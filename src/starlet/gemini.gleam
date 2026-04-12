//// Google Gemini provider for starlet.
////
//// Uses the [Gemini API](https://ai.google.dev/gemini-api/docs) via Google AI Studio.
////
//// ## Usage
////
//// ```gleam
//// import gleam/httpc
//// import starlet
//// import starlet/gemini
////
//// let creds = gemini.credentials(api_key)
//// let chat = gemini.chat("gemini-2.5-flash")
////   |> starlet.user("Hello!")
////
//// let assert Ok(http_resp) = httpc.send(gemini.request(chat, creds))
//// let assert Ok(turn) = gemini.response(chat, http_resp)
//// ```
////
//// ## Thinking Mode
////
//// For Gemini 2.5+ models, configure thinking:
////
//// ```gleam
//// let assert Ok(chat) =
////   gemini.chat("gemini-2.5-flash")
////   |> gemini.with_thinking(budget: gemini.ThinkingDynamic)
//// let chat = chat
////   |> starlet.user("Solve this step by step...")
//// ```

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import starlet
import starlet/internal/http as internal_http
import starlet/internal/sse
import starlet/tool

const default_host = "generativelanguage.googleapis.com"

/// Thinking budget for Gemini 2.5+ models.
pub type ThinkingBudget {
  /// Disable thinking entirely
  ThinkingOff
  /// Model adjusts budget based on request complexity
  ThinkingDynamic
  /// Fixed token budget (1-32768)
  ThinkingFixed(tokens: Int)
}

/// A thought part record for round-tripping thinking data in conversation history.
pub type ThoughtRecord {
  ThoughtRecord(text: String, signature: Option(String))
}

/// Gemini provider extension type.
pub type Ext {
  Ext(
    /// Thinking budget configuration.
    thinking_budget: Option(ThinkingBudget),
    /// Thinking content from the last response.
    thinking: Option(String),
    /// Accumulated thought records per assistant message, for round-tripping
    /// thinking data (including opaque thoughtSignatures) in conversation history.
    /// Each entry corresponds to one AssistantMessage in chat.messages, in order.
    thought_history: List(List(ThoughtRecord)),
  )
}

/// Connection credentials for Gemini.
pub opaque type Credentials {
  Credentials(
    api_key: String,
    base_request: Request(String),
    path_prefix: String,
  )
}

/// Information about an available model.
pub type Model {
  Model(id: String, display_name: String)
}

/// Creates credentials for connecting to Gemini.
/// Uses the default base URL: https://generativelanguage.googleapis.com
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
pub fn chat(
  model: String,
) -> starlet.Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, Ext) {
  let default_ext =
    Ext(
      thinking_budget: option.None,
      thinking: option.None,
      thought_history: [],
    )
  starlet.new_chat(model, default_ext)
}

/// Enable thinking mode for Gemini 2.5+ models.
/// Validates that ThinkingFixed is within range 1-32768.
pub fn with_thinking(
  chat: starlet.Chat(tools, format, state, Ext),
  budget budget: ThinkingBudget,
) -> Result(starlet.Chat(tools, format, state, Ext), starlet.Error) {
  case budget {
    ThinkingFixed(tokens) if tokens < 1 ->
      Error(starlet.InvalidArgument("thinking budget must be at least 1 token"))
    ThinkingFixed(tokens) if tokens > 32_768 ->
      Error(starlet.InvalidArgument(
        "thinking budget must be at most 32768 tokens",
      ))
    ThinkingOff | ThinkingDynamic | ThinkingFixed(_) ->
      Ok(
        starlet.Chat(
          ..chat,
          ext: Ext(..chat.ext, thinking_budget: option.Some(budget)),
        ),
      )
  }
}

/// Get the thinking content from a Gemini turn (if present).
pub fn thinking(turn: starlet.Turn(tools, format, Ext)) -> Option(String) {
  turn.ext.thinking
}

/// Adds an assistant message to the chat history for few-shot examples.
///
/// Keeps the thought history aligned with assistant messages so
/// thought signatures are applied to the correct turns.
pub fn assistant(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  text: String,
) -> starlet.Chat(tools, format, starlet.Ready, Ext) {
  starlet.Chat(
    ..chat,
    messages: list.append(chat.messages, [starlet.AssistantMessage(text, [])]),
    ext: Ext(
      ..chat.ext,
      thought_history: list.append(chat.ext.thought_history, [[]]),
    ),
  )
}

