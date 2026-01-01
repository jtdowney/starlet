import birdie
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import starlet.{AssistantMessage, Request, ToolResultMessage, UserMessage}
import starlet/gemini
import starlet/tool

pub fn new_creates_client_test() {
  let client = gemini.new("test-api-key")
  assert starlet.provider_name(client) == "gemini"
}

pub fn with_thinking_dynamic_test() {
  let client = gemini.new("test-api-key")
  let chat =
    starlet.chat(client, "gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Ok(chat) = gemini.with_thinking(chat, gemini.ThinkingDynamic)
  assert chat.ext.thinking_budget == Some(gemini.ThinkingDynamic)
}

pub fn with_thinking_off_test() {
  let client = gemini.new("test-api-key")
  let chat =
    starlet.chat(client, "gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Ok(chat) = gemini.with_thinking(chat, gemini.ThinkingOff)
  assert chat.ext.thinking_budget == Some(gemini.ThinkingOff)
}

pub fn with_thinking_fixed_valid_test() {
  let client = gemini.new("test-api-key")
  let chat =
    starlet.chat(client, "gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Ok(chat) = gemini.with_thinking(chat, gemini.ThinkingFixed(1024))
  assert chat.ext.thinking_budget == Some(gemini.ThinkingFixed(1024))
}

pub fn with_thinking_fixed_min_boundary_test() {
  let client = gemini.new("test-api-key")
  let chat =
    starlet.chat(client, "gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Ok(chat) = gemini.with_thinking(chat, gemini.ThinkingFixed(1))
  assert chat.ext.thinking_budget == Some(gemini.ThinkingFixed(1))
}

pub fn with_thinking_fixed_max_boundary_test() {
  let client = gemini.new("test-api-key")
  let chat =
    starlet.chat(client, "gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Ok(chat) = gemini.with_thinking(chat, gemini.ThinkingFixed(32_768))
  assert chat.ext.thinking_budget == Some(gemini.ThinkingFixed(32_768))
}

pub fn with_thinking_fixed_too_low_test() {
  let client = gemini.new("test-api-key")
  let chat =
    starlet.chat(client, "gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Error(starlet.Provider("gemini", _, _)) =
    gemini.with_thinking(chat, gemini.ThinkingFixed(0))
}

pub fn with_thinking_fixed_too_high_test() {
  let client = gemini.new("test-api-key")
  let chat =
    starlet.chat(client, "gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Error(starlet.Provider("gemini", _, _)) =
    gemini.with_thinking(chat, gemini.ThinkingFixed(32_769))
}

pub fn thinking_accessor_test() {
  let turn =
    starlet.Turn(
      text: "Hi",
      tool_calls: [],
      ext: gemini.Ext(
        thinking_budget: None,
        thinking: Some("I thought about this"),
      ),
    )
  assert gemini.thinking(turn) == Some("I thought about this")
}

pub fn thinking_accessor_none_test() {
  let turn =
    starlet.Turn(
      text: "Hi",
      tool_calls: [],
      ext: gemini.Ext(thinking_budget: None, thinking: None),
    )
  assert gemini.thinking(turn) == None
}

fn default_ext() -> gemini.Ext {
  gemini.Ext(thinking_budget: None, thinking: None)
}

pub fn encode_simple_request_test() {
  let req =
    Request(
      model: "gemini-2.5-flash",
      system_prompt: None,
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  gemini.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("gemini encode simple request")
}

pub fn encode_request_with_system_prompt_test() {
  let req =
    Request(
      model: "gemini-2.5-flash",
      system_prompt: Some("You are helpful"),
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  gemini.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("gemini encode request with system prompt")
}

pub fn encode_request_with_options_test() {
  let req =
    Request(
      model: "gemini-2.5-flash",
      system_prompt: None,
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: Some(0.7),
      max_tokens: Some(1000),
      json_schema: None,
      timeout_ms: 60_000,
    )

  gemini.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("gemini encode request with options")
}

pub fn encode_request_with_conversation_test() {
  let req =
    Request(
      model: "gemini-2.5-flash",
      system_prompt: None,
      messages: [
        UserMessage("Hello"),
        AssistantMessage("Hi there!", []),
        UserMessage("How are you?"),
      ],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  gemini.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("gemini encode request with conversation")
}

pub fn encode_request_with_thinking_test() {
  let req =
    Request(
      model: "gemini-2.5-flash",
      system_prompt: None,
      messages: [UserMessage("Think about this")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  let ext =
    gemini.Ext(
      thinking_budget: Some(gemini.ThinkingFixed(2048)),
      thinking: None,
    )

  gemini.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("gemini encode request with thinking")
}

pub fn encode_request_with_thinking_dynamic_test() {
  let req =
    Request(
      model: "gemini-2.5-flash",
      system_prompt: None,
      messages: [UserMessage("Think about this")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  let ext =
    gemini.Ext(thinking_budget: Some(gemini.ThinkingDynamic), thinking: None)

  gemini.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("gemini encode request with thinking dynamic")
}

pub fn encode_request_with_thinking_off_test() {
  let req =
    Request(
      model: "gemini-2.5-flash",
      system_prompt: None,
      messages: [UserMessage("No thinking please")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  let ext =
    gemini.Ext(thinking_budget: Some(gemini.ThinkingOff), thinking: None)

  gemini.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("gemini encode request with thinking off")
}

// Tool encoding tests

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
      model: "gemini-2.5-flash",
      system_prompt: None,
      messages: [UserMessage("What's the weather?")],
      tools: [weather_tool],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  gemini.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("gemini encode request with tools")
}

pub fn encode_request_with_tool_result_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "gemini-0", name: "get_weather", arguments:)
  let tool_result = json.object([#("temp", json.int(22))]) |> json.to_string

  let req =
    Request(
      model: "gemini-2.5-flash",
      system_prompt: None,
      messages: [
        UserMessage("What's the weather in Paris?"),
        AssistantMessage("", [tool_call]),
        ToolResultMessage("gemini-0", "get_weather", tool_result),
      ],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  gemini.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("gemini encode request with tool result")
}

// Response decoding tests

pub fn decode_simple_response_test() {
  let body =
    json.object([
      #(
        "candidates",
        json.preprocessed_array([
          json.object([
            #(
              "content",
              json.object([
                #("role", json.string("model")),
                #(
                  "parts",
                  json.preprocessed_array([
                    json.object([#("text", json.string("Hello there!"))]),
                  ]),
                ),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(response, _thinking)) = gemini.decode_response(body)
  assert response.text == "Hello there!"
}

pub fn decode_response_with_multiple_text_parts_test() {
  let body =
    json.object([
      #(
        "candidates",
        json.preprocessed_array([
          json.object([
            #(
              "content",
              json.object([
                #("role", json.string("model")),
                #(
                  "parts",
                  json.preprocessed_array([
                    json.object([#("text", json.string("Hello "))]),
                    json.object([#("text", json.string("there!"))]),
                  ]),
                ),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(response, _thinking)) = gemini.decode_response(body)
  assert response.text == "Hello there!"
}

pub fn decode_response_with_tool_call_test() {
  let body =
    json.object([
      #(
        "candidates",
        json.preprocessed_array([
          json.object([
            #(
              "content",
              json.object([
                #("role", json.string("model")),
                #(
                  "parts",
                  json.preprocessed_array([
                    json.object([
                      #(
                        "functionCall",
                        json.object([
                          #("name", json.string("get_weather")),
                          #(
                            "args",
                            json.object([#("city", json.string("Paris"))]),
                          ),
                        ]),
                      ),
                    ]),
                  ]),
                ),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(response, _thinking)) = gemini.decode_response(body)
  assert response.text == ""

  let assert [call] = response.tool_calls
  assert call.name == "get_weather"
  let assert Ok("Paris") =
    decode.run(call.arguments, decode.at(["city"], decode.string))
}

pub fn decode_response_with_thinking_test() {
  let body =
    json.object([
      #(
        "candidates",
        json.preprocessed_array([
          json.object([
            #(
              "content",
              json.object([
                #("role", json.string("model")),
                #(
                  "parts",
                  json.preprocessed_array([
                    json.object([#("thought", json.string("Let me think..."))]),
                    json.object([#("text", json.string("The answer is 42"))]),
                  ]),
                ),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(response, thinking)) = gemini.decode_response(body)
  assert response.text == "The answer is 42"
  assert thinking == Some("Let me think...")
}

pub fn decode_invalid_json_returns_error_test() {
  let body = "not json"
  let assert Error(starlet.Decode(_)) = gemini.decode_response(body)
}

pub fn decode_empty_candidates_returns_error_test() {
  let body =
    json.object([#("candidates", json.preprocessed_array([]))])
    |> json.to_string
  let assert Error(starlet.Decode(_)) = gemini.decode_response(body)
}

pub fn decode_response_with_multiple_tool_calls_test() {
  let body =
    json.object([
      #(
        "candidates",
        json.preprocessed_array([
          json.object([
            #(
              "content",
              json.object([
                #("role", json.string("model")),
                #(
                  "parts",
                  json.preprocessed_array([
                    json.object([
                      #(
                        "functionCall",
                        json.object([
                          #("name", json.string("get_weather")),
                          #(
                            "args",
                            json.object([#("city", json.string("Paris"))]),
                          ),
                        ]),
                      ),
                    ]),
                    json.object([
                      #(
                        "functionCall",
                        json.object([
                          #("name", json.string("get_time")),
                          #(
                            "args",
                            json.object([#("timezone", json.string("UTC"))]),
                          ),
                        ]),
                      ),
                    ]),
                  ]),
                ),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(response, _thinking)) = gemini.decode_response(body)
  let assert [call1, call2] = response.tool_calls
  assert call1.name == "get_weather"
  assert call1.id == "gemini-0"
  assert call2.name == "get_time"
  assert call2.id == "gemini-1"
}
