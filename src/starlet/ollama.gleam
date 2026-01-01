//// Ollama provider for starlet.
////
//// [Ollama](https://ollama.com) is a local LLM runtime that supports many
//// open-source models.
////
//// ## Usage
////
//// ```gleam
//// import starlet
//// import starlet/ollama
////
//// let client = ollama.new("http://localhost:11434")
////
//// starlet.chat(client, "qwen3:0.6b")
//// |> starlet.user("Hello!")
//// |> starlet.send()
//// ```
////
//// ## Thinking Mode
////
//// For thinking-capable models (DeepSeek-R1, Qwen3), configure thinking:
////
//// ```gleam
//// starlet.chat(client, "deepseek-r1")
//// |> ollama.with_thinking(ollama.ThinkingEnabled)
//// |> starlet.user("Solve this step by step...")
//// |> starlet.send()
//// ```

import gleam/dynamic
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import starlet.{
  type Chat, type Client, type Message, type Request, type Response,
  type StarletError, type Turn, AssistantMessage, Chat, ProviderConfig, Response,
  ToolResultMessage, UserMessage,
}
import starlet/internal/http as internal_http
import starlet/tool

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

/// Information about an available model.
pub type Model {
  Model(name: String, size: String)
}

/// Creates a new Ollama client with the given base URL.
///
/// Example: `ollama.new("http://localhost:11434")`
pub fn new(base_url: String) -> Client(Ext) {
  let config =
    ProviderConfig(name: "ollama", base_url: base_url, send: fn(req, ext) {
      send_request(base_url, req, ext)
    })
  let default_ext = Ext(thinking: None, thinking_content: None)
  starlet.from_provider(config, default_ext)
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

fn send_request(
  base_url: String,
  req: Request,
  ext: Ext,
) -> Result(#(Response, Ext), StarletError) {
  let body = json.to_string(encode_request(req, ext))

  case uri.parse(base_url) {
    Ok(base_uri) -> {
      let scheme = option.unwrap(base_uri.scheme, "http")
      let host = option.unwrap(base_uri.host, "localhost")
      let port = base_uri.port
      let base_path = base_uri.path

      let http_request =
        request.new()
        |> request.set_method(http.Post)
        |> request.set_scheme(case scheme {
          "https" -> http.Https
          _ -> http.Http
        })
        |> request.set_host(host)
        |> internal_http.set_optional_port(port)
        |> request.set_path(base_path <> "/api/chat")
        |> request.set_header("content-type", "application/json")
        |> request.set_body(body)

      let config = httpc.configure() |> httpc.timeout(req.timeout_ms)
      case httpc.dispatch(config, http_request) {
        Ok(response) ->
          case response.status {
            200 ->
              case decode_response(response.body) {
                Ok(#(resp, thinking_content)) -> {
                  let new_ext = Ext(..ext, thinking_content: thinking_content)
                  Ok(#(resp, new_ext))
                }
                Error(e) -> Error(e)
              }
            429 -> {
              let retry_after =
                internal_http.parse_retry_after(response.headers)
              Error(starlet.RateLimited(retry_after))
            }
            status -> Error(starlet.Http(status: status, body: response.body))
          }
        Error(err) -> Error(starlet.Transport(string.inspect(err)))
      }
    }
    Error(_) -> Error(starlet.Transport("Invalid base URL: " <> base_url))
  }
}

/// Encodes a request into JSON for the Ollama `/api/chat` endpoint.
@internal
pub fn encode_request(req: Request, ext: Ext) -> Json {
  let messages = build_messages(req.system_prompt, req.messages)
  let options = build_options(req.temperature, req.max_tokens)
  let tools = build_tools(req.tools)

  let base = [
    #("model", json.string(req.model)),
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

  let base = case ext.thinking {
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

  let base = case req.json_schema {
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
/// Returns the Response and any thinking content.
@internal
pub fn decode_response(
  body: String,
) -> Result(#(Response, Option(String)), StarletError) {
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
    decode.success(#(Response(text: content, tool_calls: tool_calls), thinking))
  }

  json.parse(body, decoder)
  |> result.map_error(fn(err) {
    starlet.Decode("Failed to decode Ollama response: " <> string.inspect(err))
  })
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

/// Lists available models from the Ollama server.
pub fn list_models(
  base_url: String,
) -> Result(List(Model), starlet.StarletError) {
  case uri.parse(base_url) {
    Ok(base_uri) -> {
      let scheme = option.unwrap(base_uri.scheme, "http")
      let host = option.unwrap(base_uri.host, "localhost")
      let port = base_uri.port
      let base_path = base_uri.path

      let http_request =
        request.new()
        |> request.set_method(http.Get)
        |> request.set_scheme(case scheme {
          "https" -> http.Https
          _ -> http.Http
        })
        |> request.set_host(host)
        |> internal_http.set_optional_port(port)
        |> request.set_path(base_path <> "/api/tags")

      case httpc.send(http_request) {
        Ok(response) ->
          case response.status {
            200 -> decode_models(response.body)
            status -> Error(starlet.Http(status: status, body: response.body))
          }
        Error(err) -> Error(starlet.Transport(string.inspect(err)))
      }
    }
    Error(_) -> Error(starlet.Transport("Invalid base URL: " <> base_url))
  }
}
