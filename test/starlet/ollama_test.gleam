import birdie
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import starlet
import starlet/ollama
import starlet/tool

fn make_chat(
  model: String,
) -> starlet.Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, ollama.Ext) {
  ollama.chat(model)
}

pub fn encode_simple_request_test() {
  let chat =
    make_chat("qwen3")
    |> starlet.user("Hello")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode simple request")
}

pub fn encode_request_with_system_prompt_test() {
  let chat =
    make_chat("qwen3")
    |> starlet.system("Be helpful")
    |> starlet.user("Hello")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with system prompt")
}

pub fn encode_request_with_options_test() {
  let chat =
    make_chat("qwen3")
    |> starlet.temperature(0.7)
    |> starlet.max_tokens(1000)
    |> starlet.user("Hello")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with options")
}

pub fn encode_request_with_conversation_test() {
  let chat =
    make_chat("qwen3")
    |> starlet.user("Hello")
    |> ollama.assistant("Hi!")
    |> starlet.user("How are you?")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with conversation")
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
  |> birdie.snap("ollama encode request with tools")
}

pub fn encode_request_with_tool_calls_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "call_123", name: "get_weather", arguments:)

  let chat =
    ollama.chat("qwen3")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("What's the weather in Paris?"),
      starlet.AssistantMessage("", [tool_call]),
    ])

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with tool calls")
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

  let chat =
    ollama.chat("qwen3")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("What's the weather in Paris?"),
      starlet.AssistantMessage("", [tool_call]),
      starlet.ToolResultMessage("call_123", "get_weather", tool_result),
    ])

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with tool result")
}

pub fn encode_request_with_multi_turn_tool_use_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "ollama-0", name: "get_weather", arguments:)
  let tool_result = json.object([#("temp", json.int(22))]) |> json.to_string

  let chat =
    ollama.chat("qwen3")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("What's the weather in Paris?"),
      starlet.AssistantMessage("", [tool_call]),
      starlet.ToolResultMessage("ollama-0", "get_weather", tool_result),
      starlet.AssistantMessage("It's 22°C in Paris!", []),
      starlet.UserMessage("Now check London too"),
    ])

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with multi turn tool use")
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
  assert call.id == "ollama-0"
  assert call.name == "get_weather"
}

pub fn decode_response_with_duplicate_tool_calls_test() {
  let args1 = json.object([#("city", json.string("Paris"))]) |> json.to_string
  let args2 = json.object([#("city", json.string("London"))]) |> json.to_string
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
                    #("arguments", json.string(args1)),
                  ]),
                ),
              ]),
              json.object([
                #(
                  "function",
                  json.object([
                    #("name", json.string("get_weather")),
                    #("arguments", json.string(args2)),
                  ]),
                ),
              ]),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(_, _, tool_calls)) = ollama.decode_response(body)

  let assert [call1, call2] = tool_calls
  assert call1.id == "ollama-0"
  assert call1.name == "get_weather"
  assert call2.id == "ollama-1"
  assert call2.name == "get_weather"
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
    |> ollama.with_thinking(mode: ollama.ThinkingOn)
    |> starlet.user("Think step by step")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with thinking enabled")
}

pub fn encode_request_with_thinking_effort_test() {
  let chat =
    make_chat("deepseek-r1")
    |> ollama.with_thinking(mode: ollama.ThinkingHigh)
    |> starlet.user("Think step by step")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with thinking high")
}

pub fn encode_request_with_thinking_off_test() {
  let chat =
    make_chat("deepseek-r1")
    |> ollama.with_thinking(mode: ollama.ThinkingOff)
    |> starlet.user("No thinking please")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with thinking off")
}

pub fn encode_request_with_thinking_low_test() {
  let chat =
    make_chat("deepseek-r1")
    |> ollama.with_thinking(mode: ollama.ThinkingLow)
    |> starlet.user("Think a little")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with thinking low")
}

pub fn encode_request_with_thinking_medium_test() {
  let chat =
    make_chat("deepseek-r1")
    |> ollama.with_thinking(mode: ollama.ThinkingMedium)
    |> starlet.user("Think some more")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with thinking medium")
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
  let chat = ollama.chat("qwen3")
  let chat = starlet.Chat(..chat, json_schema: option.Some(schema))
  let chat = starlet.user(chat, "Tell me about France")

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode request with json schema")
}

