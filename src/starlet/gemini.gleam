//// Google Gemini provider for starlet.
////
//// Uses the [Gemini API](https://ai.google.dev/gemini-api/docs) via Google AI Studio.
////
//// ## Usage
////
//// ```gleam
//// import starlet
//// import starlet/gemini
////
//// let client = gemini.new(api_key)
////
//// starlet.chat(client, "gemini-2.5-flash")
//// |> starlet.user("Hello!")
//// |> starlet.send()
//// ```
////
//// ## Thinking Mode
////
//// For Gemini 2.5+ models, configure thinking:
////
//// ```gleam
//// starlet.chat(client, "gemini-2.5-flash")
//// |> gemini.with_thinking(gemini.ThinkingDynamic)
//// |> starlet.user("Solve this step by step...")
//// |> starlet.send()
//// ```

import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import starlet.{
  type Chat, type Client, type Message, type Request, type Response,
  type StarletError, type Turn, AssistantMessage, Chat, ProviderConfig,
  ToolResultMessage, UserMessage,
}
import starlet/internal/http as internal_http
import starlet/tool

/// Thinking budget for Gemini 2.5+ models.
pub type ThinkingBudget {
  /// Disable thinking entirely
  ThinkingOff
  /// Model adjusts budget based on request complexity
  ThinkingDynamic
  /// Fixed token budget (1-32768)
  ThinkingFixed(tokens: Int)
}

/// Gemini provider extension type.
pub type Ext {
  Ext(
    /// Thinking budget configuration.
    thinking_budget: Option(ThinkingBudget),
    /// Thinking content from the last response.
    thinking: Option(String),
  )
}

/// Information about an available model.
pub type Model {
  Model(id: String, display_name: String)
}

/// Creates a new Gemini client with the given API key.
/// Uses the default base URL: https://generativelanguage.googleapis.com
pub fn new(api_key: String) -> Client(Ext) {
  new_with_base_url(api_key, "https://generativelanguage.googleapis.com")
}

/// Creates a new Gemini client with a custom base URL.
pub fn new_with_base_url(api_key: String, base_url: String) -> Client(Ext) {
  let config =
    ProviderConfig(name: "gemini", base_url: base_url, send: fn(req, ext) {
      send_request(api_key, base_url, req, ext)
    })
  let default_ext = Ext(thinking_budget: None, thinking: None)
  starlet.from_provider(config, default_ext)
}

/// Enable thinking mode for Gemini 2.5+ models.
/// Validates that ThinkingFixed is within range 1-32768.
pub fn with_thinking(
  chat: Chat(t, f, s, Ext),
  budget: ThinkingBudget,
) -> Result(Chat(t, f, s, Ext), StarletError) {
  case budget {
    ThinkingFixed(tokens) if tokens < 1 ->
      Error(starlet.Provider(
        provider: "gemini",
        message: "thinking budget must be at least 1 token",
        raw: "",
      ))
    ThinkingFixed(tokens) if tokens > 32_768 ->
      Error(starlet.Provider(
        provider: "gemini",
        message: "thinking budget must be at most 32768 tokens",
        raw: "",
      ))
    _ -> Ok(Chat(..chat, ext: Ext(..chat.ext, thinking_budget: Some(budget))))
  }
}

/// Get the thinking content from a Gemini turn (if present).
pub fn thinking(turn: Turn(t, f, Ext)) -> Option(String) {
  turn.ext.thinking
}

/// Lists available Gemini models.
pub fn list_models(api_key: String) -> Result(List(Model), StarletError) {
  list_models_with_base_url(
    api_key,
    "https://generativelanguage.googleapis.com",
  )
}

