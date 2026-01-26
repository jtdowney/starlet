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
//// let chat = ollama.chat(creds, "qwen3:0.6b")
////   |> starlet.user("Hello!")
////
//// let assert Ok(http_resp) = httpc.send(ollama.request(chat, creds))
//// let assert Ok(turn) = ollama.response(http_resp)
//// ```
////
//// ## Thinking Mode
////
//// For thinking-capable models (DeepSeek-R1, Qwen3), configure thinking:
////
//// ```gleam
//// ollama.chat(creds, "deepseek-r1")
//// |> ollama.with_thinking(ollama.ThinkingEnabled)
//// |> starlet.user("Solve this step by step...")
//// ```

import gleam/dynamic
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import starlet.{
  type Chat, type Message, type StarletError, type Turn, AssistantMessage, Chat,
  ToolResultMessage, UserMessage,
}
import starlet/internal/http as internal_http
import starlet/tool

const default_host = "localhost"

/// Thinking mode configuration for Ollama.
pub type Thinking {
  /// Enable thinking (boolean mode)
  ThinkingEnabled
  /// Disable thinking
  ThinkingDisabled
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
    thinking: Option(Thinking),
    /// Thinking content from the last response.
    thinking_content: Option(String),
  )
}

/// Connection credentials for Ollama.
pub type Credentials {
  Credentials(base_url: String)
}

/// Information about an available model.
pub type Model {
  Model(name: String, size: String)
}

/// Creates credentials for connecting to an Ollama server.
///
/// Example: `ollama.credentials("http://localhost:11434")`
pub fn credentials(base_url: String) -> Credentials {
  Credentials(base_url:)
}

/// Creates a new chat with the given credentials and model name.
pub fn chat(
  creds: Credentials,
  model: String,
) -> Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, Ext) {
  let _ = creds
  let default_ext = Ext(thinking: None, thinking_content: None)
  starlet.new_chat(model, default_ext)
}

/// Configure thinking mode for thinking-capable models.
/// When not set, the provider's default applies (enabled for thinking models).
pub fn with_thinking(
  chat: Chat(t, f, s, Ext),
  mode: Thinking,
) -> Chat(t, f, s, Ext) {
  Chat(..chat, ext: Ext(..chat.ext, thinking: Some(mode)))
}

/// Get the thinking content from an Ollama turn (if present).
pub fn thinking(turn: Turn(t, f, Ext)) -> Option(String) {
  turn.ext.thinking_content
}

/// Builds an HTTP request for sending a chat to Ollama.
///
/// The returned request can be sent with any HTTP client.
pub fn request(
  chat: Chat(tools, format, starlet.Ready, Ext),
  creds: Credentials,
) -> Result(Request(String), StarletError) {
  let body = json.to_string(encode_request(chat))

  use base_uri <- result.try(
    uri.parse(creds.base_url)
    |> result.replace_error(starlet.Http(
      0,
      "Invalid base URL: " <> creds.base_url,
    )),
  )

  let base_uri = internal_http.with_defaults(base_uri, "http", default_host)
  use http_request <- result.try(
    request.from_uri(base_uri)
    |> result.replace_error(starlet.Http(
      0,
      "Invalid base URL: " <> creds.base_url,
    )),
  )

  Ok(
    http_request
    |> request.set_method(http.Post)
    |> request.set_path(base_uri.path <> "/api/chat")
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body),
  )
}

/// Decodes an HTTP response from Ollama into a Turn.
pub fn response(
  resp: Response(String),
) -> Result(Turn(tools, format, Ext), StarletError) {
  case resp.status {
    200 -> {
      use #(text, thinking_content, tool_calls) <- result.map(decode_response(
        resp.body,
      ))
      let ext = Ext(thinking: None, thinking_content: thinking_content)
      starlet.Turn(text:, tool_calls:, ext:)
    }
    429 -> {
      let retry_after = internal_http.parse_retry_after(resp.headers)
      Error(starlet.RateLimited(retry_after))
    }
    status -> Error(starlet.Http(status:, body: resp.body))
  }
}