// --- Streaming tests ---

fn to_bits(s: String) -> BitArray {
  bit_array.from_string(s)
}

pub fn stream_request_snapshot_test() {
  let chat =
    make_chat("qwen3:0.6b")
    |> starlet.user("Hello")

  ollama.encode_stream_request(chat)
  |> json.to_string
  |> birdie.snap("ollama encode stream request")
}

pub fn stream_feed_text_delta_test() {
  let state = ollama.stream_init()
  let chunk =
    json.object([
      #("message", json.object([#("content", json.string("Hello"))])),
      #("done", json.bool(False)),
    ])
    |> json.to_string
    <> "\n"
  let #(_state, events) = ollama.stream_feed(state, to_bits(chunk))
  assert events == [starlet.TextDelta("Hello")]
}

pub fn stream_feed_done_test() {
  let state = ollama.stream_init()
  let chunk =
    json.object([
      #("message", json.object([#("content", json.string(""))])),
      #("done", json.bool(True)),
      #("total_duration", json.int(123)),
    ])
    |> json.to_string
    <> "\n"
  let #(_state, events) = ollama.stream_feed(state, to_bits(chunk))
  assert events == [starlet.Done]
}

pub fn stream_feed_multiple_chunks_test() {
  let state = ollama.stream_init()
  let chunk1 =
    json.object([
      #("message", json.object([#("content", json.string("Hel"))])),
      #("done", json.bool(False)),
    ])
    |> json.to_string
    <> "\n"
  let #(state, events1) = ollama.stream_feed(state, to_bits(chunk1))
  assert events1 == [starlet.TextDelta("Hel")]
  let chunk2 =
    json.object([
      #("message", json.object([#("content", json.string("lo"))])),
      #("done", json.bool(False)),
    ])
    |> json.to_string
    <> "\n"
  let #(_state, events2) = ollama.stream_feed(state, to_bits(chunk2))
  assert events2 == [starlet.TextDelta("lo")]
}

pub fn stream_done_assembles_turn_test() {
  let state = ollama.stream_init()
  let chunk1 =
    json.object([
      #("message", json.object([#("content", json.string("Hello"))])),
      #("done", json.bool(False)),
    ])
    |> json.to_string
    <> "\n"
  let #(state, _) = ollama.stream_feed(state, to_bits(chunk1))
  let chunk2 =
    json.object([
      #("message", json.object([#("content", json.string(" world"))])),
      #("done", json.bool(False)),
    ])
    |> json.to_string
    <> "\n"
  let #(state, _) = ollama.stream_feed(state, to_bits(chunk2))
  let chunk3 =
    json.object([
      #("message", json.object([#("content", json.string(""))])),
      #("done", json.bool(True)),
    ])
    |> json.to_string
    <> "\n"
  let #(state, _) = ollama.stream_feed(state, to_bits(chunk3))
  let chat = make_chat("qwen3") |> starlet.user("x")
  let turn = ollama.stream_done(chat, state)
  assert turn.text == "Hello world"
  assert turn.tool_calls == []
  assert turn.ext
    == ollama.Ext(thinking_mode: option.None, thinking_content: option.None)
}

pub fn stream_feed_thinking_test() {
  let state = ollama.stream_init()
  let chunk =
    json.object([
      #(
        "message",
        json.object([
          #("content", json.string("")),
          #("thinking", json.string("Let me think...")),
        ]),
      ),
      #("done", json.bool(False)),
    ])
    |> json.to_string
    <> "\n"
  let #(_state, events) = ollama.stream_feed(state, to_bits(chunk))
  assert events == [starlet.ThinkingDelta("Let me think...")]
}

