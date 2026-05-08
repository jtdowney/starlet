//// OpenAI provider for starlet.
////
//// Uses the [OpenAI Responses API](https://platform.openai.com/docs/api-reference/responses)
//// for chat completions with support for server-side conversation continuation.
////
//// ## Usage
////
//// ```gleam
//// import gleam/httpc
//// import starlet
//// import starlet/openai
////
//// let creds = openai.credentials(api_key)
//// let chat = openai.chat("gpt-4o")
////   |> starlet.user("Hello!")
////
//// let assert Ok(http_resp) = httpc.send(openai.request(chat, creds))
//// let assert Ok(turn) = openai.response(chat, http_resp)
//// ```
////
//// ## Reasoning Models
////
//// For reasoning models (o1, o3, gpt-5), you can configure reasoning effort:
////
//// ```gleam
//// openai.chat("gpt-5-nano")
//// |> openai.with_reasoning(effort: openai.ReasoningHigh)
//// |> starlet.user("Solve this step by step...")
//// ```

import gleam/bool
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import starlet
import starlet/internal/http as internal_http
import starlet/internal/sse
import starlet/tool

const default_host = "api.openai.com"

/// Reasoning effort level for OpenAI reasoning models.
pub type ReasoningEffort {
  /// No reasoning tokens generated
  ReasoningNone
  /// Minimal reasoning, favors speed
  ReasoningLow
  /// Balanced reasoning (default for reasoning models)
  ReasoningMedium
  /// Maximum reasoning depth
  ReasoningHigh
  /// Extended high reasoning effort
  ReasoningXHigh
}

/// OpenAI provider extension type for server-side conversation state and reasoning.
pub type Ext {
  Ext(
    /// The ID of the last response, used for continuation.
    response_id: Option(String),
    /// Reasoning effort level for reasoning models.
    reasoning_effort: Option(ReasoningEffort),
    /// Reasoning summary from the last response.
    reasoning_summary: Option(String),
  )
}

/// Connection credentials for OpenAI.
pub opaque type Credentials {
  Credentials(
    api_key: String,
    base_request: Request(String),
    path_prefix: String,
  )
}

/// Information about an available model.
pub type Model {
  Model(id: String, owned_by: String)
}

/// Creates credentials for connecting to OpenAI.
/// Uses the default base URL: https://api.openai.com
pub fn credentials(api_key: String) -> Credentials {
  let #(base_request, path_prefix) =
    internal_http.default_base_request(host: default_host)
  Credentials(api_key:, base_request:, path_prefix:)
}

/// Creates credentials with a custom base URL.
/// Useful for proxies or Azure OpenAI endpoints.
pub fn credentials_with_base_url(
  api_key api_key: String,
  base_url base_url: String,
) -> Result(Credentials, starlet.Error) {
  use #(base_request, path_prefix) <- result.map(internal_http.base_request(
    base_url,
    default_scheme: "https",
    default_host: default_host,
  ))
  Credentials(api_key:, base_request:, path_prefix:)
}

/// Creates a new chat with the given model name.
pub fn chat(
  model: String,
) -> starlet.Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, Ext) {
  let default_ext =
    Ext(
      response_id: option.None,
      reasoning_effort: option.None,
      reasoning_summary: option.None,
    )
  starlet.new_chat(model, default_ext)
}

/// Set the reasoning effort for reasoning models (o1, o3, gpt-5).
/// When not set, the provider's default applies (medium for reasoning models).
pub fn with_reasoning(
  chat: starlet.Chat(tools, format, state, Ext),
  effort effort: ReasoningEffort,
) -> starlet.Chat(tools, format, state, Ext) {
  starlet.Chat(
    ..chat,
    ext: Ext(..chat.ext, reasoning_effort: option.Some(effort)),
  )
}

/// Continue a conversation from a previous response ID.
/// The server will use its stored conversation state.
pub fn continue_from(
  chat: starlet.Chat(tools, format, state, Ext),
  id: String,
) -> starlet.Chat(tools, format, state, Ext) {
  starlet.Chat(..chat, ext: Ext(..chat.ext, response_id: option.Some(id)))
}

