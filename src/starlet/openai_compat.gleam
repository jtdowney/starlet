//// OpenAI-compatible provider for starlet.
////
//// Uses the standard [Chat Completions API](https://platform.openai.com/docs/api-reference/chat/create)
//// (`/v1/chat/completions`) which is supported by many inference providers.
////
//// ## Usage
////
//// ```gleam
//// import starlet
//// import starlet/openai_compat
//// import starlet/openai_compat/thinking
////
//// let client = openai_compat.new(
////   "https://api.together.xyz/v1",
////   api_key,
////   thinking.Together,
//// )
////
//// starlet.chat(client, "meta-llama/Llama-3-70b-chat-hf")
//// |> starlet.user("Hello!")
//// |> starlet.send()
//// ```
////
//// ## Reasoning Support
////
//// For reasoning-capable models, use `with_reasoning`:
////
//// ```gleam
//// starlet.chat(client, "deepseek-r1")
//// |> openai_compat.with_reasoning(thinking.EffortHigh)
//// |> starlet.user("Solve step by step...")
//// |> starlet.send()
//// ```
////
//// The dialect (set at client creation) determines how reasoning is
//// encoded in requests and decoded from responses.
////
//// ## Provider Compatibility
////
//// This module works with any provider implementing the OpenAI Chat Completions
//// API, including Synthetic, Together AI, Fireworks, Groq, vLLM, llama.cpp, and others.
////

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
import starlet/openai_compat/thinking
import starlet/tool