pub fn stream_done_with_thinking_test() {
  let state = ollama.stream_init()
  let chunk1 =
    json.object([
      #(
        "message",
        json.object([
          #("content", json.string("")),
          #("thinking", json.string("thinking...")),
        ]),
      ),
      #("done", json.bool(False)),
    ])
    |> json.to_string
    <> "\n"
  let #(state, _) = ollama.stream_feed(state, to_bits(chunk1))
  let chunk2 =
    json.object([
      #("message", json.object([#("content", json.string("answer"))])),
      #("done", json.bool(False)),
    ])
    |> json.to_string
    <> "\n"
  let #(state, _) = ollama.stream_feed(state, to_bits(chunk2))
  let chunk3 =
    json.object([
      #("message", json.object([#("content", json.string(""))])),
      #("done", json.bool(True)),
    ])
    |> json.to_string
    <> "\n"
  let #(state, _) = ollama.stream_feed(state, to_bits(chunk3))
  let chat = make_chat("qwen3") |> starlet.user("x")
  let turn = ollama.stream_done(chat, state)
  assert turn.text == "answer"
  assert turn.ext.thinking_content == option.Some("thinking...")
}

pub fn stream_feed_done_with_content_test() {
  let state = ollama.stream_init()
  let chunk =
    json.object([
      #("message", json.object([#("content", json.string("final"))])),
      #("done", json.bool(True)),
      #("total_duration", json.int(123)),
    ])
    |> json.to_string
    <> "\n"
  let #(state, events) = ollama.stream_feed(state, to_bits(chunk))
  assert events == [starlet.TextDelta("final"), starlet.Done]

  let chat = make_chat("qwen3") |> starlet.user("x")
  let turn = ollama.stream_done(chat, state)
  assert turn.text == "final"
}

pub fn stream_feed_thinking_then_content_ordering_test() {
  let state = ollama.stream_init()
  let chunk =
    json.object([
      #(
        "message",
        json.object([
          #("content", json.string("answer")),
          #("thinking", json.string("reasoning")),
        ]),
      ),
      #("done", json.bool(False)),
    ])
    |> json.to_string
    <> "\n"
  let #(_state, events) = ollama.stream_feed(state, to_bits(chunk))
  assert events
    == [
      starlet.ThinkingDelta("reasoning"),
      starlet.TextDelta("answer"),
    ]
}

pub fn stream_feed_tool_calls_test() {
  let state = ollama.stream_init()
  let args = json.object([#("city", json.string("Paris"))]) |> json.to_string
  let chunk =
    json.object([
      #(
        "message",
        json.object([
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
                #("id", json.string("call_abc")),
              ]),
            ]),
          ),
        ]),
      ),
      #("done", json.bool(False)),
    ])
    |> json.to_string
  let chunk = chunk <> "\n"
  let #(state, events) = ollama.stream_feed(state, to_bits(chunk))
  assert events == [starlet.ToolCallStart("call_abc", "get_weather")]

  let done_chunk =
    json.object([
      #("message", json.object([#("content", json.string(""))])),
      #("done", json.bool(True)),
    ])
    |> json.to_string
    <> "\n"
  let #(state, _) = ollama.stream_feed(state, to_bits(done_chunk))
  let chat = make_chat("qwen3") |> starlet.user("x")
  let turn = ollama.stream_done(chat, state)
  let assert [call] = turn.tool_calls
  assert call.id == "call_abc"
  assert call.name == "get_weather"
  let assert Ok("Paris") =
    decode.run(call.arguments, decode.at(["city"], decode.string))
}

pub fn stream_done_preserves_thinking_mode_test() {
  let state = ollama.stream_init()
  let chunk =
    json.object([
      #("message", json.object([#("content", json.string("Hi"))])),
      #("done", json.bool(True)),
    ])
    |> json.to_string
    <> "\n"
  let #(state, _) = ollama.stream_feed(state, to_bits(chunk))

  let chat =
    make_chat("qwen3")
    |> ollama.with_thinking(mode: ollama.ThinkingOn)
    |> starlet.user("x")
  let turn = ollama.stream_done(chat, state)
  assert turn.ext.thinking_mode == option.Some(ollama.ThinkingOn)
}

pub fn response_preserves_thinking_mode_test() {
  let chat =
    make_chat("qwen3")
    |> ollama.with_thinking(mode: ollama.ThinkingOn)
    |> starlet.user("x")
  let body =
    json.object([
      #("message", json.object([#("content", json.string("Hi"))])),
    ])
    |> json.to_string
  let resp = response.new(200) |> response.set_body(body)
  let assert Ok(turn) = ollama.response(chat, resp)
  assert turn.ext.thinking_mode == option.Some(ollama.ThinkingOn)
}