/// Reset the response ID, disabling automatic conversation continuation.
/// Use this to start a fresh conversation without the previous context.
pub fn reset_response_id(
  chat: starlet.Chat(tools, format, state, Ext),
) -> starlet.Chat(tools, format, state, Ext) {
  starlet.Chat(..chat, ext: Ext(..chat.ext, response_id: option.None))
}

/// Adds an assistant message to the chat history for few-shot examples.
pub fn assistant(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  text: String,
) -> starlet.Chat(tools, format, starlet.Ready, Ext) {
  starlet.Chat(
    ..chat,
    messages: list.append(chat.messages, [starlet.AssistantMessage(text, [])]),
    ext: Ext(..chat.ext, response_id: option.None),
  )
}

/// Adds an assistant message with prior tool calls to the chat history.
///
/// Useful when rehydrating a transcript that includes function calls. The
/// resulting chat is in `Responded` state — the natural next step is
/// `starlet.with_tool_results` or `starlet.apply_tool_results`. Clears
/// `response_id` so the rehydrated turn is sent as a fresh request, not as
/// a continuation of an unrelated server-side conversation, and clears
/// `reasoning_summary` since the synthesized turn carries none.
pub fn assistant_with_tool_calls(
  chat: starlet.Chat(starlet.ToolsOn, format, starlet.Ready, Ext),
  text: String,
  tool_calls: List(tool.Call),
) -> starlet.Chat(starlet.ToolsOn, format, starlet.Responded, Ext) {
  let message = starlet.AssistantMessage(text, tool_calls)
  starlet.Chat(
    ..chat,
    messages: list.append(chat.messages, [message]),
    ext: Ext(
      ..chat.ext,
      response_id: option.None,
      reasoning_summary: option.None,
    ),
  )
}

/// Replace the message history and transition the chat to `Ready`.
///
/// Use this to rehydrate an OpenAI chat from a stored transcript before
/// sending. The caller is responsible for the message list being well-formed —
/// typically ending with a `UserMessage` or `ToolResultMessage`. Returns
/// `Error(InvalidArgument)` if `messages` is empty. Clears `response_id` and
/// `reasoning_summary` so the rehydrated turn is sent as a fresh request,
/// not as a continuation of an unrelated server-side conversation.
pub fn from_messages(
  chat: starlet.Chat(tools, format, state, Ext),
  messages: List(starlet.Message),
) -> Result(starlet.Chat(tools, format, starlet.Ready, Ext), starlet.Error) {
  use <- bool.guard(
    when: list.is_empty(messages),
    return: Error(starlet.InvalidArgument(
      "from_messages requires at least one message",
    )),
  )
  Ok(
    starlet.Chat(
      ..chat,
      messages:,
      ext: Ext(
        ..chat.ext,
        response_id: option.None,
        reasoning_summary: option.None,
      ),
    ),
  )
}

/// Get the response ID from an OpenAI turn.
pub fn response_id(turn: starlet.Turn(tools, format, Ext)) -> Option(String) {
  turn.ext.response_id
}

/// Get the reasoning summary from an OpenAI turn (if present).
/// Only available for reasoning models (o1, o3, gpt-5).
pub fn reasoning_summary(
  turn: starlet.Turn(tools, format, Ext),
) -> Option(String) {
  turn.ext.reasoning_summary
}

/// Builds an HTTP request for sending a chat to OpenAI.
///
/// The returned request can be sent with any HTTP client.
pub fn request(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  creds: Credentials,
) -> Request(String) {
  let body = json.to_string(encode_request(chat))
  build_chat_request(body, creds)
}

fn build_chat_request(body: String, creds: Credentials) -> Request(String) {
  creds.base_request
  |> request.set_method(http.Post)
  |> request.set_path(creds.path_prefix <> "/v1/responses")
  |> request.set_header("content-type", "application/json")
  |> request.set_header("authorization", "Bearer " <> creds.api_key)
  |> request.set_body(body)
}

