import birdie
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import starlet.{
  AssistantMessage, Decode, Request, ToolResultMessage, UserMessage,
}
import starlet/ollama
import starlet/tool

fn default_ext() -> ollama.Ext {
  ollama.Ext(thinking: None, thinking_content: None)
}

pub fn encode_simple_request_test() {
  let req =
    Request(
      model: "qwen3",
      system_prompt: None,
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  ollama.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("encode simple request")
}

pub fn encode_request_with_system_prompt_test() {
  let req =
    Request(
      model: "qwen3",
      system_prompt: Some("Be helpful"),
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  ollama.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("encode request with system prompt")
}

pub fn encode_request_with_options_test() {
  let req =
    Request(
      model: "qwen3",
      system_prompt: None,
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: Some(0.7),
      max_tokens: Some(1000),
      json_schema: None,
      timeout_ms: 60_000,
    )

  ollama.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("encode request with options")
}

pub fn encode_request_with_conversation_test() {
  let req =
    Request(
      model: "qwen3",
      system_prompt: None,
      messages: [
        UserMessage("Hello"),
        AssistantMessage("Hi!", []),
        UserMessage("How are you?"),
      ],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  ollama.encode_request(req, default_ext())
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

  let assert Ok(#(response, _thinking)) = ollama.decode_response(body)
  assert response.text == "Hello there!"
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

  let assert Ok(#(response, _thinking)) = ollama.decode_response(body)
  assert response.text == "Hi"
}

pub fn decode_invalid_json_returns_error_test() {
  let body = "not json"
  let assert Error(Decode(_)) = ollama.decode_response(body)
}

pub fn decode_missing_message_returns_error_test() {
  let body =
    json.object([#("model", json.string("qwen3"))])
    |> json.to_string
  let assert Error(Decode(_)) = ollama.decode_response(body)
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

  let req =
    Request(
      model: "qwen3",
      system_prompt: None,
      messages: [UserMessage("What's the weather in Paris?")],
      tools: [weather_tool],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  ollama.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("encode request with tools")
}

pub fn encode_request_with_tool_calls_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "call_123", name: "get_weather", arguments:)

  let req =
    Request(
      model: "qwen3",
      system_prompt: None,
      messages: [
        UserMessage("What's the weather in Paris?"),
        AssistantMessage("", [tool_call]),
      ],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  ollama.encode_request(req, default_ext())
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

  let req =
    Request(
      model: "qwen3",
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

  ollama.encode_request(req, default_ext())
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

  let assert Ok(#(response, _thinking)) = ollama.decode_response(body)
  assert response.text == ""

  let assert [call] = response.tool_calls
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

  let assert Ok(#(response, _thinking)) = ollama.decode_response(body)

  let assert [call] = response.tool_calls
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
  let req =
    Request(
      model: "deepseek-r1",
      system_prompt: None,
      messages: [UserMessage("Think step by step")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  let ext =
    ollama.Ext(thinking: Some(ollama.ThinkingEnabled), thinking_content: None)

  ollama.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("ollama encode request with thinking enabled")
}

pub fn encode_request_with_thinking_effort_test() {
  let req =
    Request(
      model: "deepseek-r1",
      system_prompt: None,
      messages: [UserMessage("Think step by step")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  let ext =
    ollama.Ext(thinking: Some(ollama.ThinkingHigh), thinking_content: None)

  ollama.encode_request(req, ext)
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

  let req =
    Request(
      model: "qwen3",
      system_prompt: None,
      messages: [UserMessage("Tell me about France")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: Some(schema),
      timeout_ms: 60_000,
    )

  ollama.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("ollama encode request with json schema")
}
