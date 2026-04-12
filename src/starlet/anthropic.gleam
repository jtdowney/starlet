//// Anthropic provider for starlet.
////
//// Uses the [Anthropic Messages API](https://docs.anthropic.com/en/api/messages)
//// for chat completions with Claude models.
////
//// ## Usage
////
//// ```gleam
//// import gleam/httpc
//// import starlet
//// import starlet/anthropic
////
//// let creds = anthropic.credentials(api_key)
//// let chat = anthropic.chat("claude-haiku-4-5-20251001")
////   |> starlet.user("Hello!")
////
//// let assert Ok(http_resp) = httpc.send(anthropic.request(chat, creds))
//// let assert Ok(turn) = anthropic.response(chat, http_resp)
//// ```
////
//// ## Extended Thinking
////
//// For models that support extended thinking, configure a thinking budget:
////
//// ```gleam
//// let assert Ok(chat) =
////   anthropic.chat("claude-haiku-4-5-20251001")
////   |> anthropic.with_thinking(budget: 16384)
//// let chat = chat
////   |> starlet.max_tokens(32000)
////   |> starlet.user("Analyze this complex problem...")
//// ```
////
//// ## Note on max_tokens
////
//// Anthropic requires `max_tokens` in every request. If not explicitly set
//// via `starlet.max_tokens()`, a default of 4096 is used.

import gleam/bool
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

const default_max_tokens = 4096

const anthropic_version = "2023-06-01"

const default_host = "api.anthropic.com"

/// Anthropic provider extension type for extended thinking.
pub type Ext {
  Ext(
    /// Token budget for extended thinking (min 1024).
    thinking_budget: Option(Int),
    /// Thinking content from the last response.
    thinking: Option(String),
  )
}

/// Connection credentials for Anthropic.
pub opaque type Credentials {
  Credentials(
    api_key: String,
    base_request: Request(String),
    path_prefix: String,
  )
}

/// Creates credentials for connecting to Anthropic.
/// Uses the default base URL: https://api.anthropic.com
pub fn credentials(api_key: String) -> Credentials {
  let #(base_request, path_prefix) =
    internal_http.default_base_request(host: default_host)
  Credentials(api_key:, base_request:, path_prefix:)
}

/// Creates credentials with a custom base URL.
/// Useful for proxies or self-hosted endpoints.
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
///
/// Note: Anthropic requires max_tokens. If not explicitly set via
/// `starlet.max_tokens()`, a default of 4096 is used.
pub fn chat(
  model: String,
) -> starlet.Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, Ext) {
  let default_ext = Ext(thinking_budget: option.None, thinking: option.None)
  starlet.new_chat(model, default_ext)
}

/// Enable extended thinking with a token budget.
/// Budget must be at least 1024 tokens. The upper bound (less than max_tokens)
/// is enforced by the API at request time.
pub fn with_thinking(
  chat: starlet.Chat(tools, format, state, Ext),
  budget budget: Int,
) -> Result(starlet.Chat(tools, format, state, Ext), starlet.Error) {
  use <- bool.guard(
    when: budget < 1024,
    return: Error(starlet.InvalidArgument(
      "thinking budget must be at least 1024 tokens",
    )),
  )
  Ok(
    starlet.Chat(
      ..chat,
      ext: Ext(..chat.ext, thinking_budget: option.Some(budget)),
    ),
  )
}

/// Get the thinking content from an Anthropic turn (if present).
pub fn thinking(turn: starlet.Turn(tools, format, Ext)) -> Option(String) {
  turn.ext.thinking
}

/// Adds an assistant message to the chat history for few-shot examples.
pub fn assistant(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  text: String,
) -> starlet.Chat(tools, format, starlet.Ready, Ext) {
  starlet.Chat(
    ..chat,
    messages: list.append(chat.messages, [starlet.AssistantMessage(text, [])]),
  )
}

/// Builds an HTTP request for sending a chat to Anthropic.
///
/// The returned request can be sent with any HTTP client.
pub fn request(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  creds: Credentials,
) -> Request(String) {
  let body = json.to_string(encode_request(chat))
  build_chat_request(body, creds, chat.ext.thinking_budget)
}

