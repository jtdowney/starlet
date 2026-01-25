//// OpenAI provider for starlet.
////
//// Uses the [OpenAI Responses API](https://platform.openai.com/docs/api-reference/responses)
//// for chat completions with support for server-side conversation continuation.
////
//// ## Usage
////
//// ```gleam
//// import starlet
//// import starlet/openai
////
//// let client = openai.new(api_key)
////
//// starlet.chat(client, "gpt-5-nano")
//// |> starlet.user("Hello!")
//// |> starlet.send()
//// ```
////
//// ## Reasoning Models
////
//// For reasoning models (o1, o3, gpt-5), you can configure reasoning effort:
////
//// ```gleam
//// starlet.chat(client, "gpt-5-nano")
//// |> openai.with_reasoning(openai.ReasoningHigh)
//// |> starlet.user("Solve this step by step...")
//// |> starlet.send()
//// ```

import gleam/bool
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

const default_host = "api.openai.com"

/// Result of decoding an OpenAI response, includes the response ID.
@internal
pub type DecodedResponse {
  DecodedResponse(
    response: Response,
    response_id: String,
    reasoning_summary: Option(String),
  )
}

/// Reasoning effort level for OpenAI reasoning models.
pub type ReasoningEffort {
  /// No reasoning tokens generated
  ReasoningNone
  /// Minimal reasoning, favors speed
  ReasoningLow
  /// Balanced reasoning (default for reasoning models)
  ReasoningMedium
  /// Maximum reasoning depth
  ReasoningHigh
  /// Extended high reasoning (GPT-5.2+)
  ReasoningXHigh
}

/// OpenAI provider extension type for server-side conversation state and reasoning.
@internal
pub type Ext {
  Ext(
    /// The ID of the last response, used for continuation.
    response_id: Option(String),
    /// Reasoning effort level for reasoning models.
    reasoning_effort: Option(ReasoningEffort),
    /// Reasoning summary from the last response.
    reasoning_summary: Option(String),
  )
}

/// Information about an available model.
pub type Model {
  Model(id: String, owned_by: String)
}

/// Creates a new OpenAI client with the given API key.
/// Uses the default base URL: https://api.openai.com
pub fn new(api_key: String) -> Client(Ext) {
  new_with_base_url(api_key, "https://api.openai.com")
}

/// Creates a new OpenAI client with a custom base URL.
/// Useful for proxies or Azure OpenAI endpoints.
pub fn new_with_base_url(api_key: String, base_url: String) -> Client(Ext) {
  let config =
    ProviderConfig(name: "openai", base_url: base_url, send: fn(req, ext) {
      send_request(api_key, base_url, req, ext)
    })
  let default_ext =
    Ext(response_id: None, reasoning_effort: None, reasoning_summary: None)
  starlet.from_provider(config, default_ext)
}