/// Decodes an HTTP response from OpenAI into a Turn.
pub fn response(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  resp: Response(String),
) -> Result(starlet.Turn(tools, format, Ext), starlet.Error) {
  case resp.status {
    200 -> {
      use decoded <- result.map(decode_response(resp.body))
      let ext =
        Ext(
          ..chat.ext,
          response_id: option.Some(decoded.response_id),
          reasoning_summary: decoded.reasoning_summary,
        )
      starlet.Turn(text: decoded.text, tool_calls: decoded.tool_calls, ext:)
    }
    _ ->
      Error(internal_http.handle_error_response(
        resp,
        provider: "openai",
        decode_error: decode_error_response,
      ))
  }
}

/// Result of decoding an OpenAI response.
@internal
pub type DecodedResponse {
  DecodedResponse(
    text: String,
    tool_calls: List(tool.Call),
    response_id: String,
    reasoning_summary: Option(String),
  )
}

@internal
pub fn decode_error_response(body: String) -> Result(String, Nil) {
  internal_http.decode_error_response(body)
}

/// Encodes a chat into JSON for the OpenAI Responses API.
@internal
pub fn encode_request(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
) -> Json {
  encode_request_with_stream(chat, False)
}

/// Encodes a chat into JSON for the OpenAI Responses API with streaming.
@internal
pub fn encode_stream_request(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
) -> Json {
  encode_request_with_stream(chat, True)
}

fn encode_request_with_stream(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  stream: Bool,
) -> Json {
  let messages = chat.messages
  let #(system_prompt, messages) = case chat.ext.response_id {
    option.Some(_) ->
      case incremental_messages(messages) {
        [] -> #(chat.system_prompt, messages)
        msgs -> #(option.None, msgs)
      }
    option.None -> #(chat.system_prompt, messages)
  }
  let input = build_input(system_prompt, messages)
  let tools = build_tools(chat.tools)

  let base = [
    #("model", json.string(chat.model)),
    #("input", json.preprocessed_array(input)),
  ]

  let optional =
    [
      case stream {
        True -> [#("stream", json.bool(True))]
        False -> []
      },
      case chat.ext.response_id {
        option.Some(id) -> [#("previous_response_id", json.string(id))]
        option.None -> []
      },
      case tools {
        option.Some(tools_json) -> [#("tools", tools_json)]
        option.None -> []
      },
      case chat.temperature {
        option.Some(temperature) -> [#("temperature", json.float(temperature))]
        option.None -> []
      },
      case chat.max_tokens {
        option.Some(max_tokens) -> [
          #("max_output_tokens", json.int(max_tokens)),
        ]
        option.None -> []
      },
      case chat.json_schema {
        option.Some(schema) -> [
          #(
            "text",
            json.object([
              #(
                "format",
                json.object([
                  #("type", json.string("json_schema")),
                  #("name", json.string("json_schema")),
                  #("schema", schema),
                ]),
              ),
            ]),
          ),
        ]
        option.None -> []
      },
      case chat.ext.reasoning_effort {
        option.Some(effort) -> [
          #(
            "reasoning",
            json.object([
              #("effort", encode_reasoning_effort(effort)),
              #("summary", json.string("auto")),
            ]),
          ),
        ]
        option.None -> []
      },
    ]
    |> list.flatten

  list.append(base, optional) |> json.object
}

fn encode_reasoning_effort(effort: ReasoningEffort) -> Json {
  case effort {
    ReasoningNone -> json.string("none")
    ReasoningLow -> json.string("low")
    ReasoningMedium -> json.string("medium")
    ReasoningHigh -> json.string("high")
    ReasoningXHigh -> json.string("xhigh")
  }
}

fn incremental_messages(
  messages: List(starlet.Message),
) -> List(starlet.Message) {
  messages
  |> list.reverse
  |> list.take_while(fn(msg) {
    case msg {
      starlet.AssistantMessage(_, _) -> False
      starlet.UserMessage(_) -> True
      starlet.ToolResultMessage(_, _, _) -> True
    }
  })
  |> list.reverse
}

