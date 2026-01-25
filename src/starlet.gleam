//// A unified, provider-agnostic interface for LLM APIs.
////
//// ## Quick Start
////
//// ```gleam
//// import starlet
//// import starlet/ollama
////
//// let client = ollama.new("http://localhost:11434")
////
//// let chat =
////   starlet.chat(client, "qwen3:0.6b")
////   |> starlet.system("You are a helpful assistant.")
////   |> starlet.user("Hello!")
////
//// case starlet.send(chat) {
////   Ok(#(new_chat, turn)) -> starlet.text(turn)
////   Error(err) -> // handle error
//// }
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
//// import starlet.{Transport, Http, Decode, Provider}
////
//// case starlet.send(chat) {
////   Ok(#(chat, turn)) -> // success
////   Error(Transport(msg)) -> // network error
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

/// Default timeout for HTTP requests in milliseconds (60 seconds).
const default_timeout_ms = 60_000

/// Errors that can occur when interacting with LLM providers.
pub type StarletError {
  /// Network-level error (connection refused, timeout, etc.)
  Transport(message: String)
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

@internal
pub type Message {
  UserMessage(content: String)
  AssistantMessage(content: String, tool_calls: List(tool.Call))
  ToolResultMessage(call_id: String, name: String, content: String)
}

@internal
pub type Request {
  Request(
    model: String,
    system_prompt: Option(String),
    messages: List(Message),
    tools: List(tool.Definition),
    temperature: Option(Float),
    max_tokens: Option(Int),
    json_schema: Option(Json),
    timeout_ms: Int,
  )
}

@internal
pub type Response {
  Response(text: String, tool_calls: List(tool.Call))
}

@internal
pub type ProviderConfig(ext) {
  ProviderConfig(
    name: String,
    base_url: String,
    send: fn(Request, ext) -> Result(#(Response, ext), StarletError),
  )
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
pub type NoExt {
  NoExt
}

/// The result of a single step in a tool-enabled conversation.
pub type Step(format, ext) {
  /// Model responded with final text, no tool calls.
  Done(
    chat: Chat(ToolsOn, format, Ready, ext),
    turn: Turn(ToolsOn, format, ext),
  )
  /// Model wants to call tools. Provide results to continue.
  ToolCall(
    chat: Chat(ToolsOn, format, Ready, ext),
    turn: Turn(ToolsOn, format, ext),
    calls: List(tool.Call),
  )
}

/// An LLM provider client. Create one using a provider module like `ollama.new()`.
///
/// The type parameter tracks the provider's extension type, allowing
/// provider-specific features (like reasoning effort) to flow through naturally.
pub type Client(ext) {
  Client(p: ProviderConfig(ext), default_ext: ext)
}

/// Returns the name of the provider (e.g., "ollama", "openai").
pub fn provider_name(client: Client(ext)) -> String {
  let Client(p, _) = client
  p.name
}

@internal
pub fn mock_client(
  respond: fn(Request) -> Result(Response, StarletError),
) -> Client(NoExt) {
  let send = fn(req, ext) {
    result.map(respond(req), fn(response) { #(response, ext) })
  }
  Client(ProviderConfig(name: "mock", base_url: "", send: send), NoExt)
}

/// Internal constructor for provider modules to create clients.
/// Not intended for direct use by library consumers.
@internal
pub fn from_provider(p: ProviderConfig(ext), default_ext: ext) -> Client(ext) {
  Client(p, default_ext)
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
    client: Client(ext),
    model: String,
    system_prompt: Option(String),
    messages: List(Message),
    tools: List(tool.Definition),
    temperature: Option(Float),
    max_tokens: Option(Int),
    ext: ext,
    json_schema: Option(Json),
    timeout_ms: Int,
  )
}

/// Creates a new chat with the given client and model name.
///
/// The chat inherits the provider's extension type from the client,
/// allowing provider-specific features to be configured.
///
/// ```gleam
/// let chat = starlet.chat(client, "qwen3:0.6b")
/// ```
pub fn chat(
  client: Client(ext),
  model: String,
) -> Chat(ToolsOff, FreeText, Empty, ext) {
  let Client(_, default_ext) = client
  Chat(
    client: client,
    model: model,
    system_prompt: None,
    messages: [],
    tools: [],
    temperature: None,
    max_tokens: None,
    ext: default_ext,
    json_schema: None,
    timeout_ms: default_timeout_ms,
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

/// Sets the HTTP request timeout in milliseconds.
///
/// Default is 60,000ms (60 seconds). Increase for long-running requests.
///
/// ```gleam
/// starlet.chat(client, "gpt-4o")
/// |> starlet.with_timeout(120_000)  // 2 minutes
/// |> starlet.user("Solve this complex problem...")
/// |> starlet.send()
/// ```
pub fn with_timeout(
  chat: Chat(tools_state, format, state, ext),
  timeout_ms: Int,
) -> Chat(tools_state, format, state, ext) {
  Chat(..chat, timeout_ms: timeout_ms)
}

/// Returns the current timeout in milliseconds.
pub fn timeout(chat: Chat(tools_state, format, state, ext)) -> Int {
  chat.timeout_ms
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

@internal
pub fn make_turn_for_testing(content: String) -> Turn(ToolsOff, FreeText, NoExt) {
  Turn(text: content, tool_calls: [], ext: NoExt)
}

/// Sends the chat to the LLM and returns the response.
///
/// Returns a tuple of the updated chat (with the assistant's response appended
/// to the history) and the turn containing the response text.
///
/// ```gleam
/// case starlet.send(chat) {
///   Ok(#(new_chat, turn)) -> starlet.text(turn)
///   Error(err) -> // handle error
/// }
/// ```
pub fn send(
  chat: Chat(tools_state, format, Ready, ext),
) -> Result(
  #(Chat(tools_state, format, Ready, ext), Turn(tools_state, format, ext)),
  StarletError,
) {
  let Chat(
    client:,
    model:,
    system_prompt:,
    messages:,
    tools:,
    temperature:,
    max_tokens:,
    ext:,
    json_schema:,
    timeout_ms:,
  ) = chat
  let Client(p, _) = client

  let request =
    Request(
      model: model,
      system_prompt: system_prompt,
      messages: messages,
      tools: tools,
      temperature: temperature,
      max_tokens: max_tokens,
      json_schema: json_schema,
      timeout_ms: timeout_ms,
    )

  use #(response, new_ext) <- result.map(p.send(request, ext))
  let new_messages =
    list.append(messages, [AssistantMessage(response.text, response.tool_calls)])
  let new_chat = Chat(..chat, messages: new_messages, ext: new_ext)
  let turn =
    Turn(text: response.text, tool_calls: response.tool_calls, ext: new_ext)
  #(new_chat, turn)
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

/// Send a tools-enabled chat and categorize the response.
/// Returns either Done (no tool calls) or ToolCall (tools requested).
pub fn step(
  chat: Chat(ToolsOn, format, Ready, ext),
) -> Result(Step(format, ext), StarletError) {
  use #(new_chat, turn) <- result.map(send(chat))
  case has_tool_calls(turn) {
    True -> ToolCall(chat: new_chat, turn: turn, calls: turn.tool_calls)
    False -> Done(chat: new_chat, turn: turn)
  }
}
