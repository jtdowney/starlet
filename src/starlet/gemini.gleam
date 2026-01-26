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
//// let chat = gemini.chat(creds, "gemini-2.5-flash")
////   |> starlet.user("Hello!")
////
//// let assert Ok(http_resp) = httpc.send(gemini.request(chat, creds))
//// let assert Ok(turn) = gemini.response(http_resp)
//// ```
////
//// ## Thinking Mode
////
//// For Gemini 2.5+ models, configure thinking:
////
//// ```gleam
//// gemini.chat(creds, "gemini-2.5-flash")
//// |> gemini.with_thinking(gemini.ThinkingDynamic)
//// |> starlet.user("Solve this step by step...")
//// ```

import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
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

const default_host = "generativelanguage.googleapis.com"

const default_base_url = "https://generativelanguage.googleapis.com"

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

/// Connection credentials for Gemini.
pub type Credentials {
  Credentials(api_key: String, base_url: String)
}

/// Information about an available model.
pub type Model {
  Model(id: String, display_name: String)
}

/// Creates credentials for connecting to Gemini.
/// Uses the default base URL: https://generativelanguage.googleapis.com
pub fn credentials(api_key: String) -> Credentials {
  Credentials(api_key:, base_url: default_base_url)
}

/// Creates credentials with a custom base URL.
pub fn credentials_with_base_url(
  api_key: String,
  base_url: String,
) -> Credentials {
  Credentials(api_key:, base_url:)
}

/// Creates a new chat with the given credentials and model name.
pub fn chat(
  creds: Credentials,
  model: String,
) -> Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, Ext) {
  let _ = creds
  let default_ext = Ext(thinking_budget: None, thinking: None)
  starlet.new_chat(model, default_ext)
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

/// Builds an HTTP request for sending a chat to Gemini.
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

  let base_uri = internal_http.with_defaults(base_uri, "https", default_host)
  use http_request <- result.try(
    request.from_uri(base_uri)
    |> result.replace_error(starlet.Http(
      0,
      "Invalid base URL: " <> creds.base_url,
    )),
  )

  let path =
    base_uri.path <> "/v1beta/models/" <> chat.model <> ":generateContent"

  Ok(
    http_request
    |> request.set_method(http.Post)
    |> request.set_path(path)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("x-goog-api-key", creds.api_key)
    |> request.set_body(body),
  )
}

/// Decodes an HTTP response from Gemini into a Turn.
pub fn response(
  resp: Response(String),
) -> Result(Turn(tools, format, Ext), StarletError) {
  case resp.status {
    200 -> {
      use #(text, thinking_content, tool_calls) <- result.map(decode_response(
        resp.body,
      ))
      let ext = Ext(thinking_budget: None, thinking: thinking_content)
      starlet.Turn(text:, tool_calls:, ext:)
    }
    429 -> {
      let retry_after = internal_http.parse_retry_after(resp.headers)
      Error(starlet.RateLimited(retry_after))
    }
    status ->
      case decode_error_response(resp.body) {
        Ok(msg) ->
          Error(starlet.Provider(
            provider: "gemini",
            message: msg,
            raw: resp.body,
          ))
        Error(_) -> Error(starlet.Http(status:, body: resp.body))
      }
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

/// Encodes a chat into JSON for the Gemini generateContent endpoint.
@internal
pub fn encode_request(chat: Chat(tools, format, starlet.Ready, Ext)) -> Json {
  let contents = build_contents(chat.messages)

  let base = [#("contents", json.array(contents, fn(c) { c }))]

  // Add systemInstruction if present
  let base = case chat.system_prompt {
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
  let base = case chat.tools {
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
  let gen_config = build_generation_config(chat)
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

fn build_generation_config(
  chat: Chat(tools, format, starlet.Ready, Ext),
) -> Option(Json) {
  let config = []

  let config = case chat.temperature {
    Some(t) -> [#("temperature", json.float(t)), ..config]
    None -> config
  }

  let config = case chat.max_tokens {
    Some(n) -> [#("maxOutputTokens", json.int(n)), ..config]
    None -> config
  }

  let config = case chat.json_schema {
    Some(schema) -> [
      #("responseMimeType", json.string("application/json")),
      #("responseSchema", schema),
      ..config
    ]
    None -> config
  }

  let config = case chat.ext.thinking_budget {
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
) -> Result(#(String, Option(String), List(tool.Call)), StarletError) {
  let part_decoder =
    decode.one_of(decode_thought_part(), or: [
      decode_text_part(),
      decode_function_call_part(),
      decode_skipped_part(),
    ])

  let candidate_decoder =
    decode.at(["content", "parts"], decode.list(part_decoder))
  let decoder = {
    use candidates <- decode.field("candidates", decode.list(candidate_decoder))
    decode.success(candidates)
  }

  case json.parse(body, decoder) {
    Ok([parts, ..]) -> {
      let text = extract_text(parts)
      let tool_calls = extract_tool_calls(parts)
      let thinking = extract_thinking(parts)
      Ok(#(text, thinking, tool_calls))
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

  let base_uri = internal_http.with_defaults(base_uri, "https", default_host)
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
    |> request.set_path(base_uri.path <> "/v1beta/models")
    |> request.set_header("x-goog-api-key", creds.api_key),
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

  json.parse(body, decoder)
  |> result.map_error(fn(err) {
    starlet.Decode("Failed to decode Gemini models: " <> string.inspect(err))
  })
}