fn build_chat_request(
  body: String,
  creds: Credentials,
  thinking_budget: Option(Int),
) -> Request(String) {
  creds.base_request
  |> request.set_method(http.Post)
  |> request.set_path(creds.path_prefix <> "/v1/messages")
  |> request.set_header("content-type", "application/json")
  |> request.set_header("x-api-key", creds.api_key)
  |> request.set_header("anthropic-version", anthropic_version)
  |> set_beta_headers(thinking_budget)
  |> request.set_body(body)
}

fn set_beta_headers(
  req: Request(String),
  thinking_budget: Option(Int),
) -> Request(String) {
  case thinking_budget {
    option.Some(_) ->
      request.set_header(
        req,
        "anthropic-beta",
        "interleaved-thinking-2025-05-14",
      )
    option.None -> req
  }
}

/// Decodes an HTTP response from Anthropic into a Turn.
pub fn response(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  resp: Response(String),
) -> Result(starlet.Turn(tools, format, Ext), starlet.Error) {
  case resp.status {
    200 -> {
      use #(text, thinking_content, tool_calls) <- result.map(decode_response(
        resp.body,
      ))
      let ext = Ext(..chat.ext, thinking: thinking_content)
      starlet.Turn(text:, tool_calls:, ext:)
    }
    _ ->
      Error(internal_http.handle_error_response(
        resp,
        provider: "anthropic",
        decode_error: decode_error_response,
      ))
  }
}

/// Decodes an error response body from the Anthropic API.
/// Returns the error message if successfully parsed.
@internal
pub fn decode_error_response(body: String) -> Result(String, Nil) {
  internal_http.decode_error_response(body)
}

/// Encodes a chat into JSON for the Anthropic Messages API.
@internal
pub fn encode_request(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
) -> Json {
  encode_request_with_stream(chat, False)
}

/// Encodes a chat into JSON for the Anthropic Messages API with streaming.
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
  let max_tokens = option.unwrap(chat.max_tokens, default_max_tokens)

  let messages = encode_messages(chat.messages)

  let base = [
    #("model", json.string(chat.model)),
    #("max_tokens", json.int(max_tokens)),
    #("messages", json.preprocessed_array(messages)),
  ]

  let base = case chat.system_prompt {
    option.Some(prompt) -> [#("system", json.string(prompt)), ..base]
    option.None -> base
  }

  let optional =
    [
      case stream {
        True -> [#("stream", json.bool(True))]
        False -> []
      },
      case chat.temperature {
        option.Some(temperature) -> [#("temperature", json.float(temperature))]
        option.None -> []
      },
      case chat.tools {
        [] -> []
        tools -> [#("tools", encode_tools(tools))]
      },
      case chat.json_schema {
        option.Some(schema) -> [
          #(
            "output_config",
            json.object([
              #(
                "format",
                json.object([
                  #("type", json.string("json_schema")),
                  #("schema", schema),
                ]),
              ),
            ]),
          ),
        ]
        option.None -> []
      },
      case chat.ext.thinking_budget {
        option.Some(budget) -> [
          #(
            "thinking",
            json.object([
              #("type", json.string("enabled")),
              #("budget_tokens", json.int(budget)),
            ]),
          ),
        ]
        option.None -> []
      },
    ]
    |> list.flatten

  list.append(base, optional) |> json.object
}

fn encode_tools(tools: List(tool.Definition)) -> Json {
  json.array(tools, fn(definition) {
    case definition {
      tool.Function(name, description, parameters) ->
        json.object([
          #("name", json.string(name)),
          #("description", json.string(description)),
          #("input_schema", parameters),
        ])
    }
  })
}

fn encode_messages(messages: List(starlet.Message)) -> List(Json) {
  encode_messages_acc(messages, [])
  |> list.reverse
}

fn encode_messages_acc(
  messages: List(starlet.Message),
  acc: List(Json),
) -> List(Json) {
  case messages {
    [] -> acc
    [msg, ..rest] -> {
      let #(encoded, remaining) = case msg {
        starlet.UserMessage(content) -> #(encode_user_message(content), rest)
        starlet.AssistantMessage(content, tool_calls) -> #(
          encode_assistant_message(content, tool_calls),
          rest,
        )
        starlet.ToolResultMessage(_, _, _) ->
          encode_tool_results_batch(messages)
      }
      encode_messages_acc(remaining, [encoded, ..acc])
    }
  }
}