fn send_request(
  api_key: String,
  base_url: String,
  req: Request,
  ext: Ext,
) -> Result(#(Response, Ext), StarletError) {
  let body = json.to_string(encode_request(req, ext))

  use base_uri <- result.try(
    uri.parse(base_url)
    |> result.replace_error(starlet.Transport("Invalid base URL: " <> base_url)),
  )

  let base_uri = internal_http.with_defaults(base_uri, "https", default_host)
  use http_request <- result.try(
    request.from_uri(base_uri)
    |> result.replace_error(starlet.Transport("Invalid base URL: " <> base_url)),
  )

  let http_request =
    http_request
    |> request.set_method(http.Post)
    |> request.set_path(base_uri.path <> "/v1/responses")
    |> request.set_header("content-type", "application/json")
    |> request.set_header("authorization", "Bearer " <> api_key)
    |> request.set_body(body)

  let config = httpc.configure() |> httpc.timeout(req.timeout_ms)
  use response <- result.try(
    httpc.dispatch(config, http_request)
    |> result.map_error(fn(err) { starlet.Transport(string.inspect(err)) }),
  )

  case response.status {
    200 -> {
      use decoded <- result.map(decode_response(response.body))
      let new_ext =
        Ext(
          ..ext,
          response_id: Some(decoded.response_id),
          reasoning_summary: decoded.reasoning_summary,
        )
      #(decoded.response, new_ext)
    }
    429 -> {
      let retry_after = internal_http.parse_retry_after(response.headers)
      Error(starlet.RateLimited(retry_after))
    }
    status ->
      case decode_error_response(response.body) {
        Ok(msg) ->
          Error(starlet.Provider(
            provider: "openai",
            message: msg,
            raw: response.body,
          ))
        Error(_) -> Error(starlet.Http(status: status, body: response.body))
      }
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

/// Encodes a request into JSON for the OpenAI Responses API.
@internal
pub fn encode_request(req: Request, ext: Ext) -> Json {
  let input = build_input(req.system_prompt, req.messages)
  let tools = build_tools(req.tools)

  let base = [
    #("model", json.string(req.model)),
    #("input", json.array(input, fn(m) { m })),
  ]

  let base = case ext.response_id {
    Some(id) -> list.append(base, [#("previous_response_id", json.string(id))])
    None -> base
  }

  let base = case tools {
    Some(t) -> list.append(base, [#("tools", t)])
    None -> base
  }

  let base = case req.temperature {
    Some(t) -> list.append(base, [#("temperature", json.float(t))])
    None -> base
  }

  let base = case req.max_tokens {
    Some(n) -> list.append(base, [#("max_output_tokens", json.int(n))])
    None -> base
  }

  let base = case req.json_schema {
    Some(schema) ->
      list.append(base, [
        #(
          "text",
          json.object([
            #(
              "format",
              json.object([
                #("type", json.string("json_schema")),
                #("name", json.string("json_schema")),
                #("schema", schema),
              ]),
            ),
          ]),
        ),
      ])
    None -> base
  }

  let base = case ext.reasoning_effort {
    Some(effort) ->
      list.append(base, [
        #(
          "reasoning",
          json.object([
            #("effort", encode_reasoning_effort(effort)),
            #("summary", json.string("auto")),
          ]),
        ),
      ])
    None -> base
  }

  json.object(base)
}

fn encode_reasoning_effort(effort: ReasoningEffort) -> Json {
  case effort {
    ReasoningNone -> json.string("none")
    ReasoningLow -> json.string("low")
    ReasoningMedium -> json.string("medium")
    ReasoningHigh -> json.string("high")
    ReasoningXHigh -> json.string("xhigh")
  }
}

fn build_input(
  system_prompt: Option(String),
  messages: List(Message),
) -> List(Json) {
  let system_items = case system_prompt {
    Some(prompt) -> [
      json.object([
        #("role", json.string("system")),
        #("content", json.string(prompt)),
      ]),
    ]
    None -> []
  }

  let message_items =
    list.flat_map(messages, fn(msg) {
      case msg {
        UserMessage(content) -> build_user_item(content)
        AssistantMessage(content, tool_calls) ->
          build_assistant_items(content, tool_calls)
        ToolResultMessage(call_id, _name, content) ->
          build_tool_result_item(call_id, content)
      }
    })

  list.append(system_items, message_items)
}

fn build_user_item(content: String) -> List(Json) {
  [
    json.object([
      #("role", json.string("user")),
      #("content", json.string(content)),
    ]),
  ]
}

fn build_assistant_items(
  content: String,
  tool_calls: List(tool.Call),
) -> List(Json) {
  use <- bool.guard(when: list.is_empty(tool_calls), return: [
    json.object([
      #("role", json.string("assistant")),
      #("content", json.string(content)),
    ]),
  ])

  let text_output = case content {
    "" -> []
    _ -> [
      json.object([
        #("type", json.string("text")),
        #("text", json.string(content)),
      ]),
    ]
  }
  let tool_outputs =
    list.map(tool_calls, fn(call) {
      let args_str = json.to_string(tool.dynamic_to_json(call.arguments))
      json.object([
        #("type", json.string("function_call")),
        #("call_id", json.string(call.id)),
        #("name", json.string(call.name)),
        #("arguments", json.string(args_str)),
      ])
    })
  list.append(text_output, tool_outputs)
}

fn build_tool_result_item(call_id: String, content: String) -> List(Json) {
  [
    json.object([
      #("type", json.string("function_call_output")),
      #("call_id", json.string(call_id)),
      #("output", json.string(content)),
    ]),
  ]
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
                #("name", json.string(name)),
                #("description", json.string(description)),
                #("parameters", parameters),
              ])
          }
        }),
      )
  }
}

