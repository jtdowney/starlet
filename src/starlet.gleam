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
//// let creds = ollama.credentials("http://localhost:11434")
//// let chat = ollama.chat(creds, "qwen3:0.6b")
////   |> starlet.user("Hello!")
////
//// let assert Ok(http_resp) = httpc.send(ollama.request(chat, creds))
//// let assert Ok(turn) = ollama.response(http_resp)
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
//// case provider.response(http_resp) {
////   Ok(turn) -> // success
////   Error(Http(status, body)) -> // non-200 response
////   Error(Decode(msg)) -> // JSON parse error
////   Error(Provider(name, msg, raw)) -> // provider error
//// }
//// ```

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import jscheam/schema
import starlet/tool

/// Errors that can occur when interacting with LLM providers.
pub type StarletError {
  /// Non-200 HTTP response from the provider
  Http(status: Int, body: String)
  /// Failed to parse the provider's JSON response
  Decode(message: String)
  /// Provider-specific error (model not found, rate limited, etc.)
  Provider(provider: String, message: String, raw: String)
  /// Tool execution error
  Tool(error: tool.ToolError)
  /// Rate limited by the provider
  RateLimited(retry_after: Option(Int))
}

/// Message types in a conversation.
pub type Message {
  UserMessage(content: String)
  AssistantMessage(content: String, tool_calls: List(tool.Call))
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
pub fn new_chat(model: String, ext: ext) -> Chat(ToolsOff, FreeText, Empty, ext) {
  Chat(
    model: model,
    system_prompt: None,
    messages: [],
    tools: [],
    temperature: None,
    max_tokens: None,
    ext: ext,
    json_schema: None,
  )
}

/// Sets the system prompt for the chat.
///
/// Must be called before adding any user messages.
pub fn system(
  chat: Chat(tools, format, Empty, ext),
  text: String,
) -> Chat(tools, format, Empty, ext) {
  Chat(..chat, system_prompt: Some(text))
}

/// Adds a user message to the chat.
///
/// This transitions the chat to the `Ready` state, allowing it to be sent.
pub fn user(
  chat: Chat(tools_state, format, state, ext),
  text: String,
) -> Chat(tools_state, format, Ready, ext) {
  Chat(..chat, messages: list.append(chat.messages, [UserMessage(text)]))
}

/// Adds an assistant message to the chat history.
///
/// Useful for providing few-shot examples or resuming a conversation.
/// Requires the chat to already have a user message.
pub fn assistant(
  chat: Chat(tools_state, format, Ready, ext),
  text: String,
) -> Chat(tools_state, format, Ready, ext) {
  Chat(
    ..chat,
    messages: list.append(chat.messages, [AssistantMessage(text, [])]),
  )
}

/// Sets the sampling temperature (typically 0.0 to 2.0).
///
/// Lower values make output more deterministic, higher values more creative.
pub fn temperature(
  chat: Chat(tools_state, format, state, ext),
  value: Float,
) -> Chat(tools_state, format, state, ext) {
  Chat(..chat, temperature: Some(value))
}

/// Sets the maximum number of tokens to generate in the response.
pub fn max_tokens(
  chat: Chat(tools_state, format, state, ext),
  value: Int,
) -> Chat(tools_state, format, state, ext) {
  Chat(..chat, max_tokens: Some(value))
}

/// Enable tools on a chat. Transitions ToolsOff → ToolsOn.
pub fn with_tools(
  chat: Chat(ToolsOff, format, state, ext),
  tool_defs: List(tool.Definition),
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
  output_schema: schema.Type,
) -> Chat(tools, JsonFormat, state, ext) {
  Chat(..chat, json_schema: Some(schema.to_json(output_schema)))
}

/// Disable JSON output, return to free text. Transitions JsonFormat → FreeText.
pub fn with_free_text(
  chat: Chat(tools, JsonFormat, state, ext),
) -> Chat(tools, FreeText, state, ext) {
  Chat(..chat, json_schema: None)
}

/// A model response from a single turn of conversation.
pub type Turn(tools, format, ext) {
  Turn(text: String, tool_calls: List(tool.Call), ext: ext)
}

/// Extracts the text content from a turn.
/// Only available for free text format turns.
pub fn text(turn: Turn(tools_state, FreeText, ext)) -> String {
  turn.text
}

/// Extracts the JSON content from a turn.
/// Only available for JSON format turns.
pub fn json(turn: Turn(tools_state, JsonFormat, ext)) -> String {
  turn.text
}

/// Extract tool calls from a turn. Only available when tools are enabled.
pub fn tool_calls(turn: Turn(ToolsOn, format, ext)) -> List(tool.Call) {
  turn.tool_calls
}

/// Check if a turn has any tool calls.
pub fn has_tool_calls(turn: Turn(ToolsOn, format, ext)) -> Bool {
  !list.is_empty(turn.tool_calls)
}

/// Append a turn's response to the chat history.
///
/// This updates the chat with the assistant's response, preparing it
/// for the next user message or tool result.
pub fn append_turn(
  chat: Chat(tools, format, Ready, ext),
  turn: Turn(tools, format, ext),
) -> Chat(tools, format, Ready, ext) {
  let message = AssistantMessage(turn.text, turn.tool_calls)
  Chat(..chat, messages: list.append(chat.messages, [message]), ext: turn.ext)
}

/// Apply pre-computed tool results to the chat.
/// Use when you've already run the tools yourself.
pub fn with_tool_results(
  chat: Chat(ToolsOn, format, Ready, ext),
  results: List(tool.ToolResult),
) -> Chat(ToolsOn, format, Ready, ext) {
  let result_messages =
    list.map(results, fn(r) {
      ToolResultMessage(
        call_id: r.id,
        name: r.name,
        content: json.to_string(r.output),
      )
    })
  Chat(..chat, messages: list.append(chat.messages, result_messages))
}

/// Run tools and apply their results in one step.
/// The runner is called for each tool call; errors short-circuit.
pub fn apply_tool_results(
  chat: Chat(ToolsOn, format, Ready, ext),
  calls: List(tool.Call),
  run: fn(tool.Call) -> Result(tool.ToolResult, tool.ToolError),
) -> Result(Chat(ToolsOn, format, Ready, ext), StarletError) {
  case run_all_tools(calls, run, []) {
    Ok(results) -> Ok(with_tool_results(chat, results))
    Error(e) -> Error(Tool(e))
  }
}

fn run_all_tools(
  calls: List(tool.Call),
  run: fn(tool.Call) -> Result(tool.ToolResult, tool.ToolError),
  acc: List(tool.ToolResult),
) -> Result(List(tool.ToolResult), tool.ToolError) {
  case calls {
    [] -> Ok(list.reverse(acc))
    [call, ..rest] -> {
      use tool_result <- result.try(run(call))
      run_all_tools(rest, run, [tool_result, ..acc])
    }
  }
}

/// Creates a Turn for testing purposes.
/// This is useful for testing append_turn and other Turn-related functions.
@internal
pub fn make_turn_for_testing(text: String) -> Turn(ToolsOff, FreeText, Nil) {
  Turn(text:, tool_calls: [], ext: Nil)
}
