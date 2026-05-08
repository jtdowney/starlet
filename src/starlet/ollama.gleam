//// Ollama provider for starlet.
////
//// [Ollama](https://ollama.com) is a local LLM runtime that supports many
//// open-source models.
////
//// ## Usage
////
//// ```gleam
//// import gleam/httpc
//// import starlet
//// import starlet/ollama
////
//// let creds = ollama.credentials("http://localhost:11434")
//// let chat = ollama.chat("qwen3:0.6b")
////   |> starlet.user("Hello!")
////
//// let assert Ok(http_resp) = httpc.send(ollama.request(chat, creds))
//// let assert Ok(turn) = ollama.response(chat, http_resp)
//// ```
////
//// ## Thinking Mode
////
//// For thinking-capable models (DeepSeek-R1, Qwen3), configure thinking:
////
//// ```gleam
//// ollama.chat("deepseek-r1")
//// |> ollama.with_thinking(mode: ollama.ThinkingOn)
//// |> starlet.user("Solve this step by step...")
//// ```

import gleam/bool
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

const default_host = "localhost"

/// Thinking mode configuration for Ollama.
pub type Thinking {
  /// Enable thinking (boolean mode)
  ThinkingOn
  /// Disable thinking
  ThinkingOff
  /// Low reasoning effort (for models that support effort levels)
  ThinkingLow
  /// Medium reasoning effort
  ThinkingMedium
  /// High reasoning effort
  ThinkingHigh
}

/// Ollama provider extension type for thinking mode.
pub type Ext {
  Ext(
    /// Thinking mode configuration.
    thinking_mode: Option(Thinking),
    /// Thinking content from the last response.
    thinking_content: Option(String),
  )
}

/// Connection credentials for Ollama.
pub opaque type Credentials {
  Credentials(
    base_request: Request(String),
    path_prefix: String,
    api_key: Option(String),
  )
}

/// Information about an available model.
pub type Model {
  Model(name: String, size: String)
}

/// Creates credentials for connecting to an Ollama server.
///
/// Example: `let assert Ok(creds) = ollama.credentials("http://localhost:11434")`
pub fn credentials(base_url: String) -> Result(Credentials, starlet.Error) {
  use #(base_request, path_prefix) <- result.map(internal_http.base_request(
    base_url,
    default_scheme: "http",
    default_host: default_host,
  ))
  Credentials(base_request:, path_prefix:, api_key: option.None)
}

/// Creates credentials for a locally-running Ollama server at the default address.
///
/// Equivalent to `credentials("http://localhost:11434")`.
pub fn default_credentials() -> Credentials {
  let assert Ok(creds) = credentials("http://localhost:11434")
  creds
}

/// Creates credentials with an API key for authenticated Ollama instances.
/// Useful for hosted or proxied Ollama endpoints that require authorization.
pub fn credentials_with_api_key(
  base_url base_url: String,
  api_key api_key: String,
) -> Result(Credentials, starlet.Error) {
  use #(base_request, path_prefix) <- result.map(internal_http.base_request(
    base_url,
    default_scheme: "http",
    default_host: default_host,
  ))
  Credentials(base_request:, path_prefix:, api_key: option.Some(api_key))
}

/// Creates a new chat with the given model name.
pub fn chat(
  model: String,
) -> starlet.Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, Ext) {
  let default_ext =
    Ext(thinking_mode: option.None, thinking_content: option.None)
  starlet.new_chat(model, default_ext)
}

/// Configure thinking mode for thinking-capable models.
/// When not set, the provider's default applies (enabled for thinking models).
pub fn with_thinking(
  chat: starlet.Chat(tools, format, state, Ext),
  mode mode: Thinking,
) -> starlet.Chat(tools, format, state, Ext) {
  starlet.Chat(..chat, ext: Ext(..chat.ext, thinking_mode: option.Some(mode)))
}