/// Builds an HTTP request for sending a chat to Gemini.
///
/// The returned request can be sent with any HTTP client.
pub fn request(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  creds: Credentials,
) -> Request(String) {
  let body = json.to_string(encode_request(chat))
  let path =
    creds.path_prefix <> "/v1beta/models/" <> chat.model <> ":generateContent"

  creds.base_request
  |> request.set_method(http.Post)
  |> request.set_path(path)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("x-goog-api-key", creds.api_key)
  |> request.set_body(body)
}

/// Decodes an HTTP response from Gemini into a Turn.
pub fn response(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  resp: Response(String),
) -> Result(starlet.Turn(tools, format, Ext), starlet.Error) {
  case resp.status {
    200 -> {
      use #(text, thinking_content, tool_calls, thought_records) <- result.map(
        decode_response(resp.body),
      )
      let thought_history =
        list.append(chat.ext.thought_history, [thought_records])
      let ext = Ext(..chat.ext, thinking: thinking_content, thought_history:)
      starlet.Turn(text:, tool_calls:, ext:)
    }
    _ ->
      Error(internal_http.handle_error_response(
        resp,
        provider: "gemini",
        decode_error: decode_error_response,
      ))
  }
}

/// Decodes an error response body from the Gemini API.
/// Returns the error message if successfully parsed.
@internal
pub fn decode_error_response(body: String) -> Result(String, Nil) {
  internal_http.decode_error_response(body)
}

/// Encodes a chat into JSON for the Gemini generateContent endpoint.
@internal
pub fn encode_request(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
) -> Json {
  let contents = build_contents(chat.messages, chat.ext.thought_history)

  let base = [#("contents", json.preprocessed_array(contents))]

  let base = case chat.system_prompt {
    option.Some(prompt) -> [
      #(
        "systemInstruction",
        json.object([
          #(
            "parts",
            json.preprocessed_array([
              json.object([#("text", json.string(prompt))]),
            ]),
          ),
        ]),
      ),
      ..base
    ]
    option.None -> base
  }

  let base = case chat.tools {
    [] -> base
    tools -> [
      #("tools", json.preprocessed_array([build_function_declarations(tools)])),
      ..base
    ]
  }

  let gen_config = build_generation_config(chat)
  let base = case gen_config {
    option.Some(config) -> [#("generationConfig", config), ..base]
    option.None -> base
  }

  json.object(base)
}

fn build_contents(
  messages: List(starlet.Message),
  thought_history: List(List(ThoughtRecord)),
) -> List(Json) {
  build_contents_acc(messages, thought_history, [])
  |> list.reverse
}

fn build_contents_acc(
  messages: List(starlet.Message),
  thought_history: List(List(ThoughtRecord)),
  acc: List(Json),
) -> List(Json) {
  case messages {
    [] -> acc
    [starlet.UserMessage(content), ..rest] -> {
      let encoded = encode_user_message(content)
      build_contents_acc(rest, thought_history, [encoded, ..acc])
    }
    [starlet.AssistantMessage(content, tool_calls), ..rest] -> {
      let #(thought_records, remaining_thoughts) = case thought_history {
        [first, ..rest_thoughts] -> #(first, rest_thoughts)
        [] -> #([], [])
      }
      let encoded =
        encode_assistant_message(content, tool_calls, thought_records)
      build_contents_acc(rest, remaining_thoughts, [encoded, ..acc])
    }
    [starlet.ToolResultMessage(_call_id, name, content), ..rest] -> {
      let first_part = encode_tool_result_part(name, content)
      let #(more_parts, remaining) = collect_tool_result_parts(rest, [])
      let all_parts = [first_part, ..more_parts]
      let encoded =
        json.object([
          #("role", json.string("user")),
          #("parts", json.preprocessed_array(all_parts)),
        ])
      build_contents_acc(remaining, thought_history, [encoded, ..acc])
    }
  }
}

fn collect_tool_result_parts(
  messages: List(starlet.Message),
  acc: List(Json),
) -> #(List(Json), List(starlet.Message)) {
  case messages {
    [starlet.ToolResultMessage(_call_id, name, content), ..rest] -> {
      let part = encode_tool_result_part(name, content)
      collect_tool_result_parts(rest, [part, ..acc])
    }
    [] | [starlet.UserMessage(_), ..] | [starlet.AssistantMessage(_, _), ..] -> #(
      list.reverse(acc),
      messages,
    )
  }
}

