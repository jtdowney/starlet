//// Anthropic provider for starlet.
////
//// Uses the [Anthropic Messages API](https://docs.anthropic.com/en/api/messages)
//// for chat completions with Claude models.
////
//// ## Usage
////
//// ```gleam
//// import starlet
//// import starlet/anthropic
////
//// let client = anthropic.new(api_key)
////
//// starlet.chat(client, "claude-haiku-4-5-20251001")
//// |> starlet.user("Hello!")
//// |> starlet.send()
//// ```
////
//// ## Extended Thinking
////
//// For models that support extended thinking, configure a thinking budget:
////
//// ```gleam
//// starlet.chat(client, "claude-haiku-4-5-20251001")
//// |> anthropic.with_thinking(16384)
//// |> starlet.max_tokens(32000)
//// |> starlet.user("Analyze this complex problem...")
//// |> starlet.send()
//// ```
////
//// ## Note on max_tokens
////
//// Anthropic requires `max_tokens` in every request. If not explicitly set
//// via `starlet.max_tokens()`, a default of 4096 is used.

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

const default_max_tokens = 4096

const anthropic_version = "2023-06-01"

/// Anthropic provider extension type for extended thinking.
@internal
pub type Ext {
  Ext(
    /// Token budget for extended thinking (min 1024).
    thinking_budget: Option(Int),
    /// Thinking content from the last response.
    thinking: Option(String),
  )
}

/// Creates a new Anthropic client with the given API key.
/// Uses the default base URL: https://api.anthropic.com
///
/// Note: Anthropic requires max_tokens. If not explicitly set via
/// `starlet.max_tokens()`, a default of 4096 is used.
pub fn new(api_key: String) -> Client(Ext) {
  new_with_base_url(api_key, "https://api.anthropic.com")
}

/// Creates a new Anthropic client with a custom base URL.
/// Useful for proxies or self-hosted endpoints.
///
/// Note: Anthropic requires max_tokens. If not explicitly set via
/// `starlet.max_tokens()`, a default of 4096 is used.
pub fn new_with_base_url(api_key: String, base_url: String) -> Client(Ext) {
  let config =
    ProviderConfig(name: "anthropic", base_url: base_url, send: fn(req, ext) {
      send_request(api_key, base_url, req, ext)
    })
  let default_ext = Ext(thinking_budget: None, thinking: None)
  starlet.from_provider(config, default_ext)
}

/// Enable extended thinking with a token budget.
/// Budget must be at least 1024 tokens. The upper bound (less than max_tokens)
/// is enforced by the API at request time.
pub fn with_thinking(
  chat: Chat(t, f, s, Ext),
  budget: Int,
) -> Result(Chat(t, f, s, Ext), StarletError) {
  case budget >= 1024 {
    False ->
      Error(starlet.Provider(
        provider: "anthropic",
        message: "thinking budget must be at least 1024 tokens",
        raw: "",
      ))
    True -> {
      Ok(Chat(..chat, ext: Ext(..chat.ext, thinking_budget: Some(budget))))
    }
  }
}

/// Get the thinking content from an Anthropic turn (if present).
pub fn thinking(turn: Turn(t, f, Ext)) -> Option(String) {
  turn.ext.thinking
}