/// Get the thinking content from an Ollama turn (if present).
pub fn thinking(turn: starlet.Turn(tools, format, Ext)) -> Option(String) {
  turn.ext.thinking_content
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

/// Adds an assistant message with prior tool calls to the chat history.
///
/// Useful when rehydrating a transcript that includes function calls. The
/// resulting chat is in `Responded` state — the natural next step is
/// `starlet.with_tool_results` or `starlet.apply_tool_results`. Requires
/// `ToolsOn` since the helper only makes sense for tools-enabled chats.
/// Clears `thinking_content` since the synthesized turn carries none.
pub fn assistant_with_tool_calls(
  chat: starlet.Chat(starlet.ToolsOn, format, starlet.Ready, Ext),
  text: String,
  tool_calls: List(tool.Call),
) -> starlet.Chat(starlet.ToolsOn, format, starlet.Responded, Ext) {
  starlet.Chat(
    ..chat,
    messages: list.append(chat.messages, [
      starlet.AssistantMessage(text, tool_calls),
    ]),
    ext: Ext(..chat.ext, thinking_content: option.None),
  )
}

/// Replace the message history and transition the chat to `Ready`.
///
/// Use this to rehydrate an Ollama chat from a stored transcript before
/// sending. The caller is responsible for the message list being well-formed —
/// typically ending with a `UserMessage` or `ToolResultMessage`. Returns
/// `Error(InvalidArgument)` if `messages` is empty. Clears `thinking_content`
/// since the rehydrated transcript has no associated last-response metadata.
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
      ext: Ext(..chat.ext, thinking_content: option.None),
    ),
  )
}

/// Builds an HTTP request for sending a chat to Ollama.
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
  |> request.set_path(creds.path_prefix <> "/api/chat")
  |> request.set_header("content-type", "application/json")
  |> with_auth(creds)
  |> request.set_body(body)
}

/// Decodes an HTTP response from Ollama into a Turn.
pub fn response(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  resp: Response(String),
) -> Result(starlet.Turn(tools, format, Ext), starlet.Error) {
  case resp.status {
    200 -> {
      use #(text, thinking_content, tool_calls) <- result.map(decode_response(
        resp.body,
      ))
      let ext = Ext(..chat.ext, thinking_content:)
      starlet.Turn(text:, tool_calls:, ext:)
    }
    _ ->
      Error(internal_http.handle_error_response(
        resp,
        provider: "ollama",
        decode_error: decode_error_response,
      ))
  }
}

/// Encodes a chat into JSON for the Ollama `/api/chat` endpoint.
@internal
pub fn encode_request(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
) -> Json {
  encode_request_with_stream(chat, False)
}