fn encode_tool_result_part(name: String, content: String) -> Json {
  let response = case json.parse(content, decode.dynamic) {
    Ok(parsed) -> tool.dynamic_to_json(parsed)
    Error(_) -> json.object([#("result", json.string(content))])
  }
  json.object([
    #(
      "functionResponse",
      json.object([
        #("name", json.string(name)),
        #("response", response),
      ]),
    ),
  ])
}

fn encode_user_message(content: String) -> Json {
  json.object([
    #("role", json.string("user")),
    #(
      "parts",
      json.preprocessed_array([json.object([#("text", json.string(content))])]),
    ),
  ])
}

fn encode_assistant_message(
  content: String,
  tool_calls: List(tool.Call),
  thought_records: List(ThoughtRecord),
) -> Json {
  let thought_parts =
    list.map(thought_records, fn(record) {
      let base = [
        #("text", json.string(record.text)),
        #("thought", json.bool(True)),
      ]
      let base = case record.signature {
        option.Some(sig) -> [#("thoughtSignature", json.string(sig)), ..base]
        option.None -> base
      }
      json.object(base)
    })

  let text_parts = case content {
    "" -> []
    _ -> [json.object([#("text", json.string(content))])]
  }

  let call_parts =
    list.map(tool_calls, fn(call) {
      json.object([
        #(
          "functionCall",
          json.object([
            #("name", json.string(call.name)),
            #("args", tool.dynamic_to_json(call.arguments)),
          ]),
        ),
      ])
    })

  let all_parts = list.flatten([thought_parts, text_parts, call_parts])

  json.object([
    #("role", json.string("model")),
    #("parts", json.preprocessed_array(all_parts)),
  ])
}

fn build_function_declarations(tools: List(tool.Definition)) -> Json {
  json.object([
    #(
      "functionDeclarations",
      json.array(tools, fn(definition) {
        case definition {
          tool.Function(name, description, parameters) ->
            json.object([
              #("name", json.string(name)),
              #("description", json.string(description)),
              #("parameters", parameters),
            ])
        }
      }),
    ),
  ])
}

fn build_generation_config(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
) -> Option(Json) {
  let config = []

  let config = case chat.temperature {
    option.Some(temperature) -> [
      #("temperature", json.float(temperature)),
      ..config
    ]
    option.None -> config
  }

  let config = case chat.max_tokens {
    option.Some(max_tokens) -> [
      #("maxOutputTokens", json.int(max_tokens)),
      ..config
    ]
    option.None -> config
  }

  let config = case chat.json_schema {
    option.Some(schema) -> [
      #("responseMimeType", json.string("application/json")),
      #("responseSchema", schema),
      ..config
    ]
    option.None -> config
  }

  let config = case chat.ext.thinking_budget {
    option.Some(ThinkingOff) -> [
      #("thinkingConfig", json.object([#("thinkingBudget", json.int(0))])),
      ..config
    ]
    option.Some(ThinkingDynamic) -> [thinking_config(-1), ..config]
    option.Some(ThinkingFixed(tokens)) -> [thinking_config(tokens), ..config]
    option.None -> config
  }

  case config {
    [] -> option.None
    [_, ..] -> option.Some(json.object(config))
  }
}

fn thinking_config(budget: Int) -> #(String, Json) {
  #(
    "thinkingConfig",
    json.object([
      #("thinkingBudget", json.int(budget)),
      #("includeThoughts", json.bool(True)),
    ]),
  )
}

/// Internal type for decoding response parts.
type Part {
  TextPart(String)
  FunctionCallPart(name: String, arguments: Dynamic)
  ThoughtPart(text: String, signature: Option(String))
  SkippedPart
}

fn part_decoder() -> decode.Decoder(Part) {
  decode.one_of(decode_thought_part(), or: [
    decode_text_part(),
    decode_function_call_part(),
    decode_skipped_part(),
  ])
}

/// Decodes a response from the Gemini generateContent endpoint.
@internal
pub fn decode_response(
  body: String,
) -> Result(
  #(String, Option(String), List(tool.Call), List(ThoughtRecord)),
  starlet.Error,
) {
  let candidate_decoder =
    decode.at(["content", "parts"], decode.list(part_decoder()))
  let decoder = {
    use candidates <- decode.field("candidates", decode.list(candidate_decoder))
    decode.success(candidates)
  }

  case json.parse(body, decoder) {
    Ok([parts, ..]) -> Ok(extract_parts(parts))
    Ok([]) -> Error(starlet.Decode("Gemini response contained no candidates"))
    Error(err) ->
      Error(starlet.Decode(
        "Failed to decode Gemini response: " <> string.inspect(err),
      ))
  }
}

fn decode_text_part() -> decode.Decoder(Part) {
  use text <- decode.field("text", decode.string)
  decode.success(TextPart(text))
}

fn decode_function_call_part() -> decode.Decoder(Part) {
  use #(name, arguments) <- decode.field("functionCall", {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("args", decode.dynamic)
    decode.success(#(name, arguments))
  })
  decode.success(FunctionCallPart(name:, arguments:))
}

fn decode_thought_part() -> decode.Decoder(Part) {
  use is_thought <- decode.field("thought", decode.bool)
  case is_thought {
    True -> {
      use text <- decode.field("text", decode.string)
      use signature <- decode.optional_field(
        "thoughtSignature",
        option.None,
        decode.string |> decode.map(option.Some),
      )
      decode.success(ThoughtPart(text:, signature:))
    }
    False -> decode.failure(ThoughtPart("", option.None), "thought is false")
  }
}

fn decode_skipped_part() -> decode.Decoder(Part) {
  use dict_val <- decode.then(decode.dict(decode.string, decode.dynamic))
  case
    dict.has_key(dict_val, "text")
    || dict.has_key(dict_val, "thought")
    || dict.has_key(dict_val, "functionCall")
  {
    True -> decode.failure(SkippedPart, "skipped_part")
    False -> decode.success(SkippedPart)
  }
}

fn extract_parts(
  parts: List(Part),
) -> #(String, Option(String), List(tool.Call), List(ThoughtRecord)) {
  let #(texts, thinkings, calls, records) =
    list.fold(parts, #([], [], [], []), fn(acc, part) {
      let #(texts, thinkings, calls, records) = acc
      case part {
        TextPart(text) -> #([text, ..texts], thinkings, calls, records)
        FunctionCallPart(name:, arguments:) -> #(
          texts,
          thinkings,
          [#(name, arguments), ..calls],
          records,
        )
        ThoughtPart(text:, signature:) -> #(texts, [text, ..thinkings], calls, [
          ThoughtRecord(text:, signature:),
          ..records
        ])
        SkippedPart -> #(texts, thinkings, calls, records)
      }
    })
  let text = texts |> list.reverse |> string.join("")
  let thinking = case list.reverse(thinkings) {
    [] -> option.None
    thinking_texts -> option.Some(string.join(thinking_texts, "\n"))
  }
  let tool_calls =
    calls
    |> list.reverse
    |> list.index_map(fn(raw, index) {
      let #(name, arguments) = raw
      tool.Call(id: "gemini-" <> int.to_string(index), name:, arguments:)
    })
  #(text, thinking, tool_calls, list.reverse(records))
}