/// OpenAI-compatible provider extension type.
@internal
pub type Ext {
  Ext(
    /// Provider dialect for encoding/decoding reasoning.
    dialect: thinking.Dialect,
    /// Active thinking configuration (derived from dialect + effort).
    thinking_config: Option(thinking.Config),
    /// Thinking content extracted from the last response.
    thinking: Option(String),
    /// Thinking content per assistant message index.
    thinking_by_index: List(#(Int, String)),
    /// Whether to preserve thinking across turns in message history.
    interleaved_thinking: Bool,
  )
}

/// Creates a new OpenAI-compatible client.
///
/// The base URL should include the API version path if needed, e.g.:
/// - `"https://api.together.xyz/v1"`
/// - `"https://api.fireworks.ai/inference/v1"`
/// - `"http://localhost:8000/v1"` (for local vLLM)
///
/// The dialect determines how reasoning is encoded/decoded for this provider.
pub fn new(
  base_url: String,
  api_key: String,
  dialect: thinking.Dialect,
) -> Client(Ext) {
  let config =
    ProviderConfig(
      name: "openai_compat",
      base_url: base_url,
      send: fn(req, ext) { send_request(api_key, base_url, req, ext) },
    )
  let default_ext =
    Ext(
      dialect: dialect,
      thinking_config: None,
      thinking: None,
      thinking_by_index: [],
      interleaved_thinking: True,
    )
  starlet.from_provider(config, default_ext)
}

/// Enable reasoning with the specified effort level.
///
/// The dialect (set at client creation) determines how this is encoded
/// in the request and how reasoning is extracted from the response.
///
/// ```gleam
/// starlet.chat(client, "deepseek-r1")
/// |> openai_compat.with_reasoning(thinking.EffortHigh)
/// |> starlet.user("Solve step by step...")
/// |> starlet.send()
/// ```
pub fn with_reasoning(
  chat: Chat(t, f, s, Ext),
  effort: thinking.Effort,
) -> Chat(t, f, s, Ext) {
  let config = thinking.config_for_dialect(chat.ext.dialect, effort)
  Chat(..chat, ext: Ext(..chat.ext, thinking_config: Some(config)))
}

/// Advanced: Enable reasoning with a custom configuration.
///
/// Use this for edge cases or unsupported providers. Most users should
/// use `with_reasoning()` instead.
///
/// ```gleam
/// import starlet/openai_compat/thinking
/// let config = thinking.Config(
///   request: thinking.RequestEffort("high"),
///   response: thinking.ResponseFields(["reasoning_content"]),
///   context: thinking.ContextDoNotSend,
///   strip_from_content: False,
/// )
///
/// starlet.chat(client, "some-model")
/// |> openai_compat.with_thinking_config(config)
/// |> starlet.user("...")
/// |> starlet.send()
/// ```
pub fn with_thinking_config(
  chat: Chat(t, f, s, Ext),
  config: thinking.Config,
) -> Chat(t, f, s, Ext) {
  Chat(..chat, ext: Ext(..chat.ext, thinking_config: Some(config)))
}

/// Interleaved thinking is enabled by default. If enabled, Starlet
/// preserves the reasoning content per-turn and relays it to the
/// provider on subsequent turns. This is mostly helpful/necessary for
/// open-weights models like GLM and Kimi.
///
/// Disable it with `without_interleaved_thinking` on subsequent turns.
pub fn with_interleaved_thinking(chat: Chat(t, f, s, Ext)) -> Chat(t, f, s, Ext) {
  Chat(..chat, ext: Ext(..chat.ext, interleaved_thinking: True))
}

/// Disable interleaved thinking in message history.
pub fn without_interleaved_thinking(
  chat: Chat(t, f, s, Ext),
) -> Chat(t, f, s, Ext) {
  Chat(..chat, ext: Ext(..chat.ext, interleaved_thinking: False))
}

/// Get the thinking/reasoning content from a turn (if present).
pub fn thinking(turn: Turn(t, f, Ext)) -> Option(String) {
  turn.ext.thinking
}

fn update_thinking_history(
  ext: Ext,
  req: Request,
  thinking_content: Option(String),
) -> Ext {
  let base_ext = Ext(..ext, thinking: thinking_content)
  case ext.interleaved_thinking, thinking_content {
    True, Some(thinking_text) -> {
      let index = list.length(req.messages)
      let updated = [#(index, thinking_text), ..ext.thinking_by_index]
      Ext(..base_ext, thinking_by_index: updated)
    }
    _, _ -> base_ext
  }
}

fn thinking_for_message(
  ext: Ext,
  last_assistant: Option(Int),
  index: Int,
) -> Option(String) {
  case ext.interleaved_thinking {
    False ->
      case last_assistant {
        Some(last_index) if last_index == index -> ext.thinking
        _ -> None
      }
    True ->
      list.find(ext.thinking_by_index, fn(entry) {
        let #(entry_index, _) = entry
        entry_index == index
      })
      |> option.from_result
      |> option.map(fn(entry) {
        let #(_, text) = entry
        text
      })
  }
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
      let host = option.unwrap(base_uri.host, "localhost")
      let base_path = base_uri.path

      let http_request =
        request.new()
        |> request.set_method(http.Post)
        |> request.set_scheme(scheme)
        |> request.set_host(host)
        |> internal_http.set_optional_port(base_uri.port)
        |> request.set_path(base_path <> "/chat/completions")
        |> request.set_header("content-type", "application/json")
        |> request.set_header("authorization", "Bearer " <> api_key)
        |> request.set_body(body)

      let config = httpc.configure() |> httpc.timeout(req.timeout_ms)
      case httpc.dispatch(config, http_request) {
        Ok(response) ->
          case response.status {
            200 ->
              case decode_response(response.body, ext) {
                Ok(#(resp, thinking_content)) -> {
                  let new_ext =
                    update_thinking_history(ext, req, thinking_content)
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
                    provider: "openai_compat",
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

fn decode_error_response(body: String) -> Result(String, Nil) {
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

/// Encodes a request into JSON for the Chat Completions API.
@internal
pub fn encode_request(req: Request, ext: Ext) -> Json {
  let messages = encode_messages(req.system_prompt, req.messages, ext)

  let base = [
    #("model", json.string(req.model)),
    #("messages", json.array(messages, fn(m) { m })),
  ]

  let base = case req.tools {
    [] -> base
    _ -> list.append(base, [#("tools", encode_tools(req.tools))])
  }

  let base = case req.temperature {
    Some(t) -> list.append(base, [#("temperature", json.float(t))])
    None -> base
  }

  let base = case req.max_tokens {
    Some(n) -> list.append(base, [#("max_tokens", json.int(n))])
    None -> base
  }

  let base = case req.json_schema {
    Some(schema) ->
      list.append(base, [
        #(
          "response_format",
          json.object([
            #("type", json.string("json_schema")),
            #(
              "json_schema",
              json.object([
                #("name", json.string("response")),
                #("schema", schema),
              ]),
            ),
          ]),
        ),
      ])
    None -> base
  }

  let base = encode_thinking_request(base, ext)

  json.object(base)
}

fn encode_thinking_request(
  base: List(#(String, Json)),
  ext: Ext,
) -> List(#(String, Json)) {
  case ext.thinking_config {
    None -> base
    Some(config) ->
      case config.request {
        thinking.RequestNone -> base
        thinking.RequestEffort(effort) ->
          list.append(base, [#("reasoning_effort", json.string(effort))])
        thinking.RequestFormat(format) ->
          list.append(base, [#("reasoning_format", json.string(format))])
        thinking.RequestDisable(disabled) ->
          list.append(base, [#("disable_reasoning", json.bool(disabled))])
        thinking.RequestZai(enabled) ->
          list.append(base, [
            #(
              "thinking",
              json.object([
                #(
                  "type",
                  json.string(case enabled {
                    True -> "enabled"
                    False -> "disabled"
                  }),
                ),
              ]),
            ),
          ])
      }
  }
}

fn encode_messages(
  system_prompt: Option(String),
  messages: List(Message),
  ext: Ext,
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

  let last_assistant = last_assistant_index(messages)
  let chat_msgs =
    encode_messages_acc(messages, [], ext, last_assistant, 0) |> list.reverse

  list.append(system_msgs, chat_msgs)
}

fn encode_messages_acc(
  messages: List(Message),
  acc: List(Json),
  ext: Ext,
  last_assistant: Option(Int),
  index: Int,
) -> List(Json) {
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
          encode_messages_acc(
            rest,
            [encoded, ..acc],
            ext,
            last_assistant,
            index + 1,
          )
        }
        AssistantMessage(content, tool_calls) -> {
          let message_thinking =
            thinking_for_message(ext, last_assistant, index)
          let encoded =
            encode_assistant_message(content, tool_calls, ext, message_thinking)
          encode_messages_acc(
            rest,
            [encoded, ..acc],
            ext,
            last_assistant,
            index + 1,
          )
        }
        ToolResultMessage(call_id, name, content) -> {
          let encoded =
            json.object([
              #("role", json.string("tool")),
              #("tool_call_id", json.string(call_id)),
              #("name", json.string(name)),
              #("content", json.string(content)),
            ])
          encode_messages_acc(
            rest,
            [encoded, ..acc],
            ext,
            last_assistant,
            index + 1,
          )
        }
      }
    }
  }
}

fn last_assistant_index(messages: List(Message)) -> Option(Int) {
  last_assistant_index_loop(messages, 0, None)
}

fn last_assistant_index_loop(
  messages: List(Message),
  index: Int,
  last: Option(Int),
) -> Option(Int) {
  case messages {
    [] -> last
    [msg, ..rest] -> {
      let last = case msg {
        AssistantMessage(_, _) -> Some(index)
        _ -> last
      }
      last_assistant_index_loop(rest, index + 1, last)
    }
  }
}

fn encode_assistant_message(
  content: String,
  tool_calls: List(tool.Call),
  ext: Ext,
  thinking_content: Option(String),
) -> Json {
  case tool_calls {
    [] -> {
      let base = [
        #("role", json.string("assistant")),
        #("content", json.string(content)),
      ]
      let base = add_thinking_context(base, ext, thinking_content)
      json.object(base)
    }
    _ -> {
      let tc =
        list.map(tool_calls, fn(call) {
          json.object([
            #("id", json.string(call.id)),
            #("type", json.string("function")),
            #(
              "function",
              json.object([
                #("name", json.string(call.name)),
                #(
                  "arguments",
                  json.string(
                    json.to_string(tool.dynamic_to_json(call.arguments)),
                  ),
                ),
              ]),
            ),
          ])
        })
      let content_json = case content {
        "" -> json.null()
        _ -> json.string(content)
      }
      let base = [
        #("role", json.string("assistant")),
        #("content", content_json),
        #("tool_calls", json.array(tc, fn(t) { t })),
      ]
      let base = add_thinking_context(base, ext, thinking_content)
      json.object(base)
    }
  }
}

fn add_thinking_context(
  base: List(#(String, Json)),
  ext: Ext,
  thinking_content: Option(String),
) -> List(#(String, Json)) {
  case ext.thinking_config, thinking_content {
    Some(config), Some(thinking_content) ->
      case config.context {
        thinking.ContextDoNotSend -> base
        thinking.ContextSendAsField(field_name) ->
          list.append(base, [#(field_name, json.string(thinking_content))])
        thinking.ContextSendWithTags -> {
          case list.key_find(base, "content") {
            Ok(content_json) -> {
              let new_content =
                "<think>"
                <> thinking_content
                <> "</think>"
                <> get_json_string(content_json)
              list.key_set(base, "content", json.string(new_content))
            }
            Error(_) ->
              list.append(base, [
                #(
                  "content",
                  json.string("<think>" <> thinking_content <> "</think>"),
                ),
              ])
          }
        }
      }
    _, _ -> base
  }
}

fn get_json_string(j: Json) -> String {
  let s = json.to_string(j)
  case json.parse(s, decode.string) {
    Ok(value) -> value
    Error(_) -> s
  }
}

fn encode_tools(tools: List(tool.Definition)) -> Json {
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
  })
}

/// Decodes a JSON response from the Chat Completions API.
/// Returns the Response and any thinking content.
@internal
pub fn decode_response(
  body: String,
  ext: Ext,
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
    use id <- decode.field("id", decode.string)
    use function <- decode.field("function", function_decoder)
    let #(name, arguments) = function
    decode.success(tool.Call(id:, name:, arguments:))
  }

  let thinking_fields = get_thinking_fields(ext)

  let nullable_tool_calls_decoder =
    decode.optional(decode.list(tool_call_decoder))
    |> decode.map(option.unwrap(_, []))

  let message_decoder = {
    use content <- decode.optional_field("content", "", decode.string)
    use tool_calls <- decode.optional_field(
      "tool_calls",
      [],
      nullable_tool_calls_decoder,
    )
    decode.success(#(content, tool_calls))
  }

  let choice_decoder = {
    use #(text, tool_calls) <- decode.field("message", message_decoder)
    decode.success(#(text, tool_calls))
  }

  let decoder = {
    use choices <- decode.field("choices", decode.list(choice_decoder))
    case list.first(choices) {
      Ok(#(text, tool_calls)) -> decode.success(#(text, tool_calls))
      Error(_) -> decode.success(#("", []))
    }
  }

  case json.parse(body, decoder) {
    Ok(#(text, tool_calls)) -> {
      let thinking_from_fields =
        extract_thinking_from_body(body, thinking_fields)
      let #(final_text, thinking_result) =
        process_thinking(text, thinking_from_fields, ext)
      let response = Response(text: final_text, tool_calls: tool_calls)
      Ok(#(response, thinking_result))
    }
    Error(err) ->
      Error(starlet.Decode(
        "Failed to decode OpenAI-compat response: " <> string.inspect(err),
      ))
  }
}

fn get_thinking_fields(ext: Ext) -> List(String) {
  thinking.get_response_fields(ext.thinking_config)
}

fn extract_thinking_from_body(
  body: String,
  fields: List(String),
) -> Option(String) {
  case fields {
    [] -> None
    [field, ..rest] -> {
      let decoder = {
        use choices <- decode.field(
          "choices",
          decode.list({
            use msg <- decode.field("message", {
              use value <- decode.optional_field(field, None, {
                use v <- decode.then(decode.string)
                decode.success(Some(v))
              })
              decode.success(value)
            })
            decode.success(msg)
          }),
        )
        case list.first(choices) {
          Ok(Some(v)) -> decode.success(Some(v))
          _ -> decode.success(None)
        }
      }
      case json.parse(body, decoder) {
        Ok(Some(v)) -> Some(v)
        _ -> extract_thinking_from_body(body, rest)
      }
    }
  }
}

fn process_thinking(
  text: String,
  thinking_from_fields: Option(String),
  ext: Ext,
) -> #(String, Option(String)) {
  thinking.process(text, thinking_from_fields, ext.thinking_config)
}