fn build_input(
  system_prompt: Option(String),
  messages: List(starlet.Message),
) -> List(Json) {
  let system_items = case system_prompt {
    option.Some(prompt) -> [
      json.object([
        #("role", json.string("system")),
        #("content", json.string(prompt)),
      ]),
    ]
    option.None -> []
  }

  let message_items =
    list.flat_map(messages, fn(msg) {
      case msg {
        starlet.UserMessage(content) -> build_user_item(content)
        starlet.AssistantMessage(content, tool_calls) ->
          build_assistant_items(content, tool_calls)
        starlet.ToolResultMessage(call_id, _name, content) ->
          build_tool_result_item(call_id, content)
      }
    })

  list.append(system_items, message_items)
}

fn build_user_item(content: String) -> List(Json) {
  [
    json.object([
      #("role", json.string("user")),
      #("content", json.string(content)),
    ]),
  ]
}

fn build_assistant_items(
  content: String,
  tool_calls: List(tool.Call),
) -> List(Json) {
  use <- bool.guard(when: list.is_empty(tool_calls), return: [
    json.object([
      #("role", json.string("assistant")),
      #("content", json.string(content)),
    ]),
  ])

  let text_output = case content {
    "" -> []
    _ -> [
      json.object([
        #("role", json.string("assistant")),
        #("content", json.string(content)),
      ]),
    ]
  }
  let tool_outputs =
    list.map(tool_calls, fn(call) {
      let args_str = json.to_string(tool.dynamic_to_json(call.arguments))
      json.object([
        #("type", json.string("function_call")),
        #("call_id", json.string(call.id)),
        #("name", json.string(call.name)),
        #("arguments", json.string(args_str)),
      ])
    })
  list.append(text_output, tool_outputs)
}

fn build_tool_result_item(call_id: String, content: String) -> List(Json) {
  [
    json.object([
      #("type", json.string("function_call_output")),
      #("call_id", json.string(call_id)),
      #("output", json.string(content)),
    ]),
  ]
}

fn build_tools(tools: List(tool.Definition)) -> Option(Json) {
  case tools {
    [] -> option.None
    [_, ..] ->
      option.Some(
        json.array(tools, fn(definition) {
          case definition {
            tool.Function(name, description, parameters) ->
              json.object([
                #("type", json.string("function")),
                #("name", json.string(name)),
                #("description", json.string(description)),
                #("parameters", parameters),
              ])
          }
        }),
      )
  }
}