/// Decodes a JSON response from the OpenAI Responses API.
@internal
pub fn decode_response(body: String) -> Result(DecodedResponse, StarletError) {
  let output_item_decoder =
    decode.one_of(decode_message_item(), or: [
      decode_function_call_item(),
      decode_reasoning_summary_item(),
      decode_skipped_item(),
    ])

  let decoder = {
    use id <- decode.field("id", decode.string)
    use output <- decode.field("output", decode.list(output_item_decoder))
    decode.success(#(id, output))
  }

  case json.parse(body, decoder) {
    Ok(#(id, output_items)) -> {
      let text = extract_text(output_items)
      let tool_calls = extract_tool_calls(output_items)
      let reasoning = extract_reasoning_summary(output_items)
      Ok(DecodedResponse(
        response: Response(text: text, tool_calls: tool_calls),
        response_id: id,
        reasoning_summary: reasoning,
      ))
    }
    Error(err) ->
      Error(starlet.Decode(
        "Failed to decode OpenAI response: " <> string.inspect(err),
      ))
  }
}

type OutputItem {
  MessageItem(text: String)
  FunctionCallItem(call: tool.Call)
  ReasoningSummaryItem(text: String)
  SkippedItem
}

fn decode_output_text_content() -> decode.Decoder(String) {
  use type_ <- decode.field("type", decode.string)
  use <- bool.guard(when: type_ != "output_text", return: decode.success(""))

  use text <- decode.field("text", decode.string)
  decode.success(text)
}

fn decode_message_item() -> decode.Decoder(OutputItem) {
  use type_ <- decode.field("type", decode.string)
  use <- bool.guard(
    when: type_ != "message",
    return: decode.failure(MessageItem(""), "message"),
  )

  use content <- decode.field(
    "content",
    decode.list(decode_output_text_content()),
  )
  let text = string.join(content, "")
  decode.success(MessageItem(text))
}

fn decode_function_call_item() -> decode.Decoder(OutputItem) {
  use type_ <- decode.field("type", decode.string)
  case type_ {
    "function_call" -> {
      use call_id <- decode.field("call_id", decode.string)
      use name <- decode.field("name", decode.string)
      use arguments_str <- decode.field("arguments", decode.string)
      case json.parse(arguments_str, decode.dynamic) {
        Ok(arguments) ->
          decode.success(
            FunctionCallItem(tool.Call(id: call_id, name:, arguments:)),
          )
        Error(_) ->
          decode.failure(
            FunctionCallItem(tool.Call("", "", dynamic.nil())),
            "valid JSON arguments",
          )
      }
    }
    _ ->
      decode.failure(
        FunctionCallItem(tool.Call("", "", dynamic.nil())),
        "function_call",
      )
  }
}

fn decode_reasoning_summary_item() -> decode.Decoder(OutputItem) {
  use type_ <- decode.field("type", decode.string)
  case type_ {
    "reasoning" -> {
      use summary <- decode.field(
        "summary",
        decode.list(decode.at(["text"], decode.string)),
      )
      let text = string.join(summary, "\n")
      decode.success(ReasoningSummaryItem(text))
    }
    _ -> decode.failure(ReasoningSummaryItem(""), "reasoning")
  }
}

fn decode_skipped_item() -> decode.Decoder(OutputItem) {
  use _type <- decode.field("type", decode.string)
  decode.success(SkippedItem)
}

fn extract_text(items: List(OutputItem)) -> String {
  list.filter_map(items, fn(item) {
    case item {
      MessageItem(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("")
}

fn extract_tool_calls(items: List(OutputItem)) -> List(tool.Call) {
  list.filter_map(items, fn(item) {
    case item {
      FunctionCallItem(call) -> Ok(call)
      _ -> Error(Nil)
    }
  })
}

fn extract_reasoning_summary(items: List(OutputItem)) -> Option(String) {
  let summaries =
    list.filter_map(items, fn(item) {
      case item {
        ReasoningSummaryItem(text) -> Ok(text)
        _ -> Error(Nil)
      }
    })
  case summaries {
    [] -> None
    _ -> Some(string.join(summaries, "\n"))
  }
}

/// Get the response ID from an OpenAI turn.
pub fn response_id(turn: Turn(t, f, Ext)) -> Option(String) {
  turn.ext.response_id
}

/// Get the reasoning summary from an OpenAI turn (if present).
/// Only available for reasoning models (o1, o3, gpt-5).
pub fn reasoning_summary(turn: Turn(t, f, Ext)) -> Option(String) {
  turn.ext.reasoning_summary
}

/// Set the reasoning effort for reasoning models (o1, o3, gpt-5).
/// When not set, the provider's default applies (medium for reasoning models).
pub fn with_reasoning(
  chat: Chat(t, f, s, Ext),
  effort: ReasoningEffort,
) -> Chat(t, f, s, Ext) {
  Chat(..chat, ext: Ext(..chat.ext, reasoning_effort: Some(effort)))
}

/// Continue a conversation from a previous response ID.
/// The server will use its stored conversation state.
pub fn continue_from(chat: Chat(t, f, s, Ext), id: String) -> Chat(t, f, s, Ext) {
  Chat(..chat, ext: Ext(..chat.ext, response_id: Some(id)))
}

/// Reset the response ID, disabling automatic conversation continuation.
/// Use this to start a fresh conversation without the previous context.
pub fn reset_response_id(chat: Chat(t, f, s, Ext)) -> Chat(t, f, s, Ext) {
  Chat(..chat, ext: Ext(..chat.ext, response_id: None))
}

/// Decodes a JSON response from the OpenAI `/v1/models` endpoint.
@internal
pub fn decode_models(body: String) -> Result(List(Model), starlet.StarletError) {
  let model_decoder = {
    use id <- decode.field("id", decode.string)
    use owned_by <- decode.field("owned_by", decode.string)
    decode.success(Model(id: id, owned_by: owned_by))
  }

  let decoder = {
    use data <- decode.field("data", decode.list(model_decoder))
    decode.success(data)
  }

  json.parse(body, decoder)
  |> result.map_error(fn(err) {
    starlet.Decode("Failed to decode OpenAI models: " <> string.inspect(err))
  })
}

/// Lists available models from the OpenAI API.
pub fn list_models(api_key: String) -> Result(List(Model), starlet.StarletError) {
  list_models_with_base_url(api_key, "https://api.openai.com")
}

/// Lists available models from the OpenAI API with a custom base URL.
pub fn list_models_with_base_url(
  api_key: String,
  base_url: String,
) -> Result(List(Model), starlet.StarletError) {
  use base_uri <- result.try(
    uri.parse(base_url)
    |> result.replace_error(starlet.Transport("Invalid base URL: " <> base_url)),
  )

  let base_uri = internal_http.with_defaults(base_uri, "https", default_host)
  use http_request <- result.try(
    request.from_uri(base_uri)
    |> result.replace_error(starlet.Transport("Invalid base URL: " <> base_url)),
  )

  let http_request =
    http_request
    |> request.set_method(http.Get)
    |> request.set_path(base_uri.path <> "/v1/models")
    |> request.set_header("authorization", "Bearer " <> api_key)

  use response <- result.try(
    httpc.send(http_request)
    |> result.map_error(fn(err) { starlet.Transport(string.inspect(err)) }),
  )

  case response.status {
    200 -> decode_models(response.body)
    429 -> {
      let retry_after = internal_http.parse_retry_after(response.headers)
      Error(starlet.RateLimited(retry_after))
    }
    status -> Error(starlet.Http(status: status, body: response.body))
  }
}
