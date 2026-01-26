import birdie
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import starlet
import starlet/openai
import starlet/tool

fn make_chat(
  model: String,
) -> starlet.Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, openai.Ext) {
  let creds = openai.credentials("sk-test-key")
  openai.chat(creds, model)
}

pub fn encode_simple_request_test() {
  let chat =
    make_chat("gpt-5-nano")
    |> starlet.user("Hello")

  openai.encode_request(chat)
  |> json.to_string
  |> birdie.snap("openai encode simple request")
}

pub fn encode_request_with_system_prompt_test() {
  let chat =
    make_chat("gpt-5-nano")
    |> starlet.system("Be helpful")
    |> starlet.user("Hello")

  openai.encode_request(chat)
  |> json.to_string
  |> birdie.snap("openai encode request with system prompt")
}

pub fn encode_request_with_previous_response_id_test() {
  let creds = openai.credentials("sk-test-key")
  let chat = openai.chat(creds, "gpt-5-nano")
  // Set the response_id in ext
  let chat =
    starlet.Chat(
      ..chat,
      ext: openai.Ext(
        response_id: Some("resp_abc123"),
        reasoning_effort: None,
        reasoning_summary: None,
      ),
    )
  let chat = starlet.user(chat, "Follow up")

  openai.encode_request(chat)
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

  let chat =
    make_chat("gpt-5-nano")
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What's the weather?")

  openai.encode_request(chat)
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

  // Build chat with tool call and result
  let creds = openai.credentials("sk-test-key")
  let chat =
    openai.chat(creds, "gpt-5-nano")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  // Manually add messages
  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("What's the weather in Paris?"),
      starlet.AssistantMessage("", [tool_call]),
      starlet.ToolResultMessage("call_123", "get_weather", tool_result),
    ])

  openai.encode_request(chat)
  |> json.to_string
  |> birdie.snap("openai encode request with tool result")
}

pub fn encode_request_with_options_test() {
  let chat =
    make_chat("gpt-5-nano")
    |> starlet.temperature(0.7)
    |> starlet.max_tokens(1000)
    |> starlet.user("Hello")

  openai.encode_request(chat)
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
  assert decoded.text == "Hello!"
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
  assert decoded.text == ""
  assert decoded.response_id == "resp_456"

  let assert [call] = decoded.tool_calls
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
  let creds = openai.credentials("sk-test-key")
  let chat = openai.chat(creds, "gpt-5-nano")
  // Set reasoning effort in ext
  let chat =
    starlet.Chat(
      ..chat,
      ext: openai.Ext(
        response_id: None,
        reasoning_effort: Some(openai.ReasoningHigh),
        reasoning_summary: None,
      ),
    )
  let chat = starlet.user(chat, "Think hard about this")

  openai.encode_request(chat)
  |> json.to_string
  |> birdie.snap("openai encode request with reasoning effort")
}
