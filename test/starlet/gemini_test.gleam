import birdie
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/response
import gleam/json.{type Json}
import gleam/list
import gleam/option
import gleam/string
import starlet
import starlet/gemini
import starlet/tool

fn make_chat(
  model: String,
) -> starlet.Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, gemini.Ext) {
  gemini.chat(model)
}

pub fn thinking_accessor_test() {
  let turn =
    starlet.Turn(
      text: "answer",
      tool_calls: [],
      ext: gemini.Ext(
        thinking_budget: option.None,
        thinking: option.Some("My reasoning."),
        thought_history: [],
      ),
    )
  assert gemini.thinking(turn) == option.Some("My reasoning.")
}

pub fn list_models_response_success_test() {
  let body =
    json.object([
      #(
        "models",
        json.preprocessed_array([
          json.object([
            #("name", json.string("models/gemini-2.5-flash")),
            #("displayName", json.string("Gemini 2.5 Flash")),
          ]),
        ]),
      ),
    ])
    |> json.to_string
  let resp = response.new(200) |> response.set_body(body)
  let assert Ok(models) = gemini.list_models_response(resp)
  assert models
    == [gemini.Model(id: "gemini-2.5-flash", display_name: "Gemini 2.5 Flash")]
}

pub fn list_models_response_rate_limited_test() {
  let resp =
    response.new(429)
    |> response.set_header("retry-after", "10")
    |> response.set_body("")
  let assert Error(starlet.RateLimited(option.Some(10))) =
    gemini.list_models_response(resp)
}

pub fn credentials_with_base_url_success_test() {
  let assert Ok(creds) =
    gemini.credentials_with_base_url(
      api_key: "test-key",
      base_url: "https://proxy.example.com/gemini",
    )
  let chat =
    gemini.chat("gemini-2.5-flash")
    |> starlet.user("Hello")
  let req = gemini.request(chat, creds)
  assert string.contains(req.path, "/gemini/v1beta/models/")
}

pub fn credentials_with_base_url_invalid_url_test() {
  let assert Error(starlet.InvalidUrl(_)) =
    gemini.credentials_with_base_url(api_key: "test-key", base_url: "://")
}

pub fn with_thinking_fixed_min_boundary_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Ok(chat) =
    gemini.with_thinking(chat, budget: gemini.ThinkingFixed(1))
  assert chat.ext.thinking_budget == option.Some(gemini.ThinkingFixed(1))
}

pub fn with_thinking_fixed_max_boundary_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Ok(chat) =
    gemini.with_thinking(chat, budget: gemini.ThinkingFixed(32_768))
  assert chat.ext.thinking_budget == option.Some(gemini.ThinkingFixed(32_768))
}

pub fn with_thinking_fixed_too_low_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Error(starlet.InvalidArgument(_)) =
    gemini.with_thinking(chat, budget: gemini.ThinkingFixed(0))
}

pub fn with_thinking_fixed_too_high_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  let assert Error(starlet.InvalidArgument(_)) =
    gemini.with_thinking(chat, budget: gemini.ThinkingFixed(32_769))
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
    |> gemini.assistant("Hi there!")
    |> starlet.user("How are you?")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request with conversation")
}

pub fn encode_request_with_thinking_test() {
  let chat = make_chat("gemini-2.5-flash")
  let assert Ok(chat) =
    gemini.with_thinking(chat, budget: gemini.ThinkingFixed(2048))
  let chat = starlet.user(chat, "Think about this")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request with thinking")
}

pub fn encode_request_with_thinking_dynamic_test() {
  let chat = make_chat("gemini-2.5-flash")
  let assert Ok(chat) =
    gemini.with_thinking(chat, budget: gemini.ThinkingDynamic)
  let chat = starlet.user(chat, "Think about this")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request with thinking dynamic")
}