fn send_request(
  api_key: String,
  base_url: String,
  req: Request,
  ext: Ext,
) -> Result(#(Response, Ext), StarletError) {
  let body = json.to_string(encode_request(req, ext))

  case uri.parse(base_url) {
    Ok(base_uri) -> {
      let scheme = case option.unwrap(base_uri.scheme, "https") {
        "http" -> http.Http
        _ -> http.Https
      }
      let host = option.unwrap(base_uri.host, "api.anthropic.com")
      let base_path = base_uri.path

      let http_request =
        request.new()
        |> request.set_method(http.Post)
        |> request.set_scheme(scheme)
        |> request.set_host(host)
        |> internal_http.set_optional_port(base_uri.port)
        |> request.set_path(base_path <> "/v1/messages")
        |> request.set_header("content-type", "application/json")
        |> request.set_header("x-api-key", api_key)
        |> request.set_header("anthropic-version", anthropic_version)
        |> set_beta_headers(req.json_schema, ext.thinking_budget)
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
                    provider: "anthropic",
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

fn set_beta_headers(
  req: request.Request(String),
  json_schema: Option(Json),
  thinking_budget: Option(Int),
) -> request.Request(String) {
  let betas = []

  let betas = case json_schema {
    Some(_) -> ["structured-outputs-2025-11-13", ..betas]
    None -> betas
  }

  let betas = case thinking_budget {
    Some(_) -> ["interleaved-thinking-2025-05-14", ..betas]
    None -> betas
  }

  case betas {
    [] -> req
    _ -> request.set_header(req, "anthropic-beta", string.join(betas, ","))
  }
}

/// Decodes an error response body from the Anthropic API.
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

/// Encodes a request into JSON for the Anthropic Messages API.
@internal
pub fn encode_request(req: Request, ext: Ext) -> Json {
  let max_tokens = option.unwrap(req.max_tokens, default_max_tokens)

  let messages = encode_messages(req.messages)

  let base = [
    #("model", json.string(req.model)),
    #("max_tokens", json.int(max_tokens)),
    #("messages", json.array(messages, fn(m) { m })),
  ]

  let base = case req.system_prompt {
    Some(prompt) -> [#("system", json.string(prompt)), ..base]
    None -> base
  }

  let base = case req.temperature {
    Some(t) -> list.append(base, [#("temperature", json.float(t))])
    None -> base
  }

  let base = case req.tools {
    [] -> base
    _ -> list.append(base, [#("tools", encode_tools(req.tools))])
  }

  let base = case req.json_schema {
    Some(schema) ->
      list.append(base, [
        #(
          "output_format",
          json.object([
            #("type", json.string("json_schema")),
            #("schema", schema),
          ]),
        ),
      ])
    None -> base
  }

  let base = case ext.thinking_budget {
    Some(budget) ->
      list.append(base, [
        #(
          "thinking",
          json.object([
            #("type", json.string("enabled")),
            #("budget_tokens", json.int(budget)),
          ]),
        ),
      ])
    None -> base
  }

  json.object(base)
}

fn encode_tools(tools: List(tool.Definition)) -> Json {
  json.array(tools, fn(t) {
    case t {
      tool.Function(name, description, parameters) ->
        json.object([
          #("name", json.string(name)),
          #("description", json.string(description)),
          #("input_schema", parameters),
        ])
    }
  })
}

fn encode_messages(messages: List(Message)) -> List(Json) {
  encode_messages_acc(messages, [])
  |> list.reverse
}

fn encode_messages_acc(messages: List(Message), acc: List(Json)) -> List(Json) {
  case messages {
    [] -> acc
    [msg, ..rest] -> {
      case msg {
        UserMessage(content) -> {
          let encoded =
            json.object([
              #("role", json.string("user")),
              #("content", json.string(content)),
            ])
          encode_messages_acc(rest, [encoded, ..acc])
        }
        AssistantMessage(content, tool_calls) -> {
          let encoded = case tool_calls {
            [] ->
              json.object([
                #("role", json.string("assistant")),
                #("content", json.string(content)),
              ])
            _ -> {
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
                #(
                  "content",
                  json.array(list.append(text_blocks, tool_blocks), fn(b) { b }),
                ),
              ])
            }
          }
          encode_messages_acc(rest, [encoded, ..acc])
        }
        ToolResultMessage(_, _, _) -> {
          let #(results, remaining) = collect_tool_results(messages)
          let content_blocks =
            list.map(results, fn(r) {
              let #(id, _, c) = r
              json.object([
                #("type", json.string("tool_result")),
                #("tool_use_id", json.string(id)),
                #("content", json.string(c)),
              ])
            })
          let encoded =
            json.object([
              #("role", json.string("user")),
              #("content", json.array(content_blocks, fn(b) { b })),
            ])
          encode_messages_acc(remaining, [encoded, ..acc])
        }
      }
    }
  }
}

fn collect_tool_results(
  messages: List(Message),
) -> #(List(#(String, String, String)), List(Message)) {
  collect_tool_results_acc(messages, [])
}

fn collect_tool_results_acc(
  messages: List(Message),
  acc: List(#(String, String, String)),
) -> #(List(#(String, String, String)), List(Message)) {
  case messages {
    [ToolResultMessage(id, name, content), ..rest] ->
      collect_tool_results_acc(rest, [#(id, name, content), ..acc])
    _ -> #(list.reverse(acc), messages)
  }
}

type ContentBlock {
  TextBlock(text: String)
  ToolUseBlock(call: tool.Call)
  ThinkingBlock(text: String)
  SkippedBlock
}

/// Decodes a JSON response from the Anthropic Messages API.
/// Returns the Response and any thinking content.
@internal
pub fn decode_response(
  body: String,
) -> Result(#(Response, Option(String)), StarletError) {
  let content_block_decoder =
    decode.one_of(decode_text_block(), or: [
      decode_tool_use_block(),
      decode_thinking_block(),
      decode_skipped_block(),
    ])

  let decoder = {
    use content <- decode.field("content", decode.list(content_block_decoder))
    decode.success(content)
  }

  case json.parse(body, decoder) {
    Ok(content_blocks) -> {
      let text = extract_text(content_blocks)
      let tool_calls = extract_tool_calls(content_blocks)
      let thinking = extract_thinking(content_blocks)
      Ok(#(Response(text: text, tool_calls: tool_calls), thinking))
    }
    Error(err) ->
      Error(starlet.Decode(
        "Failed to decode Anthropic response: " <> string.inspect(err),
      ))
  }
}

fn decode_text_block() -> decode.Decoder(ContentBlock) {
  use type_ <- decode.field("type", decode.string)
  case type_ {
    "text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(TextBlock(text))
    }
    _ -> decode.failure(TextBlock(""), "text")
  }
}

fn decode_tool_use_block() -> decode.Decoder(ContentBlock) {
  use type_ <- decode.field("type", decode.string)
  case type_ {
    "tool_use" -> {
      use id <- decode.field("id", decode.string)
      use name <- decode.field("name", decode.string)
      use arguments <- decode.field("input", decode.dynamic)
      decode.success(ToolUseBlock(tool.Call(id:, name:, arguments:)))
    }
    _ ->
      decode.failure(ToolUseBlock(tool.Call("", "", dynamic.nil())), "tool_use")
  }
}

fn decode_thinking_block() -> decode.Decoder(ContentBlock) {
  use type_ <- decode.field("type", decode.string)
  case type_ {
    "thinking" -> {
      use text <- decode.field("thinking", decode.string)
      decode.success(ThinkingBlock(text))
    }
    _ -> decode.failure(ThinkingBlock(""), "thinking")
  }
}

fn decode_skipped_block() -> decode.Decoder(ContentBlock) {
  use _type <- decode.field("type", decode.string)
  decode.success(SkippedBlock)
}

fn extract_text(blocks: List(ContentBlock)) -> String {
  list.filter_map(blocks, fn(block) {
    case block {
      TextBlock(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("")
}

fn extract_tool_calls(blocks: List(ContentBlock)) -> List(tool.Call) {
  list.filter_map(blocks, fn(block) {
    case block {
      ToolUseBlock(call) -> Ok(call)
      _ -> Error(Nil)
    }
  })
}

fn extract_thinking(blocks: List(ContentBlock)) -> Option(String) {
  let thinking_texts =
    list.filter_map(blocks, fn(block) {
      case block {
        ThinkingBlock(text) -> Ok(text)
        _ -> Error(Nil)
      }
    })
  case thinking_texts {
    [] -> None
    texts -> Some(string.join(texts, "\n"))
  }
}
