import birdie
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import starlet
import starlet/gemini
import starlet/tool

fn make_chat(
  model: String,
) -> starlet.Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, gemini.Ext) {
  let creds = gemini.credentials("test-api-key")
  gemini.chat(creds, model)
}

pub fn with_thinking_fixed_valid_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Ok(chat) = gemini.with_thinking(chat, gemini.ThinkingFixed(1024))
  assert chat.ext.thinking_budget == Some(gemini.ThinkingFixed(1024))
}

pub fn with_thinking_fixed_min_boundary_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Ok(chat) = gemini.with_thinking(chat, gemini.ThinkingFixed(1))
  assert chat.ext.thinking_budget == Some(gemini.ThinkingFixed(1))
}

pub fn with_thinking_fixed_max_boundary_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Ok(chat) = gemini.with_thinking(chat, gemini.ThinkingFixed(32_768))
  assert chat.ext.thinking_budget == Some(gemini.ThinkingFixed(32_768))
}

pub fn with_thinking_fixed_too_low_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Error(starlet.Provider("gemini", _, _)) =
    gemini.with_thinking(chat, gemini.ThinkingFixed(0))
}

pub fn with_thinking_fixed_too_high_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Error(starlet.Provider("gemini", _, _)) =
    gemini.with_thinking(chat, gemini.ThinkingFixed(32_769))
}

pub fn encode_simple_request_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode simple request")
}

pub fn encode_request_with_system_prompt_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.system("You are helpful")
    |> starlet.user("Hello")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request with system prompt")
}

pub fn encode_request_with_options_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.temperature(0.7)
    |> starlet.max_tokens(1000)
    |> starlet.user("Hello")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request with options")
}

pub fn encode_request_with_conversation_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")
    |> starlet.assistant("Hi there!")
    |> starlet.user("How are you?")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request with conversation")
}

pub fn encode_request_with_thinking_test() {
  let chat = make_chat("gemini-2.5-flash")
  let assert Ok(chat) = gemini.with_thinking(chat, gemini.ThinkingFixed(2048))
  let chat = starlet.user(chat, "Think about this")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request with thinking")
}

pub fn encode_request_with_thinking_dynamic_test() {
  let chat = make_chat("gemini-2.5-flash")
  let assert Ok(chat) = gemini.with_thinking(chat, gemini.ThinkingDynamic)
  let chat = starlet.user(chat, "Think about this")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request with thinking dynamic")
}

pub fn encode_request_with_thinking_off_test() {
  let chat = make_chat("gemini-2.5-flash")
  let assert Ok(chat) = gemini.with_thinking(chat, gemini.ThinkingOff)
  let chat = starlet.user(chat, "No thinking please")

  gemini.encode_request(chat)
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

  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What's the weather?")

  gemini.encode_request(chat)
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

  // Build chat with tool call and result
  let creds = gemini.credentials("test-api-key")
  let chat =
    gemini.chat(creds, "gemini-2.5-flash")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  // Manually add messages
  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("What's the weather in Paris?"),
      starlet.AssistantMessage("", [tool_call]),
      starlet.ToolResultMessage("gemini-0", "get_weather", tool_result),
    ])

  gemini.encode_request(chat)
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

  let assert Ok(#(text, _thinking, tool_calls)) = gemini.decode_response(body)
  assert text == "Hello there!"
  assert tool_calls == []
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

  let assert Ok(#(text, _thinking, _tool_calls)) = gemini.decode_response(body)
  assert text == "Hello there!"
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

  let assert Ok(#(text, _thinking, tool_calls)) = gemini.decode_response(body)
  assert text == ""

  let assert [call] = tool_calls
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
                    json.object([
                      #("text", json.string("Let me think...")),
                      #("thought", json.bool(True)),
                    ]),
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

  let assert Ok(#(text, thinking, _tool_calls)) = gemini.decode_response(body)
  assert text == "The answer is 42"
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

  let assert Ok(#(_text, _thinking, tool_calls)) = gemini.decode_response(body)
  let assert [call1, call2] = tool_calls
  assert call1.name == "get_weather"
  assert call1.id == "gemini-0"
  assert call2.name == "get_time"
  assert call2.id == "gemini-1"
}