/// Decodes a JSON response from the OpenAI Responses API.
@internal
pub fn decode_response(body: String) -> Result(DecodedResponse, starlet.Error) {
  let output_item_decoder = {
    use type_ <- decode.field("type", decode.string)
    case type_ {
      "message" -> decode_message_item()
      "function_call" -> decode_function_call_item()
      "reasoning" -> decode_reasoning_item()
      _ -> decode.success(SkippedItem(type_))
    }
  }

  let decoder = {
    use id <- decode.field("id", decode.string)
    use output <- decode.field("output", decode.list(output_item_decoder))
    decode.success(#(id, output))
  }

  case json.parse(body, decoder) {
    Ok(#(id, output_items)) -> {
      let #(text, tool_calls, reasoning) = extract_output(output_items)
      Ok(DecodedResponse(
        text:,
        tool_calls:,
        response_id: id,
        reasoning_summary: reasoning,
      ))
    }
    Error(err) ->
      Error(starlet.Decode(
        "Failed to decode OpenAI response: " <> string.inspect(err),
      ))
  }
}

type OutputItem {
  MessageItem(text: String)
  FunctionCallItem(call: tool.Call)
  ReasoningSummaryItem(text: String)
  SkippedItem(String)
}

fn decode_output_text_content() -> decode.Decoder(Option(String)) {
  use type_ <- decode.field("type", decode.string)
  use <- bool.guard(
    when: type_ != "output_text",
    return: decode.success(option.None),
  )

  use text <- decode.field("text", decode.string)
  decode.success(option.Some(text))
}

fn decode_message_item() -> decode.Decoder(OutputItem) {
  use content <- decode.field(
    "content",
    decode.list(decode_output_text_content()),
  )
  let text =
    content
    |> option.values
    |> string.join("")
  decode.success(MessageItem(text))
}

fn decode_function_call_item() -> decode.Decoder(OutputItem) {
  use call_id <- decode.field("call_id", decode.string)
  use name <- decode.field("name", decode.string)
  use arguments_str <- decode.field("arguments", decode.string)
  case json.parse(arguments_str, decode.dynamic) {
    Ok(arguments) ->
      decode.success(
        FunctionCallItem(tool.Call(id: call_id, name:, arguments:)),
      )
    Error(_) ->
      decode.success(
        FunctionCallItem(tool.Call(
          id: call_id,
          name:,
          arguments: dynamic.string(arguments_str),
        )),
      )
  }
}

fn decode_reasoning_item() -> decode.Decoder(OutputItem) {
  use summary <- decode.field(
    "summary",
    decode.list(decode.at(["text"], decode.string)),
  )
  let text = string.join(summary, "\n")
  decode.success(ReasoningSummaryItem(text))
}

fn extract_output(
  items: List(OutputItem),
) -> #(String, List(tool.Call), Option(String)) {
  let #(texts, calls, summaries) =
    list.fold(items, #([], [], []), fn(acc, item) {
      let #(texts, calls, summaries) = acc
      case item {
        MessageItem(text) -> #([text, ..texts], calls, summaries)
        FunctionCallItem(call) -> #(texts, [call, ..calls], summaries)
        ReasoningSummaryItem(text) -> #(texts, calls, [text, ..summaries])
        SkippedItem(_) -> #(texts, calls, summaries)
      }
    })
  let text = texts |> list.reverse |> string.join("")
  let reasoning = case list.reverse(summaries) {
    [] -> option.None
    ss -> option.Some(string.join(ss, "\n"))
  }
  #(text, list.reverse(calls), reasoning)
}

/// Builds an HTTP request to list available models.
pub fn list_models_request(creds: Credentials) -> Request(String) {
  creds.base_request
  |> request.set_method(http.Get)
  |> request.set_path(creds.path_prefix <> "/v1/models")
  |> request.set_header("authorization", "Bearer " <> creds.api_key)
}

/// Decodes an HTTP response containing the list of models.
pub fn list_models_response(
  resp: Response(String),
) -> Result(List(Model), starlet.Error) {
  case resp.status {
    200 -> decode_models(resp.body)
    _ -> Error(internal_http.handle_error_status(resp))
  }
}

/// Decodes a JSON response from the OpenAI `/v1/models` endpoint.
@internal
pub fn decode_models(body: String) -> Result(List(Model), starlet.Error) {
  let model_decoder = {
    use id <- decode.field("id", decode.string)
    use owned_by <- decode.field("owned_by", decode.string)
    decode.success(Model(id:, owned_by:))
  }

  let decoder = {
    use data <- decode.field("data", decode.list(model_decoder))
    decode.success(data)
  }

  json.parse(body, decoder)
  |> result.map_error(fn(err) {
    starlet.Decode("Failed to decode OpenAI models: " <> string.inspect(err))
  })
}

// --- Streaming ---

/// Builds an HTTP request for streaming a chat from OpenAI.
pub fn stream_request(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  creds: Credentials,
) -> Request(String) {
  let body = json.to_string(encode_stream_request(chat))
  build_chat_request(body, creds)
}

@internal
pub type PendingTool {
  PendingTool(call_id: String, name: String, args: String)
}

@internal
pub type StreamState {
  StreamState(
    buffer: sse.Buffer,
    text: String,
    tool_calls: List(tool.Call),
    pending_tools: dict.Dict(Int, PendingTool),
    response_id: Option(String),
    reasoning_summary: Option(String),
  )
}

/// Creates the initial streaming state for OpenAI.
pub fn stream_init() -> StreamState {
  StreamState(
    buffer: sse.new(),
    text: "",
    tool_calls: [],
    pending_tools: dict.new(),
    response_id: option.None,
    reasoning_summary: option.None,
  )
}

