import birdie
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import starlet.{AssistantMessage, Request, ToolResultMessage, UserMessage}
import starlet/anthropic
import starlet/tool

fn default_ext() -> anthropic.Ext {
  anthropic.Ext(thinking_budget: None, thinking: None)
}

pub fn new_creates_client_test() {
  let client = anthropic.new("sk-ant-test-key")
  assert starlet.provider_name(client) == "anthropic"
}

pub fn encode_simple_request_test() {
  let req =
    Request(
      model: "claude-haiku-4-5-20251001",
      system_prompt: None,
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  anthropic.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("anthropic encode simple request")
}

pub fn encode_request_with_system_prompt_test() {
  let req =
    Request(
      model: "claude-haiku-4-5-20251001",
      system_prompt: Some("Be helpful"),
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  anthropic.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("anthropic encode request with system prompt")
}

pub fn encode_request_applies_default_max_tokens_test() {
  let req =
    Request(
      model: "claude-haiku-4-5-20251001",
      system_prompt: None,
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  let encoded = anthropic.encode_request(req, default_ext()) |> json.to_string
  assert string.contains(encoded, "\"max_tokens\":4096")
}

pub fn encode_request_respects_explicit_max_tokens_test() {
  let req =
    Request(
      model: "claude-haiku-4-5-20251001",
      system_prompt: None,
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: None,
      max_tokens: Some(1000),
      json_schema: None,
      timeout_ms: 60_000,
    )

  let encoded = anthropic.encode_request(req, default_ext()) |> json.to_string
  assert string.contains(encoded, "\"max_tokens\":1000")
}

pub fn encode_request_with_tools_test() {
  let weather_tool =
    tool.function(
      name: "get_weather",
      description: "Get current weather",
      parameters: json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #("city", json.object([#("type", json.string("string"))])),
          ]),
        ),
      ]),
    )

  let req =
    Request(
      model: "claude-haiku-4-5-20251001",
      system_prompt: None,
      messages: [UserMessage("What's the weather?")],
      tools: [weather_tool],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  anthropic.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("anthropic encode request with tools")
}

pub fn encode_request_with_tool_result_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "toolu_123", name: "get_weather", arguments:)
  let tool_result = json.object([#("temp", json.int(22))]) |> json.to_string

  let req =
    Request(
      model: "claude-haiku-4-5-20251001",
      system_prompt: None,
      messages: [
        UserMessage("What's the weather in Paris?"),
        AssistantMessage("", [tool_call]),
        ToolResultMessage("toolu_123", "get_weather", tool_result),
      ],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  anthropic.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("anthropic encode request with tool result")
}

pub fn decode_simple_response_test() {
  let body =
    json.object([
      #("id", json.string("msg_123")),
      #("type", json.string("message")),
      #("role", json.string("assistant")),
      #(
        "content",
        json.preprocessed_array([
          json.object([
            #("type", json.string("text")),
            #("text", json.string("Hello!")),
          ]),
        ]),
      ),
      #("stop_reason", json.string("end_turn")),
      #(
        "usage",
        json.object([
          #("input_tokens", json.int(10)),
          #("output_tokens", json.int(5)),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(response, _thinking)) = anthropic.decode_response(body)
  assert response.text == "Hello!"
  assert response.tool_calls == []
}

pub fn decode_response_with_tool_calls_test() {
  let body =
    json.object([
      #("id", json.string("msg_456")),
      #("type", json.string("message")),
      #("role", json.string("assistant")),
      #(
        "content",
        json.preprocessed_array([
          json.object([
            #("type", json.string("tool_use")),
            #("id", json.string("toolu_abc")),
            #("name", json.string("get_weather")),
            #("input", json.object([#("city", json.string("Paris"))])),
          ]),
        ]),
      ),
      #("stop_reason", json.string("tool_use")),
      #(
        "usage",
        json.object([
          #("input_tokens", json.int(10)),
          #("output_tokens", json.int(15)),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(response, _thinking)) = anthropic.decode_response(body)
  assert response.text == ""

  let assert [call] = response.tool_calls
  assert call.id == "toolu_abc"
  assert call.name == "get_weather"
  let assert Ok("Paris") =
    decode.run(call.arguments, decode.at(["city"], decode.string))
}

pub fn decode_invalid_json_returns_error_test() {
  let body = "not json"
  let assert Error(starlet.Decode(_)) = anthropic.decode_response(body)
}

pub fn decode_error_response_test() {
  let body =
    json.object([
      #("type", json.string("error")),
      #(
        "error",
        json.object([
          #("type", json.string("invalid_request_error")),
          #("message", json.string("Invalid API key")),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok("Invalid API key") = anthropic.decode_error_response(body)
}

pub fn encode_request_with_thinking_test() {
  let req =
    Request(
      model: "claude-haiku-4-5-20251001",
      system_prompt: None,
      messages: [UserMessage("Think step by step")],
      tools: [],
      temperature: None,
      max_tokens: Some(32_000),
      json_schema: None,
      timeout_ms: 60_000,
    )

  let ext = anthropic.Ext(thinking_budget: Some(16_384), thinking: None)

  anthropic.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("anthropic encode request with thinking")
}

pub fn with_thinking_valid_budget_test() {
  let client = anthropic.new("test-key")
  let chat = starlet.chat(client, "claude-haiku-4-5-20251001")

  let assert Ok(_chat) = anthropic.with_thinking(chat, 1024)
  let assert Ok(_chat) = anthropic.with_thinking(chat, 16_384)
}

pub fn with_thinking_invalid_budget_test() {
  let client = anthropic.new("test-key")
  let chat = starlet.chat(client, "claude-haiku-4-5-20251001")

  let assert Error(starlet.Provider(provider: "anthropic", message: msg, raw: _)) =
    anthropic.with_thinking(chat, 1023)
  assert string.contains(msg, "1024")
}
