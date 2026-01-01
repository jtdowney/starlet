import birdie
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import starlet.{AssistantMessage, Request, ToolResultMessage, UserMessage}
import starlet/openai
import starlet/tool

fn default_ext() -> openai.Ext {
  openai.Ext(response_id: None, reasoning_effort: None, reasoning_summary: None)
}

pub fn encode_simple_request_test() {
  let req =
    Request(
      model: "gpt-5-nano",
      system_prompt: None,
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai encode simple request")
}

pub fn encode_request_with_system_prompt_test() {
  let req =
    Request(
      model: "gpt-5-nano",
      system_prompt: Some("Be helpful"),
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai encode request with system prompt")
}

pub fn encode_request_with_previous_response_id_test() {
  let req =
    Request(
      model: "gpt-5-nano",
      system_prompt: None,
      messages: [UserMessage("Follow up")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  let ext =
    openai.Ext(
      response_id: Some("resp_abc123"),
      reasoning_effort: None,
      reasoning_summary: None,
    )

  openai.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("openai encode request with previous response id")
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
      model: "gpt-5-nano",
      system_prompt: None,
      messages: [UserMessage("What's the weather?")],
      tools: [weather_tool],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai encode request with tools")
}

pub fn encode_request_with_tool_result_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "call_123", name: "get_weather", arguments:)
  let tool_result = json.object([#("temp", json.int(22))]) |> json.to_string

  let req =
    Request(
      model: "gpt-5-nano",
      system_prompt: None,
      messages: [
        UserMessage("What's the weather in Paris?"),
        AssistantMessage("", [tool_call]),
        ToolResultMessage("call_123", "get_weather", tool_result),
      ],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai encode request with tool result")
}

pub fn encode_request_with_options_test() {
  let req =
    Request(
      model: "gpt-5-nano",
      system_prompt: None,
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: Some(0.7),
      max_tokens: Some(1000),
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai encode request with options")
}

pub fn decode_simple_response_test() {
  let body =
    json.object([
      #("id", json.string("resp_123")),
      #(
        "output",
        json.preprocessed_array([
          json.object([
            #("type", json.string("message")),
            #(
              "content",
              json.preprocessed_array([
                json.object([
                  #("type", json.string("output_text")),
                  #("text", json.string("Hello!")),
                ]),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(decoded) = openai.decode_response(body)
  assert decoded.response.text == "Hello!"
  assert decoded.response_id == "resp_123"
}

pub fn decode_response_with_tool_calls_test() {
  let args = json.object([#("city", json.string("Paris"))]) |> json.to_string
  let body =
    json.object([
      #("id", json.string("resp_456")),
      #(
        "output",
        json.preprocessed_array([
          json.object([
            #("type", json.string("function_call")),
            #("call_id", json.string("call_abc")),
            #("name", json.string("get_weather")),
            #("arguments", json.string(args)),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(decoded) = openai.decode_response(body)
  assert decoded.response.text == ""
  assert decoded.response_id == "resp_456"

  let assert [call] = decoded.response.tool_calls
  assert call.id == "call_abc"
  assert call.name == "get_weather"
  let assert Ok("Paris") =
    decode.run(call.arguments, decode.at(["city"], decode.string))
}

pub fn decode_invalid_json_returns_error_test() {
  let body = "not json"
  let assert Error(starlet.Decode(_)) = openai.decode_response(body)
}

pub fn decode_models_response_test() {
  let body =
    json.object([
      #("object", json.string("list")),
      #(
        "data",
        json.preprocessed_array([
          json.object([
            #("id", json.string("gpt-4o")),
            #("object", json.string("model")),
            #("owned_by", json.string("openai")),
          ]),
          json.object([
            #("id", json.string("gpt-4o-mini")),
            #("object", json.string("model")),
            #("owned_by", json.string("openai")),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(models) = openai.decode_models(body)
  assert models
    == [
      openai.Model(id: "gpt-4o", owned_by: "openai"),
      openai.Model(id: "gpt-4o-mini", owned_by: "openai"),
    ]
}

pub fn decode_models_empty_list_test() {
  let body =
    json.object([
      #("object", json.string("list")),
      #("data", json.preprocessed_array([])),
    ])
    |> json.to_string

  let assert Ok(models) = openai.decode_models(body)
  assert models == []
}

pub fn decode_models_invalid_json_test() {
  let body = "not json"
  let assert Error(_) = openai.decode_models(body)
}

pub fn encode_request_with_reasoning_effort_test() {
  let req =
    Request(
      model: "gpt-5-nano",
      system_prompt: None,
      messages: [UserMessage("Think hard about this")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  let ext =
    openai.Ext(
      response_id: None,
      reasoning_effort: Some(openai.ReasoningHigh),
      reasoning_summary: None,
    )

  openai.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("openai encode request with reasoning effort")
}
