//// Anthropic provider for starlet.
////
//// Uses the [Anthropic Messages API](https://docs.anthropic.com/en/api/messages)
//// for chat completions with Claude models.
////
//// ## Usage
////
//// ```gleam
//// import gleam/httpc
//// import starlet
//// import starlet/anthropic
////
//// let creds = anthropic.credentials(api_key)
//// let chat = anthropic.chat(creds, "claude-haiku-4-5-20251001")
////   |> starlet.user("Hello!")
////
//// let assert Ok(http_resp) = httpc.send(anthropic.request(chat, creds))
//// let assert Ok(turn) = anthropic.response(http_resp)
//// ```
////
//// ## Extended Thinking
////
//// For models that support extended thinking, configure a thinking budget:
////
//// ```gleam
//// anthropic.chat(creds, "claude-haiku-4-5-20251001")
//// |> anthropic.with_thinking(16384)
//// |> starlet.max_tokens(32000)
//// |> starlet.user("Analyze this complex problem...")
//// ```
////
//// ## Note on max_tokens
////
//// Anthropic requires `max_tokens` in every request. If not explicitly set
//// via `starlet.max_tokens()`, a default of 4096 is used.

import gleam/bool
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

const default_max_tokens = 4096

const anthropic_version = "2023-06-01"

const default_host = "api.anthropic.com"

const default_base_url = "https://api.anthropic.com"

/// Anthropic provider extension type for extended thinking.
pub type Ext {
  Ext(
    /// Token budget for extended thinking (min 1024).
    thinking_budget: Option(Int),
    /// Thinking content from the last response.
    thinking: Option(String),
  )
}

/// Connection credentials for Anthropic.
pub type Credentials {
  Credentials(api_key: String, base_url: String)
}

/// Creates credentials for connecting to Anthropic.
/// Uses the default base URL: https://api.anthropic.com
pub fn credentials(api_key: String) -> Credentials {
  Credentials(api_key:, base_url: default_base_url)
}

/// Creates credentials with a custom base URL.
/// Useful for proxies or self-hosted endpoints.
pub fn credentials_with_base_url(
  api_key: String,
  base_url: String,
) -> Credentials {
  Credentials(api_key:, base_url:)
}

/// Creates a new chat with the given credentials and model name.
///
/// Note: Anthropic requires max_tokens. If not explicitly set via
/// `starlet.max_tokens()`, a default of 4096 is used.
pub fn chat(
  creds: Credentials,
  model: String,
) -> Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, Ext) {
  let _ = creds
  let default_ext = Ext(thinking_budget: None, thinking: None)
  starlet.new_chat(model, default_ext)
}

/// Enable extended thinking with a token budget.
/// Budget must be at least 1024 tokens. The upper bound (less than max_tokens)
/// is enforced by the API at request time.
pub fn with_thinking(
  chat: Chat(t, f, s, Ext),
  budget: Int,
) -> Result(Chat(t, f, s, Ext), StarletError) {
  use <- bool.guard(
    when: budget < 1024,
    return: Error(starlet.Provider(
      provider: "anthropic",
      message: "thinking budget must be at least 1024 tokens",
      raw: "",
    )),
  )
  Ok(Chat(..chat, ext: Ext(..chat.ext, thinking_budget: Some(budget))))
}

/// Get the thinking content from an Anthropic turn (if present).
pub fn thinking(turn: Turn(t, f, Ext)) -> Option(String) {
  turn.ext.thinking
}

/// Builds an HTTP request for sending a chat to Anthropic.
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

  Ok(
    http_request
    |> request.set_method(http.Post)
    |> request.set_path(base_uri.path <> "/v1/messages")
    |> request.set_header("content-type", "application/json")
    |> request.set_header("x-api-key", creds.api_key)
    |> request.set_header("anthropic-version", anthropic_version)
    |> set_beta_headers(chat.json_schema, chat.ext.thinking_budget)
    |> request.set_body(body),
  )
}

fn set_beta_headers(
  req: Request(String),
  json_schema: Option(Json),
  thinking_budget: Option(Int),
) -> Request(String) {
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

/// Decodes an HTTP response from Anthropic into a Turn.
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
            provider: "anthropic",
            message: msg,
            raw: resp.body,
          ))
        Error(_) -> Error(starlet.Http(status:, body: resp.body))
      }
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

/// Encodes a chat into JSON for the Anthropic Messages API.
@internal
pub fn encode_request(chat: Chat(tools, format, starlet.Ready, Ext)) -> Json {
  let max_tokens = option.unwrap(chat.max_tokens, default_max_tokens)

  let messages = encode_messages(chat.messages)

  let base = [
    #("model", json.string(chat.model)),
    #("max_tokens", json.int(max_tokens)),
    #("messages", json.array(messages, fn(m) { m })),
  ]

  let base = case chat.system_prompt {
    Some(prompt) -> [#("system", json.string(prompt)), ..base]
    None -> base
  }

  let base = case chat.temperature {
    Some(t) -> list.append(base, [#("temperature", json.float(t))])
    None -> base
  }

  let base = case chat.tools {
    [] -> base
    tools -> list.append(base, [#("tools", encode_tools(tools))])
  }

  let base = case chat.json_schema {
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

  let base = case chat.ext.thinking_budget {
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
      let #(encoded, remaining) = case msg {
        UserMessage(content) -> #(encode_user_message(content), rest)
        AssistantMessage(content, tool_calls) -> #(
          encode_assistant_message(content, tool_calls),
          rest,
        )
        ToolResultMessage(_, _, _) -> encode_tool_results_batch(messages)
      }
      encode_messages_acc(remaining, [encoded, ..acc])
    }
  }
}

fn encode_user_message(content: String) -> Json {
  json.object([
    #("role", json.string("user")),
    #("content", json.string(content)),
  ])
}

fn encode_assistant_message(
  content: String,
  tool_calls: List(tool.Call),
) -> Json {
  use <- bool.guard(
    when: list.is_empty(tool_calls),
    return: json.object([
      #("role", json.string("assistant")),
      #("content", json.string(content)),
    ]),
  )

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
    #("content", json.array(list.append(text_blocks, tool_blocks), fn(b) { b })),
  ])
}

fn encode_tool_results_batch(messages: List(Message)) -> #(Json, List(Message)) {
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
  #(encoded, remaining)
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
/// Returns the text, thinking content, and tool calls.
@internal
pub fn decode_response(
  body: String,
) -> Result(#(String, Option(String), List(tool.Call)), StarletError) {
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
      Ok(#(text, thinking, tool_calls))
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