/// Builds an HTTP request to list available models.
pub fn list_models_request(creds: Credentials) -> Request(String) {
  creds.base_request
  |> request.set_method(http.Get)
  |> request.set_path(creds.path_prefix <> "/v1beta/models")
  |> request.set_header("x-goog-api-key", creds.api_key)
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
    use name <- decode.field("name", decode.string)
    use display_name <- decode.field("displayName", decode.string)
    let id = case string.split(name, "/") {
      [_, model_id] -> model_id
      _ -> name
    }
    decode.success(Model(id:, display_name:))
  }

  let decoder = {
    use models <- decode.field("models", decode.list(model_decoder))
    decode.success(models)
  }

  json.parse(body, decoder)
  |> result.map_error(fn(err) {
    starlet.Decode("Failed to decode Gemini models: " <> string.inspect(err))
  })
}

// --- Streaming ---

/// Builds an HTTP request for streaming a chat from Gemini.
pub fn stream_request(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  creds: Credentials,
) -> Request(String) {
  let body = json.to_string(encode_request(chat))
  let path =
    creds.path_prefix
    <> "/v1beta/models/"
    <> chat.model
    <> ":streamGenerateContent"

  let existing_query =
    request.get_query(creds.base_request) |> result.unwrap([])
  let query = list.append(existing_query, [#("alt", "sse")])

  creds.base_request
  |> request.set_method(http.Post)
  |> request.set_path(path)
  |> request.set_query(query)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("x-goog-api-key", creds.api_key)
  |> request.set_body(body)
}

@internal
pub type StreamState {
  StreamState(
    buffer: sse.Buffer,
    text: String,
    thinking_text: String,
    tool_calls: List(tool.Call),
    tool_call_index: Int,
    thought_records: List(ThoughtRecord),
  )
}

/// Creates the initial streaming state for Gemini.
pub fn stream_init() -> StreamState {
  StreamState(
    buffer: sse.new(),
    text: "",
    thinking_text: "",
    tool_calls: [],
    tool_call_index: 0,
    thought_records: [],
  )
}

/// Feeds raw bytes into the stream state, returning updated state and events.
///
/// Gemini sends complete function calls in a single SSE event, so only
/// `ToolCallStart` events are emitted for tool calls, never `ToolCallDelta`.
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
  // Try provider error shape first (has "error.message"), then candidate shape.
  case try_decode_provider_error(state, event_str) {
    Ok(result) -> result
    Error(Nil) -> decode_stream_candidate(state, event_str)
  }
}

fn try_decode_provider_error(
  state: StreamState,
  event_str: String,
) -> Result(#(StreamState, List(starlet.StreamEvent)), Nil) {
  let error_decoder = decode.at(["error", "message"], decode.string)
  case json.parse(event_str, error_decoder) {
    Ok(message) ->
      Ok(
        #(state, [
          starlet.StreamError(starlet.Provider(
            provider: "gemini",
            message: message,
            raw: event_str,
          )),
        ]),
      )
    Error(_) -> Error(Nil)
  }
}

