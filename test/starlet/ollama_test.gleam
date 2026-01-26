import birdie
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import starlet
import starlet/ollama
import starlet/tool

fn make_chat(
  model: String,
) -> starlet.Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, ollama.Ext) {
  let creds = ollama.credentials("http://localhost:11434")
  ollama.chat(creds, model)
}

pub fn encode_simple_request_test() {
  let chat =
    make_chat("qwen3")
    |> starlet.user("Hello")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("encode simple request")
}

pub fn encode_request_with_system_prompt_test() {
  let chat =
    make_chat("qwen3")
    |> starlet.system("Be helpful")
    |> starlet.user("Hello")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("encode request with system prompt")
}

pub fn encode_request_with_options_test() {
  let chat =
    make_chat("qwen3")
    |> starlet.temperature(0.7)
    |> starlet.max_tokens(1000)
    |> starlet.user("Hello")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("encode request with options")
}

pub fn encode_request_with_conversation_test() {
  let chat =
    make_chat("qwen3")
    |> starlet.user("Hello")
    |> starlet.assistant("Hi!")
    |> starlet.user("How are you?")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("encode request with conversation")
}

pub fn decode_simple_response_test() {
  let body =
    json.object([
      #(
        "message",
        json.object([
          #("role", json.string("assistant")),
          #("content", json.string("Hello there!")),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(text, _thinking, tool_calls)) = ollama.decode_response(body)
  assert text == "Hello there!"
  assert tool_calls == []
}

pub fn decode_response_with_extra_fields_test() {
  let body =
    json.object([
      #("model", json.string("qwen3")),
      #(
        "message",
        json.object([
          #("role", json.string("assistant")),
          #("content", json.string("Hi")),
        ]),
      ),
      #("done", json.bool(True)),
    ])
    |> json.to_string

  let assert Ok(#(text, _thinking, _tool_calls)) = ollama.decode_response(body)
  assert text == "Hi"
}

pub fn decode_invalid_json_returns_error_test() {
  let body = "not json"
  let assert Error(starlet.Decode(_)) = ollama.decode_response(body)
}

pub fn decode_missing_message_returns_error_test() {
  let body =
    json.object([#("model", json.string("qwen3"))])
    |> json.to_string
  let assert Error(starlet.Decode(_)) = ollama.decode_response(body)
}

pub fn encode_request_with_tools_test() {
  let weather_tool =
    tool.function(
      name: "get_weather",
      description: "Get the current weather for a city",
      parameters: json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #("city", json.object([#("type", json.string("string"))])),
          ]),
        ),
        #("required", json.array(["city"], json.string)),
      ]),
    )

  let chat =
    make_chat("qwen3")
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What's the weather in Paris?")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("encode request with tools")
}

pub fn encode_request_with_tool_calls_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "call_123", name: "get_weather", arguments:)

  // Build chat with tool call in assistant message
  let creds = ollama.credentials("http://localhost:11434")
  let chat =
    ollama.chat(creds, "qwen3")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  // Manually add assistant message with tool call
  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("What's the weather in Paris?"),
      starlet.AssistantMessage("", [tool_call]),
    ])

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("encode request with tool calls")
}

pub fn encode_request_with_tool_result_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "call_123", name: "get_weather", arguments:)
  let tool_result =
    json.object([
      #("temp", json.int(22)),
      #("condition", json.string("sunny")),
    ])
    |> json.to_string

  // Build chat with tool call and result
  let creds = ollama.credentials("http://localhost:11434")
  let chat =
    ollama.chat(creds, "qwen3")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  // Manually add messages
  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("What's the weather in Paris?"),
      starlet.AssistantMessage("", [tool_call]),
      starlet.ToolResultMessage("call_123", "get_weather", tool_result),
    ])

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("encode request with tool result")
}