pub fn stream_error_from_provider_test() {
  let state = ollama.stream_init()
  let chunk =
    json.object([#("error", json.string("model 'unknown' not found"))])
    |> json.to_string
    <> "\n"
  let #(_state, events) = ollama.stream_feed(state, to_bits(chunk))
  let assert [starlet.StreamError(starlet.Provider("ollama", msg, _))] = events
  assert msg == "model 'unknown' not found"
}

pub fn response_rate_limited_test() {
  let chat =
    make_chat("qwen3")
    |> starlet.user("Hello")
  let resp =
    response.new(429)
    |> response.set_header("retry-after", "5")
    |> response.set_body("")
  let assert Error(starlet.RateLimited(option.Some(5))) =
    ollama.response(chat, resp)
}

pub fn response_http_fallback_test() {
  let chat =
    make_chat("qwen3")
    |> starlet.user("Hello")
  let resp = response.new(500) |> response.set_body("Internal Server Error")
  let assert Error(starlet.Http(500, "Internal Server Error")) =
    ollama.response(chat, resp)
}

pub fn response_provider_error_test() {
  let chat =
    make_chat("qwen3")
    |> starlet.user("Hello")
  let body =
    json.object([#("error", json.string("model 'unknown' not found"))])
    |> json.to_string
  let resp = response.new(404) |> response.set_body(body)
  let assert Error(starlet.Provider("ollama", msg, _)) =
    ollama.response(chat, resp)
  assert msg == "model 'unknown' not found"
}

pub fn decode_response_with_thinking_test() {
  let body =
    json.object([
      #(
        "message",
        json.object([
          #("role", json.string("assistant")),
          #("content", json.string("The answer is 42")),
          #("thinking", json.string("Let me reason about this...")),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(text, thinking, tool_calls)) = ollama.decode_response(body)
  assert text == "The answer is 42"
  assert thinking == option.Some("Let me reason about this...")
  assert tool_calls == []
}

pub fn thinking_accessor_test() {
  let turn =
    starlet.Turn(
      text: "answer",
      tool_calls: [],
      ext: ollama.Ext(
        thinking_mode: option.None,
        thinking_content: option.Some("Let me reason..."),
      ),
    )
  assert ollama.thinking(turn) == option.Some("Let me reason...")
}

pub fn list_models_response_success_test() {
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
        ]),
      ),
    ])
    |> json.to_string
  let resp = response.new(200) |> response.set_body(body)
  let assert Ok(models) = ollama.list_models_response(resp)
  assert models == [ollama.Model(name: "qwen3:0.6b", size: "751.63M")]
}

pub fn list_models_response_rate_limited_test() {
  let resp =
    response.new(429)
    |> response.set_header("retry-after", "5")
    |> response.set_body("")
  let assert Error(starlet.RateLimited(option.Some(5))) =
    ollama.list_models_response(resp)
}

pub fn request_builds_correct_http_request_test() {
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")
  let chat =
    ollama.chat("qwen3")
    |> starlet.user("Hello")

  let req = ollama.request(chat, creds)
  assert req.method == http.Post
  assert string.contains(req.path, "/api/chat")
  let assert Ok(ct) = list.key_find(req.headers, "content-type")
  assert ct == "application/json"
}

pub fn list_models_request_builds_correct_http_request_test() {
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")
  let req = ollama.list_models_request(creds)
  assert req.method == http.Get
  assert string.contains(req.path, "/api/tags")
}

pub fn list_models_request_with_api_key_test() {
  let assert Ok(creds) =
    ollama.credentials_with_api_key(
      base_url: "http://localhost:11434",
      api_key: "test-key",
    )
  let req = ollama.list_models_request(creds)
  let assert Ok(auth) = list.key_find(req.headers, "authorization")
  assert auth == "Bearer test-key"
}

pub fn request_with_api_key_sets_authorization_header_test() {
  let assert Ok(creds) =
    ollama.credentials_with_api_key(
      base_url: "http://localhost:11434",
      api_key: "test-key-123",
    )
  let chat =
    ollama.chat("qwen3")
    |> starlet.user("Hello")

  let req = ollama.request(chat, creds)
  let assert Ok(auth) = list.key_find(req.headers, "authorization")
  assert auth == "Bearer test-key-123"
}

pub fn request_without_api_key_has_no_authorization_header_test() {
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")
  let chat =
    ollama.chat("qwen3")
    |> starlet.user("Hello")

  let req = ollama.request(chat, creds)
  assert list.key_find(req.headers, "authorization") == Error(Nil)
}

pub fn stream_feed_garbled_json_emits_error_test() {
  let state = ollama.stream_init()
  let #(_state, events) = ollama.stream_feed(state, to_bits("not valid json\n"))
  let assert [starlet.StreamError(starlet.Decode(_))] = events
}

pub fn stream_tool_call_round_trip_test() {
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
    make_chat("qwen3")
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What's the weather in Paris?")

  let state = ollama.stream_init()

  let args = json.object([#("city", json.string("Paris"))]) |> json.to_string
  let chunk =
    json.object([
      #(
        "message",
        json.object([
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
                #("id", json.string("call_abc")),
              ]),
            ]),
          ),
        ]),
      ),
      #("done", json.bool(False)),
    ])
    |> json.to_string
    <> "\n"
  let #(state, _) = ollama.stream_feed(state, to_bits(chunk))

  let done_chunk =
    json.object([
      #("message", json.object([#("content", json.string(""))])),
      #("done", json.bool(True)),
    ])
    |> json.to_string
    <> "\n"
  let #(state, _) = ollama.stream_feed(state, to_bits(done_chunk))

  let turn = ollama.stream_done(chat, state)
  let assert [call] = turn.tool_calls
  assert call.id == "call_abc"
  assert call.name == "get_weather"

  let chat = starlet.append_turn(chat, turn)
  let result =
    tool.success(call, output: json.object([#("temp", json.int(22))]))
  let chat = starlet.with_tool_results(chat, results: [result])

  ollama.encode_request(chat)
  |> json.to_string
  |> birdie.snap("ollama stream tool call round trip")
}

pub fn assistant_with_tool_calls_appends_message_test() {
  let arguments_json =
    json.object([#("city", json.string("Paris"))]) |> json.to_string
  let assert Ok(arguments) = json.parse(arguments_json, decode.dynamic)
  let call = tool.Call(id: "call_1", name: "get_weather", arguments:)
  let result =
    tool.success(call, output: json.object([#("temp", json.int(22))]))

  let chat =
    make_chat("qwen3")
    |> starlet.with_tools([])
    |> starlet.with_ext(ollama.Ext(
      thinking_mode: option.None,
      thinking_content: option.Some("stale reasoning"),
    ))
    |> starlet.user("Weather?")
    |> ollama.assistant_with_tool_calls("Looking up...", [call])
    |> starlet.with_tool_results(results: [result])
    |> starlet.user("Thanks")

  let assert [
    starlet.UserMessage("Weather?"),
    starlet.AssistantMessage("Looking up...", [returned]),
    starlet.ToolResultMessage(call_id: "call_1", ..),
    starlet.UserMessage("Thanks"),
  ] = chat.messages
  assert returned.id == "call_1"
  assert returned.name == "get_weather"
  assert chat.ext.thinking_content == option.None
}

pub fn from_messages_replaces_history_and_lands_in_ready_test() {
  let messages = [
    starlet.UserMessage("Hi"),
    starlet.AssistantMessage("Hello", []),
    starlet.UserMessage("How are you?"),
  ]
  let assert Ok(chat) =
    make_chat("qwen3")
    |> starlet.with_ext(ollama.Ext(
      thinking_mode: option.None,
      thinking_content: option.Some("stale reasoning"),
    ))
    |> ollama.from_messages(messages)
  let turn = starlet.Turn(text: "Fine.", tool_calls: [], ext: chat.ext)
  let chat = starlet.append_turn(chat, turn)

  assert chat.messages
    == [
      starlet.UserMessage("Hi"),
      starlet.AssistantMessage("Hello", []),
      starlet.UserMessage("How are you?"),
      starlet.AssistantMessage("Fine.", []),
    ]
  assert chat.ext.thinking_content == option.None
}

pub fn from_messages_rejects_empty_test() {
  let chat = make_chat("qwen3")
  assert ollama.from_messages(chat, [])
    == Error(starlet.InvalidArgument(
      "from_messages requires at least one message",
    ))
}