/// Encodes a chat into JSON for the Ollama `/api/chat` endpoint.
@internal
pub fn encode_request(chat: Chat(tools, format, starlet.Ready, Ext)) -> Json {
  let messages = build_messages(chat.system_prompt, chat.messages)
  let options = build_options(chat.temperature, chat.max_tokens)
  let tools = build_tools(chat.tools)

  let base = [
    #("model", json.string(chat.model)),
    #("messages", json.array(messages, fn(m) { m })),
    #("stream", json.bool(False)),
  ]

  let base = case options {
    Some(opts) -> list.append(base, [#("options", opts)])
    None -> base
  }

  let base = case tools {
    Some(t) -> list.append(base, [#("tools", t)])
    None -> base
  }

  let base = case chat.ext.thinking {
    Some(ThinkingEnabled) -> list.append(base, [#("think", json.bool(True))])
    Some(ThinkingDisabled) -> list.append(base, [#("think", json.bool(False))])
    Some(ThinkingLow) ->
      list.append(base, [
        #("think", json.bool(True)),
        #("reasoning_effort", json.string("low")),
      ])
    Some(ThinkingMedium) ->
      list.append(base, [
        #("think", json.bool(True)),
        #("reasoning_effort", json.string("medium")),
      ])
    Some(ThinkingHigh) ->
      list.append(base, [
        #("think", json.bool(True)),
        #("reasoning_effort", json.string("high")),
      ])
    None -> base
  }

  let base = case chat.json_schema {
    Some(schema) -> list.append(base, [#("format", schema)])
    None -> base
  }

  json.object(base)
}

fn build_messages(
  system_prompt: Option(String),
  messages: List(Message),
) -> List(Json) {
  let system_msgs = case system_prompt {
    Some(prompt) -> [
      json.object([
        #("role", json.string("system")),
        #("content", json.string(prompt)),
      ]),
    ]
    None -> []
  }

  let chat_msgs =
    list.map(messages, fn(msg) {
      case msg {
        UserMessage(content) ->
          json.object([
            #("role", json.string("user")),
            #("content", json.string(content)),
          ])
        AssistantMessage(content, tool_calls) ->
          case tool_calls {
            [] ->
              json.object([
                #("role", json.string("assistant")),
                #("content", json.string(content)),
              ])
            _ ->
              json.object([
                #("role", json.string("assistant")),
                #("content", json.string(content)),
                #("tool_calls", json.array(tool_calls, encode_tool_call)),
              ])
          }
        ToolResultMessage(_call_id, name, content) ->
          json.object([
            #("role", json.string("tool")),
            #("name", json.string(name)),
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
    Some(t) -> [#("temperature", json.float(t)), ..opts]
    None -> opts
  }

  let opts = case max_tokens {
    Some(n) -> [#("num_predict", json.int(n)), ..opts]
    None -> opts
  }

  case opts {
    [] -> None
    _ -> Some(json.object(opts))
  }
}

fn build_tools(tools: List(tool.Definition)) -> Option(Json) {
  case tools {
    [] -> None
    _ ->
      Some(
        json.array(tools, fn(t) {
          case t {
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

/// Decodes a JSON response from the Ollama `/api/chat` endpoint.
/// Returns the text, thinking content, and tool calls.
@internal
pub fn decode_response(
  body: String,
) -> Result(#(String, Option(String), List(tool.Call)), StarletError) {
  let arguments_decoder =
    decode.one_of(
      {
        use s <- decode.then(decode.string)
        case json.parse(s, decode.dynamic) {
          Ok(dyn) -> decode.success(dyn)
          Error(_) -> decode.failure(dynamic.nil(), "parsable json string")
        }
      },
      or: [decode.dynamic],
    )

  let function_decoder = {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("arguments", arguments_decoder)
    decode.success(#(name, arguments))
  }

  let tool_call_decoder = {
    use function <- decode.field("function", function_decoder)
    use id <- decode.optional_field("id", "", decode.string)
    let #(name, arguments) = function
    let id = case id {
      "" -> name <> "_call"
      i -> i
    }
    decode.success(tool.Call(id:, name:, arguments:))
  }

  let message_decoder = {
    use content <- decode.optional_field("content", "", decode.string)
    use thinking <- decode.optional_field("thinking", None, {
      use t <- decode.then(decode.string)
      decode.success(Some(t))
    })
    use tool_calls <- decode.optional_field(
      "tool_calls",
      [],
      decode.list(tool_call_decoder),
    )
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
pub fn list_models_request(
  creds: Credentials,
) -> Result(Request(String), StarletError) {
  use base_uri <- result.try(
    uri.parse(creds.base_url)
    |> result.replace_error(starlet.Http(
      0,
      "Invalid base URL: " <> creds.base_url,
    )),
  )

  let base_uri = internal_http.with_defaults(base_uri, "http", default_host)
  use http_request <- result.try(
    request.from_uri(base_uri)
    |> result.replace_error(starlet.Http(
      0,
      "Invalid base URL: " <> creds.base_url,
    )),
  )

  Ok(
    http_request
    |> request.set_method(http.Get)
    |> request.set_path(base_uri.path <> "/api/tags"),
  )
}

/// Decodes an HTTP response containing the list of models.
pub fn list_models_response(
  resp: Response(String),
) -> Result(List(Model), StarletError) {
  case resp.status {
    200 -> decode_models(resp.body)
    429 -> {
      let retry_after = internal_http.parse_retry_after(resp.headers)
      Error(starlet.RateLimited(retry_after))
    }
    status -> Error(starlet.Http(status:, body: resp.body))
  }
}

/// Decodes a JSON response from the Ollama `/api/tags` endpoint.
@internal
pub fn decode_models(body: String) -> Result(List(Model), starlet.StarletError) {
  let model_decoder = {
    use name <- decode.field("name", decode.string)
    use details <- decode.field("details", {
      use parameter_size <- decode.field("parameter_size", decode.string)
      decode.success(parameter_size)
    })
    decode.success(Model(name: name, size: details))
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