/// Lists available Gemini models with a custom base URL.
pub fn list_models_with_base_url(
  api_key: String,
  base_url: String,
) -> Result(List(Model), StarletError) {
  case uri.parse(base_url) {
    Ok(base_uri) -> {
      let scheme = case option.unwrap(base_uri.scheme, "https") {
        "http" -> http.Http
        _ -> http.Https
      }
      let host =
        option.unwrap(base_uri.host, "generativelanguage.googleapis.com")
      let base_path = base_uri.path

      let http_request =
        request.new()
        |> request.set_method(http.Get)
        |> request.set_scheme(scheme)
        |> request.set_host(host)
        |> internal_http.set_optional_port(base_uri.port)
        |> request.set_path(base_path <> "/v1beta/models")
        |> request.set_header("x-goog-api-key", api_key)

      case httpc.send(http_request) {
        Ok(response) ->
          case response.status {
            200 -> decode_models(response.body)
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

fn decode_models(body: String) -> Result(List(Model), StarletError) {
  let model_decoder = {
    use name <- decode.field("name", decode.string)
    use display_name <- decode.field("displayName", decode.string)
    let id = case string.split(name, "/") {
      [_, model_id] -> model_id
      _ -> name
    }
    decode.success(Model(id: id, display_name: display_name))
  }

  let decoder = {
    use models <- decode.field("models", decode.list(model_decoder))
    decode.success(models)
  }

  case json.parse(body, decoder) {
    Ok(models) -> Ok(models)
    Error(err) ->
      Error(starlet.Decode(
        "Failed to decode Gemini models: " <> string.inspect(err),
      ))
  }
}

/// Encodes a request into JSON for the Gemini generateContent endpoint.
@internal
pub fn encode_request(req: Request, ext: Ext) -> Json {
  let contents = build_contents(req.messages)

  let base = [#("contents", json.array(contents, fn(c) { c }))]

  // Add systemInstruction if present
  let base = case req.system_prompt {
    Some(prompt) ->
      list.append(base, [
        #(
          "systemInstruction",
          json.object([
            #(
              "parts",
              json.array([json.object([#("text", json.string(prompt))])], fn(p) {
                p
              }),
            ),
          ]),
        ),
      ])
    None -> base
  }

  // Add tools if present
  let base = case req.tools {
    [] -> base
    tools ->
      list.append(base, [
        #(
          "tools",
          json.array([build_function_declarations(tools)], fn(t) { t }),
        ),
      ])
  }

  // Add generationConfig if any options are set
  let gen_config = build_generation_config(req, ext)
  let base = case gen_config {
    Some(config) -> list.append(base, [#("generationConfig", config)])
    None -> base
  }

  json.object(base)
}

fn build_contents(messages: List(Message)) -> List(Json) {
  list.map(messages, fn(msg) {
    case msg {
      UserMessage(content) ->
        json.object([
          #("role", json.string("user")),
          #(
            "parts",
            json.array([json.object([#("text", json.string(content))])], fn(p) {
              p
            }),
          ),
        ])
      AssistantMessage(content, tool_calls) ->
        case tool_calls {
          [] ->
            json.object([
              #("role", json.string("model")),
              #(
                "parts",
                json.array(
                  [json.object([#("text", json.string(content))])],
                  fn(p) { p },
                ),
              ),
            ])
          _ -> {
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
            json.object([
              #("role", json.string("model")),
              #(
                "parts",
                json.array(list.append(text_parts, call_parts), fn(p) { p }),
              ),
            ])
          }
        }
      ToolResultMessage(_call_id, name, content) -> {
        let response = case json.parse(content, decode.dynamic) {
          Ok(parsed) -> tool.dynamic_to_json(parsed)
          Error(_) -> json.object([#("result", json.string(content))])
        }
        json.object([
          #("role", json.string("user")),
          #(
            "parts",
            json.array(
              [
                json.object([
                  #(
                    "functionResponse",
                    json.object([
                      #("name", json.string(name)),
                      #("response", response),
                    ]),
                  ),
                ]),
              ],
              fn(p) { p },
            ),
          ),
        ])
      }
    }
  })
}

fn build_function_declarations(tools: List(tool.Definition)) -> Json {
  json.object([
    #(
      "functionDeclarations",
      json.array(tools, fn(t) {
        case t {
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

fn build_generation_config(req: Request, ext: Ext) -> Option(Json) {
  let config = []

  let config = case req.temperature {
    Some(t) -> [#("temperature", json.float(t)), ..config]
    None -> config
  }

  let config = case req.max_tokens {
    Some(n) -> [#("maxOutputTokens", json.int(n)), ..config]
    None -> config
  }

  let config = case req.json_schema {
    Some(schema) -> [
      #("responseMimeType", json.string("application/json")),
      #("responseSchema", schema),
      ..config
    ]
    None -> config
  }

  let config = case ext.thinking_budget {
    Some(ThinkingOff) -> [
      #("thinkingConfig", json.object([#("thinkingBudget", json.int(0))])),
      ..config
    ]
    Some(ThinkingDynamic) -> [
      #(
        "thinkingConfig",
        json.object([
          #("thinkingBudget", json.int(-1)),
          #("includeThoughts", json.bool(True)),
        ]),
      ),
      ..config
    ]
    Some(ThinkingFixed(tokens)) -> [
      #(
        "thinkingConfig",
        json.object([
          #("thinkingBudget", json.int(tokens)),
          #("includeThoughts", json.bool(True)),
        ]),
      ),
      ..config
    ]
    None -> config
  }

  case config {
    [] -> None
    _ -> Some(json.object(config))
  }
}

fn send_request(
  api_key: String,
  base_url: String,
  req: Request,
  ext: Ext,
) -> Result(#(starlet.Response, Ext), StarletError) {
  let body = json.to_string(encode_request(req, ext))

  case uri.parse(base_url) {
    Ok(base_uri) -> {
      let scheme = case option.unwrap(base_uri.scheme, "https") {
        "http" -> http.Http
        _ -> http.Https
      }
      let host =
        option.unwrap(base_uri.host, "generativelanguage.googleapis.com")
      let base_path = base_uri.path

      let path =
        base_path <> "/v1beta/models/" <> req.model <> ":generateContent"

      let http_request =
        request.new()
        |> request.set_method(http.Post)
        |> request.set_scheme(scheme)
        |> request.set_host(host)
        |> internal_http.set_optional_port(base_uri.port)
        |> request.set_path(path)
        |> request.set_header("content-type", "application/json")
        |> request.set_header("x-goog-api-key", api_key)
        |> request.set_body(body)

      let config = httpc.configure() |> httpc.timeout(req.timeout_ms)
      case httpc.dispatch(config, http_request) {
        Ok(response) ->
          case response.status {
            200 ->
              case decode_response(response.body) {
                Ok(#(resp, thinking_content)) -> {
                  let new_ext = Ext(..ext, thinking: thinking_content)
                  Ok(#(resp, new_ext))
                }
                Error(e) -> Error(e)
              }
            429 -> {
              let retry_after =
                internal_http.parse_retry_after(response.headers)
              Error(starlet.RateLimited(retry_after))
            }
            status -> {
              case decode_error_response(response.body) {
                Ok(msg) ->
                  Error(starlet.Provider(
                    provider: "gemini",
                    message: msg,
                    raw: response.body,
                  ))
                Error(_) ->
                  Error(starlet.Http(status: status, body: response.body))
              }
            }
          }
        Error(err) -> Error(starlet.Transport(string.inspect(err)))
      }
    }
    Error(_) -> Error(starlet.Transport("Invalid base URL: " <> base_url))
  }
}

/// Decodes an error response body from the Gemini API.
/// Returns the error message if successfully parsed.
@internal
pub fn decode_error_response(body: String) -> Result(String, Nil) {
  let decoder = {
    use error <- decode.field("error", {
      use message <- decode.field("message", decode.string)
      decode.success(message)
    })
    decode.success(error)
  }
  json.parse(body, decoder)
  |> result.replace_error(Nil)
}

/// Internal type for decoding response parts.
type Part {
  TextPart(String)
  FunctionCallPart(tool.Call)
  ThoughtPart(String)
  SkippedPart
}

/// Decodes a response from the Gemini generateContent endpoint.
@internal
pub fn decode_response(
  body: String,
) -> Result(#(Response, Option(String)), StarletError) {
  let part_decoder =
    decode.one_of(decode_thought_part(), or: [
      decode_text_part(),
      decode_function_call_part(),
      decode_skipped_part(),
    ])

  let decoder = {
    use candidates <- decode.field(
      "candidates",
      decode.list({
        use parts <- decode.field("content", {
          use inner_parts <- decode.field("parts", decode.list(part_decoder))
          decode.success(inner_parts)
        })
        decode.success(parts)
      }),
    )
    decode.success(candidates)
  }

  case json.parse(body, decoder) {
    Ok([parts, ..]) -> {
      let text = extract_text(parts)
      let tool_calls = extract_tool_calls(parts)
      let thinking = extract_thinking(parts)
      Ok(#(starlet.Response(text: text, tool_calls: tool_calls), thinking))
    }
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
  use call <- decode.field("functionCall", {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("args", decode.dynamic)
    decode.success(#(name, arguments))
  })
  let #(name, arguments) = call
  decode.success(FunctionCallPart(tool.Call(id: "", name: name, arguments:)))
}

fn decode_thought_part() -> decode.Decoder(Part) {
  use is_thought <- decode.field("thought", decode.bool)
  case is_thought {
    True -> {
      use text <- decode.field("text", decode.string)
      decode.success(ThoughtPart(text))
    }
    False -> decode.failure(ThoughtPart(""), "thought is false")
  }
}

fn decode_skipped_part() -> decode.Decoder(Part) {
  decode.success(SkippedPart)
}

fn extract_text(parts: List(Part)) -> String {
  list.filter_map(parts, fn(part) {
    case part {
      TextPart(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("")
}

fn extract_tool_calls(parts: List(Part)) -> List(tool.Call) {
  list.index_fold(parts, [], fn(acc, part, index) {
    case part {
      FunctionCallPart(call) -> {
        let id = "gemini-" <> int.to_string(index)
        [tool.Call(..call, id: id), ..acc]
      }
      _ -> acc
    }
  })
  |> list.reverse
}

fn extract_thinking(parts: List(Part)) -> Option(String) {
  let thinking_texts =
    list.filter_map(parts, fn(part) {
      case part {
        ThoughtPart(text) -> Ok(text)
        _ -> Error(Nil)
      }
    })
  case thinking_texts {
    [] -> None
    texts -> Some(string.join(texts, "\n"))
  }
}