/// Encodes a chat into JSON for the Ollama `/api/chat` endpoint with streaming.
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
  let messages = build_messages(chat.system_prompt, chat.messages)
  let options = build_options(chat.temperature, chat.max_tokens)
  let tools = build_tools(chat.tools)

  let base = [
    #("model", json.string(chat.model)),
    #("messages", json.preprocessed_array(messages)),
    #("stream", json.bool(stream)),
  ]

  let optional =
    [
      case options {
        option.Some(opts) -> [#("options", opts)]
        option.None -> []
      },
      case tools {
        option.Some(tools_json) -> [#("tools", tools_json)]
        option.None -> []
      },
      case chat.ext.thinking_mode {
        option.Some(mode) -> encode_thinking_mode(mode)
        option.None -> []
      },
      case chat.json_schema {
        option.Some(schema) -> [#("format", schema)]
        option.None -> []
      },
    ]
    |> list.flatten

  list.append(base, optional) |> json.object
}

fn encode_thinking_mode(thinking: Thinking) -> List(#(String, Json)) {
  case thinking {
    ThinkingOn -> [#("think", json.bool(True))]
    ThinkingOff -> [#("think", json.bool(False))]
    ThinkingLow -> [
      #("think", json.bool(True)),
      #("reasoning_effort", json.string("low")),
    ]
    ThinkingMedium -> [
      #("think", json.bool(True)),
      #("reasoning_effort", json.string("medium")),
    ]
    ThinkingHigh -> [
      #("think", json.bool(True)),
      #("reasoning_effort", json.string("high")),
    ]
  }
}

/// Builds an HTTP request for streaming a chat from Ollama.
pub fn stream_request(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  creds: Credentials,
) -> Request(String) {
  let body = json.to_string(encode_stream_request(chat))
  build_chat_request(body, creds)
}

@internal
pub type StreamState {
  StreamState(
    buffer: sse.NdjsonBuffer,
    text: String,
    thinking_text: String,
    tool_calls: List(tool.Call),
    tool_call_index: Int,
  )
}

/// Creates the initial streaming state for Ollama.
pub fn stream_init() -> StreamState {
  StreamState(
    buffer: sse.new_ndjson(),
    text: "",
    thinking_text: "",
    tool_calls: [],
    tool_call_index: 0,
  )
}

/// Feeds raw bytes into the stream state, returning updated state and events.
pub fn stream_feed(
  state: StreamState,
  data: BitArray,
) -> #(StreamState, List(starlet.StreamEvent)) {
  let #(buffer, lines) = sse.feed_ndjson(state.buffer, data)
  let state = StreamState(..state, buffer: buffer)
  decode_stream_lines(state, lines, [])
}

fn decode_error_response(body: String) -> Result(String, Nil) {
  let decoder = {
    use message <- decode.field("error", decode.string)
    decode.success(message)
  }
  json.parse(body, decoder)
  |> result.replace_error(Nil)
}

fn decode_stream_lines(
  state: StreamState,
  lines: List(String),
  acc: List(List(starlet.StreamEvent)),
) -> #(StreamState, List(starlet.StreamEvent)) {
  case lines {
    [] -> #(state, list.flatten(list.reverse(acc)))
    [line, ..rest] -> {
      let #(state, new_events) = decode_stream_line(state, line)
      decode_stream_lines(state, rest, [new_events, ..acc])
    }
  }
}

type StreamChunk {
  StreamChunkMessage(
    done: Bool,
    content: String,
    thinking: String,
    tool_calls: List(RawToolCall),
  )
  StreamChunkError(message: String)
}

fn stream_chunk_decoder() -> decode.Decoder(StreamChunk) {
  let inner_decoder = {
    use content <- decode.optional_field("content", "", decode.string)
    use thinking <- decode.optional_field("thinking", "", decode.string)
    use tool_calls <- decode.optional_field(
      "tool_calls",
      [],
      decode.list(tool_call_decoder()),
    )
    decode.success(#(content, thinking, tool_calls))
  }
  let message_decoder = {
    use done <- decode.field("done", decode.bool)
    use #(content, thinking, tool_calls) <- decode.field(
      "message",
      inner_decoder,
    )
    decode.success(StreamChunkMessage(done:, content:, thinking:, tool_calls:))
  }
  let error_decoder = {
    use message <- decode.field("error", decode.string)
    decode.success(StreamChunkError(message:))
  }
  decode.one_of(message_decoder, or: [error_decoder])
}

fn decode_stream_line(
  state: StreamState,
  line: String,
) -> #(StreamState, List(starlet.StreamEvent)) {
  case json.parse(line, stream_chunk_decoder()) {
    Ok(StreamChunkError(message)) -> #(state, [
      starlet.StreamError(starlet.Provider(
        provider: "ollama",
        message: message,
        raw: line,
      )),
    ])
    Ok(StreamChunkMessage(done: is_done, content:, thinking:, tool_calls:)) ->
      decode_stream_message(state, is_done, content, thinking, tool_calls)
    Error(_) -> #(state, [
      starlet.StreamError(starlet.Decode("Failed to decode Ollama stream event")),
    ])
  }
}

