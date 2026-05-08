//// A unified, provider-agnostic interface for LLM APIs.
////
//// Starlet uses a sans-IO architecture: it provides pure functions for building
//// HTTP requests and decoding responses, but never performs IO itself.
////
//// ## Quick Start
////
//// ```gleam
//// import gleam/httpc
//// import starlet
//// import starlet/ollama
////
//// let assert Ok(creds) = ollama.credentials("http://localhost:11434")
//// let chat = ollama.chat("qwen3:0.6b")
////   |> starlet.user("Hello!")
////
//// let assert Ok(http_resp) = httpc.send(ollama.request(chat, creds))
//// let assert Ok(turn) = ollama.response(chat, http_resp)
//// let chat = starlet.append_turn(chat, turn)
////
//// io.println(starlet.text(turn))
//// ```
////
//// ## Typestate
////
//// The `Chat` type uses phantom types to enforce correct usage at compile time:
//// - You must add a user message before sending
//// - System prompts can only be set before adding messages
////
//// ## Error Handling
////
//// ```gleam
//// case provider.response(chat, http_resp) {
////   Ok(turn) -> // success
////   Error(starlet.Http(status, body)) -> // non-200 response
////   Error(starlet.Decode(msg)) -> // JSON parse error
////   Error(starlet.Provider(name, msg, raw)) -> // provider error
//// }
//// ```

import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import jscheam/schema
import starlet/tool

/// Errors that can occur when interacting with LLM providers.
pub type Error {
  /// Non-200 HTTP response from the provider
  Http(status: Int, body: String)
  /// Failed to parse the provider's JSON response
  Decode(message: String)
  /// Provider-specific error (model not found, rate limited, etc.)
  Provider(provider: String, message: String, raw: String)
  /// Tool execution error
  Tool(error: tool.Error)
  /// Rate limited by the provider
  RateLimited(retry_after: Option(Int))
  /// Invalid or unparseable base URL in provider credentials
  InvalidUrl(url: String)
  /// Invalid argument passed to a builder function (e.g., thinking budget out of range)
  InvalidArgument(message: String)
  /// Transport-level error from the HTTP client (connection refused, timeout, etc.)
  Transport(message: String)
}

/// Render an `Error` as a human-readable string.
///
/// Use this so consumers don't need to keep a private renderer in sync
/// with new variants.
pub fn error_to_string(err: Error) -> String {
  case err {
    Http(status, body) -> "HTTP " <> int.to_string(status) <> ": " <> body
    Decode(message) -> "Decode error: " <> message
    Provider(provider, message, raw) ->
      provider <> " error: " <> message <> "\n" <> raw
    Tool(tool.NotFound(name)) -> "Tool not found: " <> name
    Tool(tool.InvalidArguments(message)) -> "Invalid arguments: " <> message
    Tool(tool.ExecutionFailed(message)) -> "Tool execution failed: " <> message
    RateLimited(option.Some(seconds)) ->
      "Rate limited, retry after " <> int.to_string(seconds) <> "s"
    RateLimited(option.None) -> "Rate limited"
    InvalidUrl(url) -> "Invalid URL: " <> url
    InvalidArgument(message) -> "Invalid argument: " <> message
    Transport(message) -> "Transport error: " <> message
  }
}

/// Events emitted during streaming, unified across all providers.
pub type StreamEvent {
  /// Incremental text token
  TextDelta(text: String)
  /// A tool call is starting (id and function name known)
  ToolCallStart(id: String, name: String)
  /// Incremental arguments for an in-progress tool call
  ToolCallDelta(id: String, arguments: String)
  /// Incremental thinking/reasoning content
  ThinkingDelta(text: String)
  /// Provider sent an error mid-stream
  StreamError(error: Error)
  /// Stream is complete
  Done
}

/// Message types in a conversation.
pub type Message {
  /// A message from the user.
  UserMessage(content: String)
  /// A message from the assistant, possibly including tool calls.
  AssistantMessage(content: String, tool_calls: List(tool.Call))
  /// The result of a tool execution, sent back to the model.
  ToolResultMessage(call_id: String, name: String, content: String)
}

@internal
pub type ToolsOff {
  ToolsOff
}

@internal
pub type ToolsOn {
  ToolsOn
}

@internal
pub type FreeText {
  FreeText
}

@internal
pub type JsonFormat {
  JsonFormat
}

@internal
pub type Empty {
  Empty
}

@internal
pub type Ready {
  Ready
}

@internal
pub type Responded {
  Responded
}

/// A conversation builder that accumulates messages and settings.
///
/// The type parameters track capabilities at compile time:
/// - `tools`: Whether tool calling is enabled
/// - `format`: Output format constraint (free text or JSON)
/// - `state`: Whether the chat is ready to send (has at least one user message)
/// - `ext`: Provider-specific extension data
pub type Chat(tools, format, state, ext) {
  Chat(
    model: String,
    system_prompt: Option(String),
    messages: List(Message),
    tools: List(tool.Definition),
    temperature: Option(Float),
    max_tokens: Option(Int),
    ext: ext,
    json_schema: Option(Json),
  )
}

/// Creates a new chat with the given model and extension data.
/// Provider modules should call this to create chats.
@internal
pub fn new_chat(
  model: String,
  ext: ext,
) -> Chat(ToolsOff, FreeText, Empty, ext) {
  Chat(
    model:,
    system_prompt: option.None,
    messages: [],
    tools: [],
    temperature: option.None,
    max_tokens: option.None,
    ext:,
    json_schema: option.None,
  )
}

/// Sets the system prompt for the chat.
///
/// Must be called before adding any user messages.
pub fn system(
  chat: Chat(tools, format, Empty, ext),
  text: String,
) -> Chat(tools, format, Empty, ext) {
  Chat(..chat, system_prompt: option.Some(text))
}