fn encode_user_message(content: String) -> Json {
  json.object([
    #("role", json.string("user")),
    #("content", json.string(content)),
  ])
}

fn encode_assistant_message(
  content: String,
  tool_calls: List(tool.Call),
) -> Json {
  use <- bool.guard(
    when: list.is_empty(tool_calls),
    return: json.object([
      #("role", json.string("assistant")),
      #("content", json.string(content)),
    ]),
  )

  let text_blocks = case content {
    "" -> []
    _ -> [
      json.object([
        #("type", json.string("text")),
        #("text", json.string(content)),
      ]),
    ]
  }
  let tool_blocks =
    list.map(tool_calls, fn(call) {
      json.object([
        #("type", json.string("tool_use")),
        #("id", json.string(call.id)),
        #("name", json.string(call.name)),
        #("input", tool.dynamic_to_json(call.arguments)),
      ])
    })
  json.object([
    #("role", json.string("assistant")),
    #("content", json.preprocessed_array(list.append(text_blocks, tool_blocks))),
  ])
}

fn encode_tool_results_batch(
  messages: List(starlet.Message),
) -> #(Json, List(starlet.Message)) {
  let #(results, remaining) = collect_tool_results(messages)
  let content_blocks =
    list.map(results, fn(result) {
      let #(id, content) = result
      json.object([
        #("type", json.string("tool_result")),
        #("tool_use_id", json.string(id)),
        #("content", json.string(content)),
      ])
    })
  let encoded =
    json.object([
      #("role", json.string("user")),
      #("content", json.preprocessed_array(content_blocks)),
    ])
  #(encoded, remaining)
}

fn collect_tool_results(
  messages: List(starlet.Message),
) -> #(List(#(String, String)), List(starlet.Message)) {
  collect_tool_results_acc(messages, [])
}

fn collect_tool_results_acc(
  messages: List(starlet.Message),
  acc: List(#(String, String)),
) -> #(List(#(String, String)), List(starlet.Message)) {
  case messages {
    [starlet.ToolResultMessage(id, _name, content), ..rest] ->
      collect_tool_results_acc(rest, [#(id, content), ..acc])
    [] | [starlet.UserMessage(_), ..] | [starlet.AssistantMessage(_, _), ..] -> #(
      list.reverse(acc),
      messages,
    )
  }
}

type ContentBlock {
  TextBlock(text: String)
  ToolUseBlock(call: tool.Call)
  ThinkingBlock(text: String)
  SkippedBlock(String)
}

/// Decodes a JSON response from the Anthropic Messages API.
/// Returns the text, thinking content, and tool calls.
@internal
pub fn decode_response(
  body: String,
) -> Result(#(String, Option(String), List(tool.Call)), starlet.Error) {
  let content_block_decoder = {
    use type_ <- decode.field("type", decode.string)
    case type_ {
      "text" -> decode_text_block()
      "tool_use" -> decode_tool_use_block()
      "thinking" -> decode_thinking_block()
      _ -> decode.success(SkippedBlock(type_))
    }
  }

  let decoder = {
    use content <- decode.field("content", decode.list(content_block_decoder))
    decode.success(content)
  }

  case json.parse(body, decoder) {
    Ok(content_blocks) -> Ok(extract_content(content_blocks))
    Error(err) ->
      Error(starlet.Decode(
        "Failed to decode Anthropic response: " <> string.inspect(err),
      ))
  }
}

fn decode_text_block() -> decode.Decoder(ContentBlock) {
  use text <- decode.field("text", decode.string)
  decode.success(TextBlock(text))
}

fn decode_tool_use_block() -> decode.Decoder(ContentBlock) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use arguments <- decode.field("input", decode.dynamic)
  decode.success(ToolUseBlock(tool.Call(id:, name:, arguments:)))
}

