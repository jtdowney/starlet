import birdie
import gleam/dynamic/decode
import gleam/json
import gleam/string
import starlet
import starlet/anthropic
import starlet/tool

fn make_chat(
  model: String,
) -> starlet.Chat(
  starlet.ToolsOff,
  starlet.FreeText,
  starlet.Empty,
  anthropic.Ext,
) {
  let creds = anthropic.credentials("sk-ant-test-key")
  anthropic.chat(creds, model)
}

pub fn encode_simple_request_test() {
  let chat =
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.user("Hello")

  anthropic.encode_request(chat)
  |> json.to_string
  |> birdie.snap("anthropic encode simple request")
}

pub fn encode_request_with_system_prompt_test() {
  let chat =
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.system("Be helpful")
    |> starlet.user("Hello")

  anthropic.encode_request(chat)
  |> json.to_string
  |> birdie.snap("anthropic encode request with system prompt")
}

pub fn encode_request_applies_default_max_tokens_test() {
  let chat =
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.user("Hello")

  let encoded = anthropic.encode_request(chat) |> json.to_string
  assert string.contains(encoded, "\"max_tokens\":4096")
}

pub fn encode_request_respects_explicit_max_tokens_test() {
  let chat =
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.max_tokens(1000)
    |> starlet.user("Hello")

  let encoded = anthropic.encode_request(chat) |> json.to_string
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

  let chat =
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What's the weather?")

  anthropic.encode_request(chat)
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

  // Build chat with tool call and result
  let creds = anthropic.credentials("sk-ant-test-key")
  let chat =
    anthropic.chat(creds, "claude-haiku-4-5-20251001")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  // Manually add messages
  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("What's the weather in Paris?"),
      starlet.AssistantMessage("", [tool_call]),
      starlet.ToolResultMessage("toolu_123", "get_weather", tool_result),
    ])

  anthropic.encode_request(chat)
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

  let assert Ok(#(text, _thinking, tool_calls)) =
    anthropic.decode_response(body)
  assert text == "Hello!"
  assert tool_calls == []
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

  let assert Ok(#(text, _thinking, tool_calls)) =
    anthropic.decode_response(body)
  assert text == ""

  let assert [call] = tool_calls
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
  let creds = anthropic.credentials("sk-ant-test-key")
  let chat = anthropic.chat(creds, "claude-haiku-4-5-20251001")
  let chat = starlet.max_tokens(chat, 32_000)
  let assert Ok(chat) = anthropic.with_thinking(chat, 16_384)
  let chat = starlet.user(chat, "Think step by step")

  anthropic.encode_request(chat)
  |> json.to_string
  |> birdie.snap("anthropic encode request with thinking")
}

pub fn with_thinking_valid_budget_test() {
  let creds = anthropic.credentials("test-key")
  let chat = anthropic.chat(creds, "claude-haiku-4-5-20251001")

  let assert Ok(_chat) = anthropic.with_thinking(chat, 1024)
  let assert Ok(_chat) = anthropic.with_thinking(chat, 16_384)
}

pub fn with_thinking_invalid_budget_test() {
  let creds = anthropic.credentials("test-key")
  let chat = anthropic.chat(creds, "claude-haiku-4-5-20251001")

  let assert Error(starlet.Provider(provider: "anthropic", message: msg, raw: _)) =
    anthropic.with_thinking(chat, 1023)
  assert string.contains(msg, "1024")
}