/// Adds a user message to the chat.
///
/// Transitions the chat to the `Ready` state, allowing it to be sent.
pub fn user(
  chat: Chat(tools_state, format, state, ext),
  text: String,
) -> Chat(tools_state, format, Ready, ext) {
  Chat(..chat, messages: list.append(chat.messages, [UserMessage(text)]))
}

/// Replace the provider extension data while preserving the current state.
///
/// Stable setter for the `ext` field; prefer this over the
/// `Chat(..chat, ext: ...)` record-update form.
pub fn with_ext(
  chat: Chat(tools, format, state, ext),
  ext: ext,
) -> Chat(tools, format, state, ext) {
  Chat(..chat, ext:)
}

/// Sets the sampling temperature (typically 0.0 to 2.0).
///
/// Lower values make output more deterministic, higher values more creative.
pub fn temperature(
  chat: Chat(tools_state, format, state, ext),
  value: Float,
) -> Chat(tools_state, format, state, ext) {
  Chat(..chat, temperature: option.Some(value))
}

/// Sets the maximum number of tokens to generate in the response.
pub fn max_tokens(
  chat: Chat(tools_state, format, state, ext),
  value: Int,
) -> Chat(tools_state, format, state, ext) {
  Chat(..chat, max_tokens: option.Some(value))
}

/// Enable tools on a chat. Transitions ToolsOff → ToolsOn.
pub fn with_tools(
  chat: Chat(ToolsOff, format, state, ext),
  definitions tool_defs: List(tool.Definition),
) -> Chat(ToolsOn, format, state, ext) {
  Chat(..chat, tools: tool_defs)
}

/// Get the tool definitions from a tools-enabled chat.
pub fn tools(chat: Chat(ToolsOn, format, state, ext)) -> List(tool.Definition) {
  chat.tools
}

/// Enable JSON output with a schema. Transitions FreeText → JsonFormat.
///
/// The model will be constrained to output valid JSON matching the schema.
/// Use `json(turn)` to extract the JSON string from the response.
pub fn with_json_output(
  chat: Chat(tools, FreeText, state, ext),
  schema output_schema: schema.Type,
) -> Chat(tools, JsonFormat, state, ext) {
  Chat(..chat, json_schema: option.Some(schema.to_json(output_schema)))
}

/// Disable JSON output, return to free text. Transitions JsonFormat → FreeText.
pub fn with_free_text(
  chat: Chat(tools, JsonFormat, state, ext),
) -> Chat(tools, FreeText, state, ext) {
  Chat(..chat, json_schema: option.None)
}

/// A model response from a single turn of conversation.
pub type Turn(tools, format, ext) {
  Turn(text: String, tool_calls: List(tool.Call), ext: ext)
}

/// Extracts the text content from a turn.
pub fn text(turn: Turn(tools_state, FreeText, ext)) -> String {
  turn.text
}

/// Extracts the JSON content from a turn.
pub fn json(turn: Turn(tools_state, JsonFormat, ext)) -> String {
  turn.text
}

/// Extract tool calls from a turn.
pub fn tool_calls(turn: Turn(ToolsOn, format, ext)) -> List(tool.Call) {
  turn.tool_calls
}

/// Check if a turn has any tool calls.
pub fn has_tool_calls(turn: Turn(ToolsOn, format, ext)) -> Bool {
  !list.is_empty(turn.tool_calls)
}

/// Append a turn's response to the chat history.
pub fn append_turn(
  chat: Chat(tools, format, Ready, ext),
  turn: Turn(tools, format, ext),
) -> Chat(tools, format, Responded, ext) {
  let message = AssistantMessage(turn.text, turn.tool_calls)
  Chat(..chat, messages: list.append(chat.messages, [message]), ext: turn.ext)
}

/// Apply pre-computed tool results to the chat.
/// Use when you've already run the tools yourself.
pub fn with_tool_results(
  chat: Chat(ToolsOn, format, Responded, ext),
  results results: List(tool.ToolResult),
) -> Chat(ToolsOn, format, Ready, ext) {
  let result_messages =
    list.map(results, fn(tool_result) {
      ToolResultMessage(
        call_id: tool_result.id,
        name: tool_result.name,
        content: json.to_string(tool_result.output),
      )
    })
  Chat(..chat, messages: list.append(chat.messages, result_messages))
}

/// Run tools and apply their results in one step.
/// The runner is called for each tool call; errors short-circuit.
pub fn apply_tool_results(
  chat: Chat(ToolsOn, format, Responded, ext),
  calls calls: List(tool.Call),
  with run: fn(tool.Call) -> Result(tool.ToolResult, tool.Error),
) -> Result(Chat(ToolsOn, format, Ready, ext), Error) {
  case list.try_map(calls, run) {
    Ok(results) -> Ok(with_tool_results(chat, results))
    Error(tool_error) -> Error(Tool(tool_error))
  }
}

/// Maps an HTTP client error into a starlet error.
///
/// Converts any error type to a `Transport` error using `string.inspect`.
/// Works with any HTTP client (httpc, fetch, etc.).
///
/// ```gleam
/// httpc.send(req)
/// |> starlet.map_transport_error
/// |> result.try(provider.response(chat, _))
/// ```
pub fn map_transport_error(res: Result(a, error)) -> Result(a, Error) {
  result.map_error(res, fn(err) { Transport(string.inspect(err)) })
}

/// Creates a Turn for testing purposes.
/// This is useful for testing append_turn and other Turn-related functions.
@internal
pub fn make_turn_for_testing(text: String) -> Turn(ToolsOff, FreeText, Nil) {
  Turn(text:, tool_calls: [], ext: Nil)
}