pub fn encode_request_with_thinking_off_test() {
  let chat = make_chat("gemini-2.5-flash")
  let assert Ok(chat) = gemini.with_thinking(chat, budget: gemini.ThinkingOff)
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

  let chat =
    gemini.chat("gemini-2.5-flash")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

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

pub fn encode_request_with_multi_turn_tool_use_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "gemini-0", name: "get_weather", arguments:)
  let tool_result = json.object([#("temp", json.int(22))]) |> json.to_string

  let chat =
    gemini.chat("gemini-2.5-flash")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("What's the weather in Paris?"),
      starlet.AssistantMessage("", [tool_call]),
      starlet.ToolResultMessage("gemini-0", "get_weather", tool_result),
      starlet.AssistantMessage("It's 22°C in Paris!", []),
      starlet.UserMessage("Now check London too"),
    ])

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request with multi turn tool use")
}

pub fn encode_request_with_multiple_tool_results_test() {
  let arguments1 =
    json.object([#("city", json.string("Paris"))]) |> json.to_string
  let assert Ok(arguments1) = json.parse(arguments1, decode.dynamic)
  let arguments2 =
    json.object([#("city", json.string("Tokyo"))]) |> json.to_string
  let assert Ok(arguments2) = json.parse(arguments2, decode.dynamic)
  let tool_call1 =
    tool.Call(id: "gemini-0", name: "get_weather", arguments: arguments1)
  let tool_call2 =
    tool.Call(id: "gemini-1", name: "get_weather", arguments: arguments2)
  let result1 = json.object([#("temp", json.int(22))]) |> json.to_string
  let result2 = json.object([#("temp", json.int(18))]) |> json.to_string

  let chat =
    gemini.chat("gemini-2.5-flash")
    |> starlet.with_tools([])
    |> starlet.user("Weather in Paris and Tokyo?")

  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("Weather in Paris and Tokyo?"),
      starlet.AssistantMessage("", [tool_call1, tool_call2]),
      starlet.ToolResultMessage("gemini-0", "get_weather", result1),
      starlet.ToolResultMessage("gemini-1", "get_weather", result2),
    ])

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request with multiple tool results")
}

pub fn encode_request_round_trips_thought_signatures_test() {
  let chat =
    gemini.chat("gemini-2.5-flash")
    |> starlet.user("Think about this")

  // Simulate a response with thought signature
  let response_body =
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
                      #("text", json.string("let me reason")),
                      #("thought", json.bool(True)),
                      #("thoughtSignature", json.string("sig-abc")),
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

  let http_resp = response.new(200) |> response.set_body(response_body)
  let assert Ok(turn) = gemini.response(chat, http_resp)
  let chat = starlet.append_turn(chat, turn)
  let chat = starlet.user(chat, "Tell me more")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request round trips thought signatures")
}

pub fn encode_request_with_thinking_and_tool_call_test() {
  let arguments = json.object([#("city", json.string("Paris"))])
  let chat =
    gemini.chat("gemini-2.5-flash")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  // Simulate a response where the model thinks (with signature) then calls a tool
  let response_body =
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
                      #("text", json.string("let me check the weather")),
                      #("thought", json.bool(True)),
                      #("thoughtSignature", json.string("sig-abc")),
                    ]),
                    json.object([
                      #(
                        "functionCall",
                        json.object([
                          #("name", json.string("get_weather")),
                          #("args", arguments),
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

  let http_resp = response.new(200) |> response.set_body(response_body)
  let assert Ok(turn) = gemini.response(chat, http_resp)
  let assert [call] = starlet.tool_calls(turn)
  let chat = starlet.append_turn(chat, turn)
  let chat =
    starlet.with_tool_results(chat, [
      tool.success(call, json.object([#("temp", json.int(22))])),
    ])
  let chat = starlet.user(chat, "What about London?")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request with thinking and tool call")
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

  let assert Ok(#(text, _thinking, tool_calls, _sigs)) =
    gemini.decode_response(body)
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

  let assert Ok(#(text, _thinking, _tool_calls, _sigs)) =
    gemini.decode_response(body)
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

  let assert Ok(#(text, _thinking, tool_calls, _sigs)) =
    gemini.decode_response(body)
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

  let assert Ok(#(text, thinking, _tool_calls, _sigs)) =
    gemini.decode_response(body)
  assert text == "The answer is 42"
  assert thinking == option.Some("Let me think...")
}

pub fn decode_response_with_thought_signature_test() {
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
                      #("text", json.string("reasoning here")),
                      #("thought", json.bool(True)),
                      #("thoughtSignature", json.string("opaque-sig-abc123")),
                    ]),
                    json.object([#("text", json.string("The answer"))]),
                  ]),
                ),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(text, thinking, _tool_calls, thought_records)) =
    gemini.decode_response(body)
  assert text == "The answer"
  assert thinking == option.Some("reasoning here")
  assert thought_records
    == [
      gemini.ThoughtRecord(
        text: "reasoning here",
        signature: option.Some("opaque-sig-abc123"),
      ),
    ]
}

pub fn decode_response_without_thought_signature_test() {
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
                      #("text", json.string("thinking")),
                      #("thought", json.bool(True)),
                    ]),
                    json.object([#("text", json.string("result"))]),
                  ]),
                ),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(_text, _thinking, _tool_calls, thought_records)) =
    gemini.decode_response(body)
  assert thought_records
    == [gemini.ThoughtRecord(text: "thinking", signature: option.None)]
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

pub fn decode_response_skips_unknown_part_types_test() {
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
                        "executableCode",
                        json.object([#("code", json.string("print('hi')"))]),
                      ),
                    ]),
                    json.object([#("text", json.string("Hello"))]),
                  ]),
                ),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(text, thinking, tool_calls, thought_records)) =
    gemini.decode_response(body)
  assert text == "Hello"
  assert thinking == option.None
  assert tool_calls == []
  assert thought_records == []
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

  let assert Ok(#(_text, _thinking, tool_calls, _sigs)) =
    gemini.decode_response(body)
  let assert [call1, call2] = tool_calls
  assert call1.name == "get_weather"
  assert call1.id == "gemini-0"
  assert call2.name == "get_time"
  assert call2.id == "gemini-1"
}

// --- Streaming tests ---

fn to_bits(s: String) -> BitArray {
  bit_array.from_string(s)
}

fn sse_event(data: String) -> String {
  "data: " <> data <> "\n\n"
}

fn candidate_event(parts: List(Json)) -> String {
  sse_event(
    json.object([
      #(
        "candidates",
        json.preprocessed_array([
          json.object([
            #(
              "content",
              json.object([
                #("parts", json.preprocessed_array(parts)),
                #("role", json.string("model")),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string,
  )
}

fn candidate_event_with_finish(parts: List(Json), reason: String) -> String {
  sse_event(
    json.object([
      #(
        "candidates",
        json.preprocessed_array([
          json.object([
            #(
              "content",
              json.object([
                #("parts", json.preprocessed_array(parts)),
                #("role", json.string("model")),
              ]),
            ),
            #("finishReason", json.string(reason)),
          ]),
        ]),
      ),
    ])
    |> json.to_string,
  )
}

pub fn stream_request_uses_stream_endpoint_test() {
  let creds = gemini.credentials("test-key")
  let chat =
    gemini.chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  let req = gemini.stream_request(chat, creds)
  assert string.ends_with(req.path, ":streamGenerateContent")
  assert req.query == option.Some("alt=sse")
}

pub fn stream_request_snapshot_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode stream request")
}

pub fn stream_feed_text_delta_test() {
  let state = gemini.stream_init()
  let chunk = candidate_event([json.object([#("text", json.string("Hello"))])])
  let #(_state, events) = gemini.stream_feed(state, to_bits(chunk))
  assert events == [starlet.TextDelta("Hello")]
}

pub fn stream_feed_thinking_delta_test() {
  let state = gemini.stream_init()
  let chunk =
    candidate_event([
      json.object([
        #("thought", json.bool(True)),
        #("text", json.string("reasoning...")),
      ]),
    ])
  let #(_state, events) = gemini.stream_feed(state, to_bits(chunk))
  assert events == [starlet.ThinkingDelta("reasoning...")]
}

pub fn stream_feed_done_on_finish_reason_test() {
  let state = gemini.stream_init()
  let chunk =
    candidate_event_with_finish(
      [json.object([#("text", json.string(" world"))])],
      "STOP",
    )
  let #(_state, events) = gemini.stream_feed(state, to_bits(chunk))
  assert events == [starlet.TextDelta(" world"), starlet.Done]
}

pub fn stream_done_assembles_turn_test() {
  let state = gemini.stream_init()

  let #(state, _) =
    gemini.stream_feed(
      state,
      to_bits(
        candidate_event([
          json.object([#("text", json.string("Hello"))]),
        ]),
      ),
    )
  let #(state, _) =
    gemini.stream_feed(
      state,
      to_bits(candidate_event_with_finish(
        [json.object([#("text", json.string(" world"))])],
        "STOP",
      )),
    )

  let chat = make_chat("gemini-2.5-flash") |> starlet.user("x")
  let turn = gemini.stream_done(chat, state)
  assert turn.text == "Hello world"
  assert turn.tool_calls == []
  assert turn.ext
    == gemini.Ext(
      thinking_budget: option.None,
      thinking: option.None,
      thought_history: [[]],
    )
}

pub fn stream_done_with_thinking_test() {
  let state = gemini.stream_init()

  let #(state, _) =
    gemini.stream_feed(
      state,
      to_bits(
        candidate_event([
          json.object([
            #("thought", json.bool(True)),
            #("text", json.string("let me think")),
          ]),
        ]),
      ),
    )
  let #(state, _) =
    gemini.stream_feed(
      state,
      to_bits(candidate_event_with_finish(
        [json.object([#("text", json.string("answer"))])],
        "STOP",
      )),
    )

  let chat = make_chat("gemini-2.5-flash") |> starlet.user("x")
  let turn = gemini.stream_done(chat, state)
  assert turn.text == "answer"
  assert turn.ext.thinking == option.Some("let me think")
}

pub fn stream_feed_done_on_safety_finish_reason_test() {
  let state = gemini.stream_init()
  let chunk =
    json.object([
      #(
        "candidates",
        json.preprocessed_array([
          json.object([
            #(
              "content",
              json.object([
                #(
                  "parts",
                  json.preprocessed_array([
                    json.object([#("text", json.string(""))]),
                  ]),
                ),
                #("role", json.string("model")),
              ]),
            ),
            #("finishReason", json.string("SAFETY")),
          ]),
        ]),
      ),
    ])
    |> json.to_string
    |> sse_event
  let #(_state, events) = gemini.stream_feed(state, to_bits(chunk))
  assert events == [starlet.Done]
}

pub fn stream_feed_done_on_recitation_finish_reason_test() {
  let state = gemini.stream_init()
  let chunk =
    json.object([
      #(
        "candidates",
        json.preprocessed_array([
          json.object([
            #(
              "content",
              json.object([
                #(
                  "parts",
                  json.preprocessed_array([
                    json.object([#("text", json.string("partial"))]),
                  ]),
                ),
                #("role", json.string("model")),
              ]),
            ),
            #("finishReason", json.string("RECITATION")),
          ]),
        ]),
      ),
    ])
    |> json.to_string
    |> sse_event
  let #(_state, events) = gemini.stream_feed(state, to_bits(chunk))
  assert events == [starlet.TextDelta("partial"), starlet.Done]
}

pub fn stream_feed_function_call_test() {
  let state = gemini.stream_init()
  let chunk =
    candidate_event_with_finish(
      [
        json.object([
          #(
            "functionCall",
            json.object([
              #("name", json.string("get_weather")),
              #("args", json.object([#("city", json.string("Paris"))])),
            ]),
          ),
        ]),
      ],
      "STOP",
    )
  let #(state, events) = gemini.stream_feed(state, to_bits(chunk))
  assert events
    == [
      starlet.ToolCallStart("gemini-0", "get_weather"),
      starlet.Done,
    ]

  let chat = make_chat("gemini-2.5-flash") |> starlet.user("x")
  let turn = gemini.stream_done(chat, state)
  let assert [call] = turn.tool_calls
  assert call.name == "get_weather"
  let assert Ok("Paris") =
    decode.run(call.arguments, decode.at(["city"], decode.string))
}

pub fn stream_done_preserves_thinking_budget_test() {
  let state = gemini.stream_init()
  let #(state, _) =
    gemini.stream_feed(
      state,
      to_bits(candidate_event_with_finish(
        [json.object([#("text", json.string("Hi"))])],
        "STOP",
      )),
    )

  let assert Ok(chat) =
    make_chat("gemini-2.5-flash")
    |> gemini.with_thinking(budget: gemini.ThinkingDynamic)
  let chat = starlet.user(chat, "x")
  let turn = gemini.stream_done(chat, state)
  assert turn.ext.thinking_budget == option.Some(gemini.ThinkingDynamic)
}

pub fn response_preserves_thinking_budget_test() {
  let assert Ok(chat) =
    make_chat("gemini-2.5-flash")
    |> gemini.with_thinking(budget: gemini.ThinkingDynamic)
  let chat = starlet.user(chat, "x")
  let body =
    json.object([
      #(
        "candidates",
        json.preprocessed_array([
          json.object([
            #(
              "content",
              json.object([
                #(
                  "parts",
                  json.preprocessed_array([
                    json.object([#("text", json.string("Hi"))]),
                  ]),
                ),
                #("role", json.string("model")),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string
  let resp = response.new(200) |> response.set_body(body)
  let assert Ok(turn) = gemini.response(chat, resp)
  assert turn.ext.thinking_budget == option.Some(gemini.ThinkingDynamic)
}

pub fn stream_error_from_provider_test() {
  let state = gemini.stream_init()
  let chunk =
    sse_event(
      json.object([
        #(
          "error",
          json.object([
            #("code", json.int(400)),
            #("message", json.string("Invalid request")),
            #("status", json.string("INVALID_ARGUMENT")),
          ]),
        ),
      ])
      |> json.to_string,
    )
  let #(_state, events) = gemini.stream_feed(state, to_bits(chunk))
  let assert [starlet.StreamError(starlet.Provider("gemini", msg, _))] = events
  assert string.contains(msg, "Invalid request")
}

pub fn decode_error_response_test() {
  let body =
    json.object([
      #(
        "error",
        json.object([
          #("code", json.int(400)),
          #("message", json.string("API key not valid")),
          #("status", json.string("INVALID_ARGUMENT")),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok("API key not valid") = gemini.decode_error_response(body)
}

pub fn decode_models_response_test() {
  let body =
    json.object([
      #(
        "models",
        json.preprocessed_array([
          json.object([
            #("name", json.string("models/gemini-2.5-flash")),
            #("displayName", json.string("Gemini 2.5 Flash")),
          ]),
          json.object([
            #("name", json.string("models/gemini-2.5-pro")),
            #("displayName", json.string("Gemini 2.5 Pro")),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(models) = gemini.decode_models(body)
  assert models
    == [
      gemini.Model(id: "gemini-2.5-flash", display_name: "Gemini 2.5 Flash"),
      gemini.Model(id: "gemini-2.5-pro", display_name: "Gemini 2.5 Pro"),
    ]
}

pub fn decode_models_empty_list_test() {
  let body =
    json.object([#("models", json.preprocessed_array([]))])
    |> json.to_string

  let assert Ok(models) = gemini.decode_models(body)
  assert models == []
}

pub fn decode_models_invalid_json_test() {
  let body = "not json"
  let assert Error(_) = gemini.decode_models(body)
}

pub fn response_rate_limited_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")
  let resp =
    response.new(429)
    |> response.set_header("retry-after", "10")
    |> response.set_body("")
  let assert Error(starlet.RateLimited(option.Some(10))) =
    gemini.response(chat, resp)
}

pub fn response_provider_error_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")
  let body =
    json.object([
      #(
        "error",
        json.object([
          #("code", json.int(400)),
          #("message", json.string("API key not valid")),
          #("status", json.string("INVALID_ARGUMENT")),
        ]),
      ),
    ])
    |> json.to_string
  let resp = response.new(400) |> response.set_body(body)
  let assert Error(starlet.Provider("gemini", "API key not valid", _)) =
    gemini.response(chat, resp)
}

pub fn response_http_fallback_test() {
  let chat =
    make_chat("gemini-2.5-flash")
    |> starlet.user("Hello")
  let resp = response.new(500) |> response.set_body("Internal Server Error")
  let assert Error(starlet.Http(500, "Internal Server Error")) =
    gemini.response(chat, resp)
}

pub fn request_builds_correct_http_request_test() {
  let creds = gemini.credentials("test-key")
  let chat =
    gemini.chat("gemini-2.5-flash")
    |> starlet.user("Hello")

  let req = gemini.request(chat, creds)
  assert req.method == http.Post
  assert string.contains(req.path, "/v1beta/models/")
  assert string.contains(req.path, ":generateContent")
  let assert Ok(ct) = list.key_find(req.headers, "content-type")
  assert ct == "application/json"
  let assert Ok(api_key) = list.key_find(req.headers, "x-goog-api-key")
  assert api_key == "test-key"
}

pub fn list_models_request_builds_correct_http_request_test() {
  let creds = gemini.credentials("test-key")
  let req = gemini.list_models_request(creds)
  assert req.method == http.Get
  assert string.contains(req.path, "/v1beta/models")
  let assert Ok(api_key) = list.key_find(req.headers, "x-goog-api-key")
  assert api_key == "test-key"
}

pub fn encode_request_with_json_schema_test() {
  let schema =
    json.object([
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #("name", json.object([#("type", json.string("string"))])),
        ]),
      ),
      #("required", json.array(["name"], json.string)),
    ])

  let chat = gemini.chat("gemini-2.5-flash")
  let chat = starlet.Chat(..chat, json_schema: option.Some(schema))
  let chat = starlet.user(chat, "Give me a name")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini encode request with json schema")
}

pub fn stream_feed_garbled_json_emits_error_test() {
  let state = gemini.stream_init()
  let #(_state, events) =
    gemini.stream_feed(state, to_bits(sse_event("not valid json")))
  let assert [starlet.StreamError(starlet.Decode(_))] = events
}

pub fn assistant_appends_empty_thought_history_test() {
  let chat =
    gemini.chat("gemini-2.5-flash")
    |> starlet.user("What is 2+2?")
    |> gemini.assistant("4")
    |> starlet.user("Think about this")

  // Simulate a response with thought signature
  let response_body =
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
                      #("text", json.string("let me think")),
                      #("thought", json.bool(True)),
                      #("thoughtSignature", json.string("sig-xyz")),
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

  let http_resp = response.new(200) |> response.set_body(response_body)
  let assert Ok(turn) = gemini.response(chat, http_resp)
  let chat = starlet.append_turn(chat, turn)
  let chat = starlet.user(chat, "Elaborate")

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini assistant appends empty thought history")
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
    make_chat("gemini-2.5-flash")
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What's the weather in Paris?")

  let state = gemini.stream_init()

  let chunk =
    candidate_event_with_finish(
      [
        json.object([
          #(
            "functionCall",
            json.object([
              #("name", json.string("get_weather")),
              #("args", json.object([#("city", json.string("Paris"))])),
            ]),
          ),
        ]),
      ],
      "STOP",
    )
  let #(state, _) = gemini.stream_feed(state, to_bits(chunk))

  let turn = gemini.stream_done(chat, state)
  let assert [call] = turn.tool_calls
  assert call.id == "gemini-0"
  assert call.name == "get_weather"

  let chat = starlet.append_turn(chat, turn)
  let result =
    tool.success(call, output: json.object([#("temp", json.int(22))]))
  let chat = starlet.with_tool_results(chat, results: [result])

  gemini.encode_request(chat)
  |> json.to_string
  |> birdie.snap("gemini stream tool call round trip")
}