fn decode_thinking_block() -> decode.Decoder(ContentBlock) {
  use text <- decode.field("thinking", decode.string)
  decode.success(ThinkingBlock(text))
}

fn extract_content(
  blocks: List(ContentBlock),
) -> #(String, Option(String), List(tool.Call)) {
  let #(texts, thinkings, calls) =
    list.fold(blocks, #([], [], []), fn(acc, block) {
      let #(texts, thinkings, calls) = acc
      case block {
        TextBlock(text) -> #([text, ..texts], thinkings, calls)
        ToolUseBlock(call) -> #(texts, thinkings, [call, ..calls])
        ThinkingBlock(text) -> #(texts, [text, ..thinkings], calls)
        SkippedBlock(_) -> #(texts, thinkings, calls)
      }
    })
  let text = texts |> list.reverse |> string.join("")
  let thinking = case list.reverse(thinkings) {
    [] -> option.None
    thinking_texts -> option.Some(string.join(thinking_texts, "\n"))
  }
  #(text, thinking, list.reverse(calls))
}

// --- List Models ---

/// Information about an available model.
pub type Model {
  Model(id: String, display_name: String)
}

/// Builds an HTTP request to list available models.
pub fn list_models_request(creds: Credentials) -> Request(String) {
  creds.base_request
  |> request.set_method(http.Get)
  |> request.set_path(creds.path_prefix <> "/v1/models")
  |> request.set_header("x-api-key", creds.api_key)
  |> request.set_header("anthropic-version", anthropic_version)
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

@internal
pub fn decode_models(body: String) -> Result(List(Model), starlet.Error) {
  let model_decoder = {
    use id <- decode.field("id", decode.string)
    use display_name <- decode.field("display_name", decode.string)
    decode.success(Model(id:, display_name:))
  }

  let decoder = {
    use data <- decode.field("data", decode.list(model_decoder))
    decode.success(data)
  }

  json.parse(body, decoder)
  |> result.map_error(fn(err) {
    starlet.Decode("Failed to decode Anthropic models: " <> string.inspect(err))
  })
}

// --- Streaming ---

/// Builds an HTTP request for streaming a chat from Anthropic.
pub fn stream_request(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  creds: Credentials,
) -> Request(String) {
  let body = json.to_string(encode_stream_request(chat))
  build_chat_request(body, creds, chat.ext.thinking_budget)
}

@internal
pub type PendingTool {
  PendingTool(id: String, name: String, args: String)
}

@internal
pub type StreamState {
  StreamState(
    buffer: sse.Buffer,
    text: String,
    thinking_text: String,
    tool_calls: List(tool.Call),
    pending_tool: Option(PendingTool),
  )
}

/// Creates the initial streaming state for Anthropic.
pub fn stream_init() -> StreamState {
  StreamState(
    buffer: sse.new(),
    text: "",
    thinking_text: "",
    tool_calls: [],
    pending_tool: option.None,
  )
}

/// Feeds raw bytes into the stream state, returning updated state and events.
pub fn stream_feed(
  state: StreamState,
  data: BitArray,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let #(buffer, event_strings) = sse.feed(state.buffer, data)
  let state = StreamState(..state, buffer: buffer)
  decode_sse_events(state, event_strings, [])
}

fn decode_sse_events(
  state: StreamState,
  events: List(#(Option(String), String)),
  acc: List(List(starlet.StreamEvent)),
) -> #(StreamState, List(starlet.StreamEvent)) {
  case events {
    [] -> #(state, list.flatten(list.reverse(acc)))
    [event, ..rest] -> {
      let #(state, new_events) = decode_sse_event(state, event)
      decode_sse_events(state, rest, [new_events, ..acc])
    }
  }
}

fn decode_sse_event(
  state: StreamState,
  event: #(Option(String), String),
) -> #(StreamState, List(starlet.StreamEvent)) {
  let #(_, event_str) = event
  let type_decoder = {
    use type_ <- decode.field("type", decode.string)
    decode.success(type_)
  }

  case json.parse(event_str, type_decoder) {
    Ok("content_block_start") -> decode_content_block_start(state, event_str)
    Ok("content_block_delta") -> decode_content_block_delta(state, event_str)
    Ok("content_block_stop") -> finalize_content_block(state)
    Ok("message_stop") -> #(state, [starlet.Done])
    Ok("error") -> decode_stream_error(state, event_str)
    Ok(_) -> #(state, [])
    Error(_) -> #(state, [
      starlet.StreamError(starlet.Decode(
        "Failed to decode Anthropic stream event",
      )),
    ])
  }
}