/// Feeds raw bytes into the stream state, returning updated state and events.
pub fn stream_feed(
  state: StreamState,
  data: BitArray,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let #(buffer, event_strings) = sse.feed(state.buffer, data)
  let state = StreamState(..state, buffer: buffer)
  decode_stream_events(state, event_strings, [])
}

fn decode_stream_events(
  state: StreamState,
  events: List(#(Option(String), String)),
  acc: List(List(starlet.StreamEvent)),
) -> #(StreamState, List(starlet.StreamEvent)) {
  case events {
    [] -> #(state, list.flatten(list.reverse(acc)))
    [event, ..rest] -> {
      let #(state, new_events) = decode_stream_event(state, event)
      decode_stream_events(state, rest, [new_events, ..acc])
    }
  }
}

fn decode_stream_event(
  state: StreamState,
  event: #(Option(String), String),
) -> #(StreamState, List(starlet.StreamEvent)) {
  let #(_, event_str) = event
  case event_str {
    "[DONE]" -> #(state, [])
    _ -> {
      let type_decoder = {
        use type_ <- decode.field("type", decode.string)
        decode.success(type_)
      }

      case json.parse(event_str, type_decoder) {
        Ok("response.created") -> decode_response_created(state, event_str)
        Ok("response.output_text.delta") -> decode_text_delta(state, event_str)
        Ok("response.output_item.added") ->
          decode_output_item_added(state, event_str)
        Ok("response.function_call_arguments.delta") ->
          decode_function_call_delta(state, event_str)
        Ok("response.output_item.done") ->
          decode_output_item_done(state, event_str)
        Ok("response.reasoning_summary_text.delta") ->
          decode_reasoning_summary_delta(state, event_str)
        Ok("response.reasoning_summary_text.done") ->
          decode_reasoning_summary_done(state, event_str)
        Ok("error") -> decode_stream_error(state, event_str)
        Ok("response.completed") -> #(state, [starlet.Done])
        Ok(_) -> #(state, [])
        Error(_) -> #(state, [
          starlet.StreamError(starlet.Decode(
            "Failed to decode OpenAI stream event",
          )),
        ])
      }
    }
  }
}

fn decode_response_created(
  state: StreamState,
  event_str: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let decoder = decode.at(["response", "id"], decode.string)
  case json.parse(event_str, decoder) {
    Ok(id) -> #(StreamState(..state, response_id: option.Some(id)), [])
    Error(_) -> #(state, [])
  }
}

fn decode_text_delta(
  state: StreamState,
  event_str: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let decoder = {
    use delta <- decode.field("delta", decode.string)
    decode.success(delta)
  }
  case json.parse(event_str, decoder) {
    Ok(delta) -> {
      let state = StreamState(..state, text: state.text <> delta)
      #(state, [starlet.TextDelta(delta)])
    }
    Error(_) -> #(state, [])
  }
}