pub fn decode_response_with_tool_calls_test() {
  let args = json.object([#("city", json.string("Paris"))]) |> json.to_string
  let body =
    json.object([
      #(
        "message",
        json.object([
          #("role", json.string("assistant")),
          #("content", json.string("")),
          #(
            "tool_calls",
            json.preprocessed_array([
              json.object([
                #("id", json.string("call_abc")),
                #(
                  "function",
                  json.object([
                    #("name", json.string("get_weather")),
                    #("arguments", json.string(args)),
                  ]),
                ),
              ]),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(text, _thinking, tool_calls)) = ollama.decode_response(body)
  assert text == ""

  let assert [call] = tool_calls
  assert call.id == "call_abc"
  assert call.name == "get_weather"
  let assert Ok("Paris") =
    decode.run(call.arguments, decode.at(["city"], decode.string))
}

pub fn decode_response_without_tool_call_id_test() {
  let args = json.object([#("city", json.string("Paris"))]) |> json.to_string
  let body =
    json.object([
      #(
        "message",
        json.object([
          #("role", json.string("assistant")),
          #("content", json.string("")),
          #(
            "tool_calls",
            json.preprocessed_array([
              json.object([
                #(
                  "function",
                  json.object([
                    #("name", json.string("get_weather")),
                    #("arguments", json.string(args)),
                  ]),
                ),
              ]),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(_text, _thinking, tool_calls)) = ollama.decode_response(body)

  let assert [call] = tool_calls
  assert call.id == "get_weather_call"
  assert call.name == "get_weather"
}

pub fn decode_models_response_test() {
  let body =
    json.object([
      #(
        "models",
        json.preprocessed_array([
          json.object([
            #("name", json.string("qwen3:0.6b")),
            #("model", json.string("qwen3:0.6b")),
            #("size", json.int(522_653_767)),
            #(
              "details",
              json.object([
                #("parameter_size", json.string("751.63M")),
                #("quantization_level", json.string("Q4_K_M")),
              ]),
            ),
          ]),
          json.object([
            #("name", json.string("llama3.2:1b")),
            #("model", json.string("llama3.2:1b")),
            #("size", json.int(1_321_098_329)),
            #(
              "details",
              json.object([
                #("parameter_size", json.string("1.2B")),
                #("quantization_level", json.string("Q8_0")),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(models) = ollama.decode_models(body)
  assert models
    == [
      ollama.Model(name: "qwen3:0.6b", size: "751.63M"),
      ollama.Model(name: "llama3.2:1b", size: "1.2B"),
    ]
}

pub fn decode_models_empty_list_test() {
  let body =
    json.object([#("models", json.preprocessed_array([]))])
    |> json.to_string

  let assert Ok(models) = ollama.decode_models(body)
  assert models == []
}

pub fn decode_models_invalid_json_test() {
  let body = "not json"
  let assert Error(_) = ollama.decode_models(body)
}

pub fn encode_request_with_thinking_enabled_test() {
  let chat =
    make_chat("deepseek-r1")
    |> ollama.with_thinking(ollama.ThinkingEnabled)
    |> starlet.user("Think step by step")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with thinking enabled")
}

pub fn encode_request_with_thinking_effort_test() {
  let chat =
    make_chat("deepseek-r1")
    |> ollama.with_thinking(ollama.ThinkingHigh)
    |> starlet.user("Think step by step")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with thinking high")
}

pub fn encode_request_with_json_schema_test() {
  let schema =
    json.object([
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #("name", json.object([#("type", json.string("string"))])),
          #("capital", json.object([#("type", json.string("string"))])),
          #(
            "languages",
            json.object([
              #("type", json.string("array")),
              #("items", json.object([#("type", json.string("string"))])),
            ]),
          ),
        ]),
      ),
      #("required", json.array(["name", "capital", "languages"], json.string)),
    ])

  // Need to use with_json_output which expects jscheam schema, so we'll test via Chat directly
  let creds = ollama.credentials("http://localhost:11434")
  let chat = ollama.chat(creds, "qwen3")
  let chat = starlet.Chat(..chat, json_schema: Some(schema))
  let chat = starlet.user(chat, "Tell me about France")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with json schema")
}