fn decode_content_block_start(
  state: StreamState,
  event_str: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let decoder = {
    use block <- decode.field("content_block", {
      use type_ <- decode.field("type", decode.string)
      case type_ {
        "tool_use" -> {
          use id <- decode.field("id", decode.string)
          use name <- decode.field("name", decode.string)
          decode.success(option.Some(#(id, name)))
        }
        _ -> decode.success(option.None)
      }
    })
    decode.success(block)
  }

  case json.parse(event_str, decoder) {
    Ok(option.Some(#(id, name))) -> {
      let state =
        StreamState(
          ..state,
          pending_tool: option.Some(PendingTool(id:, name:, args: "")),
        )
      #(state, [starlet.ToolCallStart(id, name)])
    }
    _ -> #(state, [])
  }
}

fn decode_content_block_delta(
  state: StreamState,
  event_str: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let decoder = {
    use delta <- decode.field("delta", {
      use type_ <- decode.field("type", decode.string)
      decode.success(type_)
    })
    decode.success(delta)
  }

  case json.parse(event_str, decoder) {
    Ok("text_delta") -> {
      let text_decoder = decode.at(["delta", "text"], decode.string)
      case json.parse(event_str, text_decoder) {
        Ok(text) -> {
          let state = StreamState(..state, text: state.text <> text)
          #(state, [starlet.TextDelta(text)])
        }
        Error(_) -> #(state, [])
      }
    }
    Ok("thinking_delta") -> {
      let thinking_decoder = decode.at(["delta", "thinking"], decode.string)
      case json.parse(event_str, thinking_decoder) {
        Ok(text) -> {
          let state =
            StreamState(..state, thinking_text: state.thinking_text <> text)
          #(state, [starlet.ThinkingDelta(text)])
        }
        Error(_) -> #(state, [])
      }
    }
    Ok("input_json_delta") -> {
      let json_decoder = decode.at(["delta", "partial_json"], decode.string)
      case json.parse(event_str, json_decoder), state.pending_tool {
        Ok(partial), option.Some(pending_tool) -> {
          let state =
            StreamState(
              ..state,
              pending_tool: option.Some(
                PendingTool(..pending_tool, args: pending_tool.args <> partial),
              ),
            )
          #(state, [
            starlet.ToolCallDelta(pending_tool.id, partial),
          ])
        }
        Ok(_), option.None -> #(state, [
          starlet.StreamError(starlet.Decode(
            "Received input_json_delta without a pending tool call",
          )),
        ])
        Error(_), _ -> #(state, [])
      }
    }
    _ -> #(state, [])
  }
}

fn finalize_content_block(
  state: StreamState,
) -> #(StreamState, List(starlet.StreamEvent)) {
  case state.pending_tool {
    option.None -> #(state, [])
    option.Some(pending_tool) -> {
      let arguments = case pending_tool.args {
        "" -> dynamic.nil()
        raw ->
          case json.parse(raw, decode.dynamic) {
            Ok(parsed) -> parsed
            Error(_) -> dynamic.string(raw)
          }
      }
      let call =
        tool.Call(id: pending_tool.id, name: pending_tool.name, arguments:)
      let state =
        StreamState(
          ..state,
          tool_calls: list.append(state.tool_calls, [call]),
          pending_tool: option.None,
        )
      #(state, [])
    }
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
        provider: "anthropic",
        message: message,
        raw: event_str,
      )),
    ])
    Error(_) -> #(state, [
      starlet.StreamError(starlet.Provider(
        provider: "anthropic",
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
  let thinking = case state.thinking_text {
    "" -> option.None
    thinking_text -> option.Some(thinking_text)
  }
  let ext = Ext(..chat.ext, thinking:)
  starlet.Turn(text: state.text, tool_calls: state.tool_calls, ext:)
}