fn decode_output_item_added(
  state: StreamState,
  event_str: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let decoder = {
    use output_index <- decode.field("output_index", decode.int)
    use item <- decode.field("item", {
      use type_ <- decode.field("type", decode.string)
      case type_ {
        "function_call" -> {
          use call_id <- decode.field("call_id", decode.string)
          use name <- decode.field("name", decode.string)
          decode.success(option.Some(#(call_id, name)))
        }
        _ -> decode.success(option.None)
      }
    })
    decode.success(#(output_index, item))
  }

  case json.parse(event_str, decoder) {
    Ok(#(output_index, option.Some(#(call_id, name)))) -> {
      let state =
        StreamState(
          ..state,
          pending_tools: dict.insert(
            state.pending_tools,
            output_index,
            PendingTool(call_id:, name:, args: ""),
          ),
        )
      #(state, [starlet.ToolCallStart(call_id, name)])
    }
    _ -> #(state, [])
  }
}

fn decode_function_call_delta(
  state: StreamState,
  event_str: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let decoder = {
    use output_index <- decode.field("output_index", decode.int)
    use delta <- decode.field("delta", decode.string)
    decode.success(#(output_index, delta))
  }
  case json.parse(event_str, decoder) {
    Ok(#(output_index, delta)) ->
      case dict.get(state.pending_tools, output_index) {
        Ok(pending) -> {
          let state =
            StreamState(
              ..state,
              pending_tools: dict.insert(
                state.pending_tools,
                output_index,
                PendingTool(..pending, args: pending.args <> delta),
              ),
            )
          #(state, [starlet.ToolCallDelta(pending.call_id, delta)])
        }
        Error(_) -> #(state, [
          starlet.StreamError(starlet.Decode(
            "Received function_call_arguments.delta for unknown output_index",
          )),
        ])
      }
    Error(_) -> #(state, [])
  }
}

fn parse_args_string(raw: String) -> dynamic.Dynamic {
  case raw {
    "" -> dynamic.nil()
    _ ->
      case json.parse(raw, decode.dynamic) {
        Ok(parsed) -> parsed
        Error(_) -> dynamic.string(raw)
      }
  }
}

fn decode_output_item_done(
  state: StreamState,
  event_str: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let type_decoder = decode.at(["item", "type"], decode.string)
  case json.parse(event_str, type_decoder) {
    Ok("function_call") -> finalize_function_call(state, event_str)
    _ -> #(state, [])
  }
}

fn finalize_function_call(
  state: StreamState,
  event_str: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let index_decoder = {
    use output_index <- decode.field("output_index", decode.int)
    decode.success(output_index)
  }

  case json.parse(event_str, index_decoder) {
    Error(_) -> #(state, [
      starlet.StreamError(starlet.Decode(
        "Failed to decode output_index from response.output_item.done",
      )),
    ])
    Ok(output_index) ->
      case dict.get(state.pending_tools, output_index) {
        Error(_) -> #(state, [
          starlet.StreamError(starlet.Decode(
            "Received response.output_item.done for unknown output_index",
          )),
        ])
        Ok(pending) -> {
          let args_str = case
            json.parse(
              event_str,
              decode.at(["item", "arguments"], decode.string),
            )
          {
            Ok(s) -> s
            Error(_) -> pending.args
          }
          let arguments = parse_args_string(args_str)
          let call =
            tool.Call(id: pending.call_id, name: pending.name, arguments:)
          let state =
            StreamState(
              ..state,
              tool_calls: list.append(state.tool_calls, [call]),
              pending_tools: dict.delete(state.pending_tools, output_index),
            )
          #(state, [])
        }
      }
  }
}

fn decode_reasoning_summary_delta(
  state: StreamState,
  event_str: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let decoder = {
    use delta <- decode.field("delta", decode.string)
    decode.success(delta)
  }
  case json.parse(event_str, decoder) {
    Ok(delta) -> {
      let current = option.unwrap(state.reasoning_summary, "")
      let state =
        StreamState(..state, reasoning_summary: option.Some(current <> delta))
      #(state, [starlet.ThinkingDelta(delta)])
    }
    Error(_) -> #(state, [])
  }
}

fn decode_reasoning_summary_done(
  state: StreamState,
  event_str: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let decoder = decode.at(["text"], decode.string)
  case json.parse(event_str, decoder) {
    Ok(text) -> {
      let state = StreamState(..state, reasoning_summary: option.Some(text))
      #(state, [])
    }
    Error(_) -> #(state, [])
  }
}

fn decode_stream_error(
  state: StreamState,
  event_str: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let decoder = decode.at(["error", "message"], decode.string)
  case json.parse(event_str, decoder) {
    Ok(message) -> #(state, [
      starlet.StreamError(starlet.Provider(
        provider: "openai",
        message: message,
        raw: event_str,
      )),
    ])
    Error(_) -> #(state, [
      starlet.StreamError(starlet.Provider(
        provider: "openai",
        message: "unknown stream error",
        raw: event_str,
      )),
    ])
  }
}

/// Assembles a completed Turn from the accumulated stream state.
pub fn stream_done(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  state: StreamState,
) -> starlet.Turn(tools, format, Ext) {
  let ext =
    Ext(
      ..chat.ext,
      response_id: state.response_id,
      reasoning_summary: state.reasoning_summary,
    )
  starlet.Turn(text: state.text, tool_calls: state.tool_calls, ext:)
}