fn decode_stream_message(
  state: StreamState,
  is_done: Bool,
  content: String,
  thinking: String,
  tool_calls: List(RawToolCall),
) -> #(StreamState, List(starlet.StreamEvent)) {
  let events = []
  let #(state, events) = case thinking {
    "" -> #(state, events)
    thinking_text -> #(
      StreamState(..state, thinking_text: state.thinking_text <> thinking_text),
      [starlet.ThinkingDelta(thinking_text), ..events],
    )
  }
  let #(state, events) = case content {
    "" -> #(state, events)
    content_text -> #(StreamState(..state, text: state.text <> content_text), [
      starlet.TextDelta(content_text),
      ..events
    ])
  }
  let #(state, events) = case tool_calls {
    [] -> #(state, events)
    calls -> {
      let offset = state.tool_call_index
      let calls = assign_tool_call_ids(calls, offset: offset)
      let tool_events =
        list.map(calls, fn(call) { starlet.ToolCallStart(call.id, call.name) })
      let state =
        StreamState(
          ..state,
          tool_calls: list.append(state.tool_calls, calls),
          tool_call_index: offset + list.length(calls),
        )
      #(state, list.append(tool_events, events))
    }
  }
  let events = list.reverse(events)
  case is_done {
    True -> #(state, list.append(events, [starlet.Done]))
    False -> #(state, events)
  }
}

/// Assembles a completed Turn from the accumulated stream state.
pub fn stream_done(
  chat: starlet.Chat(tools, format, starlet.Ready, Ext),
  state: StreamState,
) -> starlet.Turn(tools, format, Ext) {
  let thinking_content = case state.thinking_text {
    "" -> option.None
    thinking_text -> option.Some(thinking_text)
  }
  let ext = Ext(..chat.ext, thinking_content:)
  starlet.Turn(text: state.text, tool_calls: state.tool_calls, ext:)
}

fn with_auth(req: Request(String), creds: Credentials) -> Request(String) {
  case creds.api_key {
    option.Some(key) ->
      request.set_header(req, "authorization", "Bearer " <> key)
    option.None -> req
  }
}

fn build_messages(
  system_prompt: Option(String),
  messages: List(starlet.Message),
) -> List(Json) {
  let system_msgs = case system_prompt {
    option.Some(prompt) -> [
      json.object([
        #("role", json.string("system")),
        #("content", json.string(prompt)),
      ]),
    ]
    option.None -> []
  }

  let chat_msgs =
    list.map(messages, fn(msg) {
      case msg {
        starlet.UserMessage(content) ->
          json.object([
            #("role", json.string("user")),
            #("content", json.string(content)),
          ])
        starlet.AssistantMessage(content, tool_calls) ->
          case tool_calls {
            [] ->
              json.object([
                #("role", json.string("assistant")),
                #("content", json.string(content)),
              ])
            [_, ..] ->
              json.object([
                #("role", json.string("assistant")),
                #("content", json.string(content)),
                #("tool_calls", json.array(tool_calls, encode_tool_call)),
              ])
          }
        starlet.ToolResultMessage(call_id, name, content) ->
          json.object([
            #("role", json.string("tool")),
            #("tool_name", json.string(name)),
            #("tool_call_id", json.string(call_id)),
            #("content", json.string(content)),
          ])
      }
    })

  list.append(system_msgs, chat_msgs)
}

fn encode_tool_call(call: tool.Call) -> Json {
  json.object([
    #("id", json.string(call.id)),
    #(
      "function",
      json.object([
        #("name", json.string(call.name)),
        #("arguments", tool.dynamic_to_json(call.arguments)),
      ]),
    ),
  ])
}

fn build_options(
  temperature: Option(Float),
  max_tokens: Option(Int),
) -> Option(Json) {
  let opts = []

  let opts = case temperature {
    option.Some(temperature_value) -> [
      #("temperature", json.float(temperature_value)),
      ..opts
    ]
    option.None -> opts
  }

  let opts = case max_tokens {
    option.Some(max_tokens_value) -> [
      #("num_predict", json.int(max_tokens_value)),
      ..opts
    ]
    option.None -> opts
  }

  case opts {
    [] -> option.None
    [_, ..] -> option.Some(json.object(opts))
  }
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
                #(
                  "function",
                  json.object([
                    #("name", json.string(name)),
                    #("description", json.string(description)),
                    #("parameters", parameters),
                  ]),
                ),
              ])
          }
        }),
      )
  }
}