fn decode_stream_candidate(
  state: StreamState,
  event_str: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let finish_decoder =
    decode.at(
      ["candidates"],
      decode.list({
        use finish <- decode.optional_field("finishReason", "", decode.string)
        decode.success(finish)
      }),
    )

  let candidate_decoder =
    decode.at(
      ["candidates"],
      decode.list(decode.at(["content", "parts"], decode.list(part_decoder()))),
    )

  case json.parse(event_str, candidate_decoder) {
    Ok([parts, ..]) -> {
      let #(state, events) = parts_to_events(state, parts, [])
      let has_finish = case json.parse(event_str, finish_decoder) {
        Ok([reason, ..]) if reason != "" -> True
        _ -> False
      }
      case has_finish {
        True -> #(state, list.append(events, [starlet.Done]))
        False -> #(state, events)
      }
    }
    Ok(_) -> #(state, [])
    Error(_) -> #(state, [
      starlet.StreamError(starlet.Decode("Failed to decode Gemini stream event")),
    ])
  }
}

fn parts_to_events(
  state: StreamState,
  parts: List(Part),
  acc: List(starlet.StreamEvent),
) -> #(StreamState, List(starlet.StreamEvent)) {
  case parts {
    [] -> #(state, list.reverse(acc))
    [part, ..rest] -> {
      let #(state, event) = part_to_event(state, part)
      let acc = case event {
        option.Some(e) -> [e, ..acc]
        option.None -> acc
      }
      parts_to_events(state, rest, acc)
    }
  }
}

fn part_to_event(
  state: StreamState,
  part: Part,
) -> #(StreamState, Option(starlet.StreamEvent)) {
  case part {
    TextPart("") -> #(state, option.None)
    TextPart(text) -> {
      let state = StreamState(..state, text: state.text <> text)
      #(state, option.Some(starlet.TextDelta(text)))
    }
    ThoughtPart(text:, signature:) -> {
      let record = ThoughtRecord(text:, signature:)
      let state =
        StreamState(
          ..state,
          thinking_text: state.thinking_text <> text,
          thought_records: list.append(state.thought_records, [record]),
        )
      #(state, option.Some(starlet.ThinkingDelta(text)))
    }
    FunctionCallPart(name:, arguments:) -> {
      let id = "gemini-" <> int.to_string(state.tool_call_index)
      let call = tool.Call(id:, name:, arguments:)
      let state =
        StreamState(
          ..state,
          tool_calls: list.append(state.tool_calls, [call]),
          tool_call_index: state.tool_call_index + 1,
        )
      #(state, option.Some(starlet.ToolCallStart(id, name)))
    }
    SkippedPart -> #(state, option.None)
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
  let thought_history =
    list.append(chat.ext.thought_history, [state.thought_records])
  let ext = Ext(..chat.ext, thinking:, thought_history:)
  starlet.Turn(text: state.text, tool_calls: state.tool_calls, ext:)
}