fn arguments_decoder() -> decode.Decoder(Dynamic) {
  decode.one_of(
    {
      use string_value <- decode.then(decode.string)
      case json.parse(string_value, decode.dynamic) {
        Ok(dyn) -> decode.success(dyn)
        Error(_) -> decode.failure(dynamic.nil(), "parsable json string")
      }
    },
    or: [decode.dynamic],
  )
}

fn function_decoder() -> decode.Decoder(#(String, Dynamic)) {
  use name <- decode.field("name", decode.string)
  use arguments <- decode.field("arguments", arguments_decoder())
  decode.success(#(name, arguments))
}

type RawToolCall {
  RawToolCall(id: Option(String), name: String, arguments: Dynamic)
}

fn tool_call_decoder() -> decode.Decoder(RawToolCall) {
  use function <- decode.field("function", function_decoder())
  use id <- decode.optional_field(
    "id",
    option.None,
    decode.optional(decode.string),
  )
  let #(name, arguments) = function
  decode.success(RawToolCall(id:, name:, arguments:))
}

fn assign_tool_call_ids(
  calls: List(RawToolCall),
  offset offset: Int,
) -> List(tool.Call) {
  list.index_map(calls, fn(raw, index) {
    let id = case raw.id {
      option.Some(id) -> id
      option.None -> "ollama-" <> int.to_string(index + offset)
    }
    tool.Call(id:, name: raw.name, arguments: raw.arguments)
  })
}

/// Decodes a JSON response from the Ollama `/api/chat` endpoint.
/// Returns the text, thinking content, and tool calls.
@internal
pub fn decode_response(
  body: String,
) -> Result(#(String, Option(String), List(tool.Call)), starlet.Error) {
  let message_decoder = {
    use content <- decode.optional_field("content", "", decode.string)
    use thinking <- decode.optional_field("thinking", option.None, {
      use thinking_text <- decode.then(decode.string)
      decode.success(option.Some(thinking_text))
    })
    use tool_calls <- decode.optional_field(
      "tool_calls",
      [],
      decode.list(tool_call_decoder()),
    )
    let tool_calls = assign_tool_call_ids(tool_calls, offset: 0)
    decode.success(#(content, thinking, tool_calls))
  }

  let decoder = {
    use #(content, thinking, tool_calls) <- decode.field(
      "message",
      message_decoder,
    )
    decode.success(#(content, thinking, tool_calls))
  }

  json.parse(body, decoder)
  |> result.map_error(fn(err) {
    starlet.Decode("Failed to decode Ollama response: " <> string.inspect(err))
  })
}

/// Builds an HTTP request to list available models.
pub fn list_models_request(creds: Credentials) -> Request(String) {
  creds.base_request
  |> request.set_method(http.Get)
  |> request.set_path(creds.path_prefix <> "/api/tags")
  |> with_auth(creds)
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

/// Decodes a JSON response from the Ollama `/api/tags` endpoint.
@internal
pub fn decode_models(body: String) -> Result(List(Model), starlet.Error) {
  let model_decoder = {
    use name <- decode.field("name", decode.string)
    use details <- decode.field("details", {
      use parameter_size <- decode.field("parameter_size", decode.string)
      decode.success(parameter_size)
    })
    decode.success(Model(name:, size: details))
  }

  let decoder = {
    use models <- decode.field("models", decode.list(model_decoder))
    decode.success(models)
  }

  json.parse(body, decoder)
  |> result.map_error(fn(err) {
    starlet.Decode("Failed to decode Ollama models: " <> string.inspect(err))
  })
}
