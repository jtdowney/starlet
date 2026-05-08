import birdie
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import jscheam/schema
import starlet
import starlet/openai
import starlet/tool

fn make_chat(
  model: String,
) -> starlet.Chat(starlet.ToolsOff, starlet.FreeText, starlet.Empty, openai.Ext) {
  openai.chat(model)
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

pub fn encode_request_with_conversation_test() {
  let chat =
    make_chat("gpt-5-nano")
    |> starlet.user("Hello")
    |> openai.assistant("Hi there!")
    |> starlet.user("How are you?")

  openai.encode_request(chat)
  |> json.to_string
  |> birdie.snap("openai encode request with conversation")
}

pub fn encode_request_with_previous_response_id_test() {
  let chat =
    openai.chat("gpt-5-nano")
    |> openai.continue_from("resp_abc123")
    |> starlet.user("Follow up")

  openai.encode_request(chat)
  |> json.to_string
  |> birdie.snap("openai encode request with previous response id")
}

pub fn encode_request_multi_turn_with_response_id_test() {
  let chat =
    make_chat("gpt-5-nano")
    |> starlet.system("Be helpful")
    |> starlet.user("Hello")

  let turn =
    starlet.Turn(
      text: "Hi there!",
      tool_calls: [],
      ext: openai.Ext(
        response_id: option.Some("resp_abc123"),
        reasoning_effort: option.None,
        reasoning_summary: option.None,
      ),
    )

  let chat =
    chat
    |> starlet.append_turn(turn)
    |> starlet.user("Follow up question")

  openai.encode_request(chat)
  |> json.to_string
  |> birdie.snap("openai encode request multi turn with response id")
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

  let chat =
    openai.chat("gpt-5-nano")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

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

pub fn encode_request_with_multi_turn_tool_use_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "call_123", name: "get_weather", arguments:)
  let tool_result = json.object([#("temp", json.int(22))]) |> json.to_string

  let chat =
    openai.chat("gpt-5-nano")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("What's the weather in Paris?"),
      starlet.AssistantMessage("", [tool_call]),
      starlet.ToolResultMessage("call_123", "get_weather", tool_result),
      starlet.AssistantMessage("It's 22°C in Paris!", []),
      starlet.UserMessage("Now check London too"),
    ])

  openai.encode_request(chat)
  |> json.to_string
  |> birdie.snap("openai encode request with multi turn tool use")
}

pub fn encode_request_with_text_and_tool_calls_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "call_123", name: "get_weather", arguments:)

  let chat =
    openai.chat("gpt-5-nano")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("What's the weather in Paris?"),
      starlet.AssistantMessage("I'll check the weather for you.", [tool_call]),
      starlet.ToolResultMessage("call_123", "get_weather", "{\"temp\":22}"),
      starlet.UserMessage("Thanks!"),
    ])

  openai.encode_request(chat)
  |> json.to_string
  |> birdie.snap("openai encode request with text and tool calls")
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
  let chat =
    openai.chat("gpt-5-nano")
    |> openai.with_reasoning(effort: openai.ReasoningHigh)
    |> starlet.user("Think hard about this")

  openai.encode_request(chat)
  |> json.to_string
  |> birdie.snap("openai encode request with reasoning effort")
}

// --- Streaming tests ---

fn to_bits(s: String) -> BitArray {
  bit_array.from_string(s)
}

fn sse_event(data: String) -> String {
  "data: " <> data <> "\n\n"
}

pub fn stream_request_snapshot_test() {
  let chat =
    make_chat("gpt-4o-mini")
    |> starlet.user("Hello")

  openai.encode_stream_request(chat)
  |> json.to_string
  |> birdie.snap("openai encode stream request")
}

pub fn stream_feed_text_delta_test() {
  let state = openai.stream_init()
  let chunk = text_delta_event(0, 0, "Hello")
  let #(_state, events) = openai.stream_feed(state, to_bits(chunk))
  assert events == [starlet.TextDelta("Hello")]
}

pub fn stream_feed_response_created_captures_id_test() {
  let state = openai.stream_init()
  let chunk =
    json.object([
      #("type", json.string("response.created")),
      #(
        "response",
        json.object([
          #("id", json.string("resp_abc123")),
          #("status", json.string("in_progress")),
        ]),
      ),
    ])
    |> json.to_string
    |> sse_event
  let #(state, _events) = openai.stream_feed(state, to_bits(chunk))

  let chat = make_chat("gpt-5-nano") |> starlet.user("x")
  let turn = openai.stream_done(chat, state)
  assert turn.ext.response_id == option.Some("resp_abc123")
}

pub fn stream_feed_function_call_test() {
  let state = openai.stream_init()

  let #(state, events1) =
    openai.stream_feed(
      state,
      to_bits(output_item_added_event(0, "call_123", "get_weather")),
    )
  assert events1 == [starlet.ToolCallStart("call_123", "get_weather")]

  let #(state, events2) =
    openai.stream_feed(
      state,
      to_bits(function_call_delta_event(0, "{\"city\":")),
    )
  assert events2 == [starlet.ToolCallDelta("call_123", "{\"city\":")]

  let #(state, events3) =
    openai.stream_feed(
      state,
      to_bits(function_call_delta_event(0, "\"Paris\"}")),
    )
  assert events3 == [starlet.ToolCallDelta("call_123", "\"Paris\"}")]

  let args = json.object([#("city", json.string("Paris"))]) |> json.to_string
  let #(state, _) =
    openai.stream_feed(
      state,
      to_bits(output_item_done_event(0, "call_123", "get_weather", args)),
    )

  let chat = make_chat("gpt-5-nano") |> starlet.user("x")
  let turn = openai.stream_done(chat, state)
  let assert [call] = turn.tool_calls
  assert call.id == "call_123"
  assert call.name == "get_weather"
  let assert Ok("Paris") =
    decode.run(call.arguments, decode.at(["city"], decode.string))
}

pub fn stream_feed_function_call_missing_args_uses_buffer_test() {
  let state = openai.stream_init()

  let #(state, _) =
    openai.stream_feed(
      state,
      to_bits(output_item_added_event(0, "call_456", "get_weather")),
    )

  let args = json.object([#("city", json.string("Berlin"))]) |> json.to_string
  let #(state, _) =
    openai.stream_feed(state, to_bits(function_call_delta_event(0, args)))

  let #(state, _) =
    openai.stream_feed(
      state,
      to_bits(output_item_done_without_args_event(0, "call_456", "get_weather")),
    )

  let chat = make_chat("gpt-5-nano") |> starlet.user("x")
  let turn = openai.stream_done(chat, state)
  let assert [call] = turn.tool_calls
  assert call.id == "call_456"
  assert call.name == "get_weather"
  let assert Ok("Berlin") =
    decode.run(call.arguments, decode.at(["city"], decode.string))
}

pub fn stream_feed_completed_test() {
  let state = openai.stream_init()
  let chunk = response_completed_event("resp_123")
  let #(_state, events) = openai.stream_feed(state, to_bits(chunk))
  assert events == [starlet.Done]
}

pub fn stream_feed_done_sentinel_ignored_test() {
  let state = openai.stream_init()
  let chunk = "data: [DONE]\n\n"
  let #(_state, events) = openai.stream_feed(state, to_bits(chunk))
  assert events == []
}

pub fn stream_done_assembles_turn_test() {
  let state = openai.stream_init()

  let #(state, _) =
    openai.stream_feed(state, to_bits(response_created_event("resp_abc")))
  let #(state, _) =
    openai.stream_feed(state, to_bits(text_delta_event(0, 0, "Hello")))
  let #(state, _) =
    openai.stream_feed(state, to_bits(text_delta_event(0, 0, " world")))

  let chat = make_chat("gpt-5-nano") |> starlet.user("x")
  let turn = openai.stream_done(chat, state)
  assert turn.text == "Hello world"
  assert turn.tool_calls == []
  assert turn.ext.response_id == option.Some("resp_abc")
}

pub fn stream_feed_reasoning_summary_delta_test() {
  let state = openai.stream_init()
  let chunk =
    sse_event(
      json.object([
        #("type", json.string("response.reasoning_summary_text.delta")),
        #("delta", json.string("Let me think")),
      ])
      |> json.to_string,
    )
  let #(state, events) = openai.stream_feed(state, to_bits(chunk))
  assert events == [starlet.ThinkingDelta("Let me think")]
  assert state.reasoning_summary == option.Some("Let me think")
}

pub fn stream_feed_reasoning_summary_done_test() {
  let state = openai.stream_init()

  let #(state, _) =
    openai.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("response.reasoning_summary_text.delta")),
          #("delta", json.string("partial")),
        ])
        |> json.to_string,
      )),
    )

  let #(state, events) =
    openai.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("response.reasoning_summary_text.done")),
          #("text", json.string("full reasoning summary")),
        ])
        |> json.to_string,
      )),
    )
  assert events == []
  assert state.reasoning_summary == option.Some("full reasoning summary")
}

pub fn stream_done_with_reasoning_summary_test() {
  let state = openai.stream_init()

  let #(state, _) =
    openai.stream_feed(state, to_bits(response_created_event("resp_reason")))
  let #(state, _) =
    openai.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("response.reasoning_summary_text.delta")),
          #("delta", json.string("I reasoned carefully.")),
        ])
        |> json.to_string,
      )),
    )
  let #(state, _) =
    openai.stream_feed(state, to_bits(text_delta_event(0, 0, "The answer")))

  let chat = make_chat("gpt-5-nano") |> starlet.user("x")
  let turn = openai.stream_done(chat, state)
  assert turn.text == "The answer"
  assert turn.ext.reasoning_summary == option.Some("I reasoned carefully.")
  assert turn.ext.response_id == option.Some("resp_reason")
}

fn text_delta_event(
  output_index: Int,
  content_index: Int,
  delta: String,
) -> String {
  json.object([
    #("type", json.string("response.output_text.delta")),
    #("output_index", json.int(output_index)),
    #("content_index", json.int(content_index)),
    #("delta", json.string(delta)),
  ])
  |> json.to_string
  |> sse_event
}

fn response_created_event(id: String) -> String {
  json.object([
    #("type", json.string("response.created")),
    #("response", json.object([#("id", json.string(id))])),
  ])
  |> json.to_string
  |> sse_event
}

fn response_completed_event(id: String) -> String {
  json.object([
    #("type", json.string("response.completed")),
    #(
      "response",
      json.object([
        #("id", json.string(id)),
        #("status", json.string("completed")),
      ]),
    ),
  ])
  |> json.to_string
  |> sse_event
}

fn output_item_done_without_args_event(
  output_index: Int,
  call_id: String,
  name: String,
) -> String {
  json.object([
    #("type", json.string("response.output_item.done")),
    #("output_index", json.int(output_index)),
    #(
      "item",
      json.object([
        #("type", json.string("function_call")),
        #("call_id", json.string(call_id)),
        #("name", json.string(name)),
      ]),
    ),
  ])
  |> json.to_string
  |> sse_event
}

fn output_item_added_event(
  output_index: Int,
  call_id: String,
  name: String,
) -> String {
  json.object([
    #("type", json.string("response.output_item.added")),
    #("output_index", json.int(output_index)),
    #(
      "item",
      json.object([
        #("type", json.string("function_call")),
        #("call_id", json.string(call_id)),
        #("name", json.string(name)),
      ]),
    ),
  ])
  |> json.to_string
  |> sse_event
}

fn function_call_delta_event(output_index: Int, delta: String) -> String {
  json.object([
    #("type", json.string("response.function_call_arguments.delta")),
    #("output_index", json.int(output_index)),
    #("delta", json.string(delta)),
  ])
  |> json.to_string
  |> sse_event
}

fn output_item_done_event(
  output_index: Int,
  call_id: String,
  name: String,
  arguments: String,
) -> String {
  json.object([
    #("type", json.string("response.output_item.done")),
    #("output_index", json.int(output_index)),
    #(
      "item",
      json.object([
        #("type", json.string("function_call")),
        #("call_id", json.string(call_id)),
        #("name", json.string(name)),
        #("arguments", json.string(arguments)),
      ]),
    ),
  ])
  |> json.to_string
  |> sse_event
}

pub fn stream_feed_parallel_tool_calls_test() {
  let state = openai.stream_init()

  let #(state, events1) =
    openai.stream_feed(
      state,
      to_bits(output_item_added_event(0, "call_a", "get_weather")),
    )
  assert events1 == [starlet.ToolCallStart("call_a", "get_weather")]

  let #(state, events2) =
    openai.stream_feed(
      state,
      to_bits(output_item_added_event(1, "call_b", "get_time")),
    )
  assert events2 == [starlet.ToolCallStart("call_b", "get_time")]

  let #(state, events3) =
    openai.stream_feed(
      state,
      to_bits(function_call_delta_event(0, "{\"city\":")),
    )
  assert events3 == [starlet.ToolCallDelta("call_a", "{\"city\":")]

  let #(state, events4) =
    openai.stream_feed(state, to_bits(function_call_delta_event(1, "{\"tz\":")))
  assert events4 == [starlet.ToolCallDelta("call_b", "{\"tz\":")]

  let #(state, _) =
    openai.stream_feed(
      state,
      to_bits(function_call_delta_event(0, "\"Paris\"}")),
    )
  let #(state, _) =
    openai.stream_feed(state, to_bits(function_call_delta_event(1, "\"UTC\"}")))

  let weather_args =
    json.object([#("city", json.string("Paris"))]) |> json.to_string
  let time_args = json.object([#("tz", json.string("UTC"))]) |> json.to_string

  let #(state, _) =
    openai.stream_feed(
      state,
      to_bits(output_item_done_event(0, "call_a", "get_weather", weather_args)),
    )
  let #(state, _) =
    openai.stream_feed(
      state,
      to_bits(output_item_done_event(1, "call_b", "get_time", time_args)),
    )

  let chat = make_chat("gpt-5-nano") |> starlet.user("x")
  let turn = openai.stream_done(chat, state)
  let assert [call_a, call_b] = turn.tool_calls
  assert call_a.id == "call_a"
  assert call_a.name == "get_weather"
  let assert Ok("Paris") =
    decode.run(call_a.arguments, decode.at(["city"], decode.string))
  assert call_b.id == "call_b"
  assert call_b.name == "get_time"
  let assert Ok("UTC") =
    decode.run(call_b.arguments, decode.at(["tz"], decode.string))
}

pub fn stream_done_preserves_reasoning_effort_test() {
  let state = openai.stream_init()
  let #(state, _) =
    openai.stream_feed(state, to_bits(response_created_event("resp_abc")))
  let #(state, _) =
    openai.stream_feed(state, to_bits(text_delta_event(0, 0, "Hi")))

  let chat =
    make_chat("gpt-5-nano")
    |> openai.with_reasoning(effort: openai.ReasoningHigh)
    |> starlet.user("x")
  let turn = openai.stream_done(chat, state)
  assert turn.ext.reasoning_effort == option.Some(openai.ReasoningHigh)
  assert turn.ext.response_id == option.Some("resp_abc")
}

pub fn response_preserves_reasoning_effort_test() {
  let chat =
    make_chat("gpt-5-nano")
    |> openai.with_reasoning(effort: openai.ReasoningHigh)
    |> starlet.user("x")
  let body =
    json.object([
      #("id", json.string("resp_abc")),
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
                  #("text", json.string("Hi")),
                ]),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string
  let resp = response.new(200) |> response.set_body(body)
  let assert Ok(turn) = openai.response(chat, resp)
  assert turn.ext.reasoning_effort == option.Some(openai.ReasoningHigh)
}

pub fn response_rate_limited_test() {
  let chat =
    make_chat("gpt-5-nano")
    |> starlet.user("Hello")
  let resp =
    response.new(429)
    |> response.set_header("retry-after", "60")
    |> response.set_body("")
  let assert Error(starlet.RateLimited(option.Some(60))) =
    openai.response(chat, resp)
}

pub fn response_provider_error_test() {
  let chat =
    make_chat("gpt-5-nano")
    |> starlet.user("Hello")
  let body =
    json.object([
      #(
        "error",
        json.object([
          #("message", json.string("Invalid API key")),
          #("type", json.string("invalid_request_error")),
        ]),
      ),
    ])
    |> json.to_string
  let resp = response.new(401) |> response.set_body(body)
  let assert Error(starlet.Provider("openai", "Invalid API key", _)) =
    openai.response(chat, resp)
}

pub fn response_http_fallback_test() {
  let chat =
    make_chat("gpt-5-nano")
    |> starlet.user("Hello")
  let resp = response.new(500) |> response.set_body("Internal Server Error")
  let assert Error(starlet.Http(500, "Internal Server Error")) =
    openai.response(chat, resp)
}

pub fn stream_error_from_provider_test() {
  let state = openai.stream_init()
  let chunk =
    sse_event(
      json.object([
        #("type", json.string("error")),
        #(
          "error",
          json.object([
            #("message", json.string("Rate limit exceeded")),
            #("type", json.string("rate_limit_error")),
          ]),
        ),
      ])
      |> json.to_string,
    )
  let #(_state, events) = openai.stream_feed(state, to_bits(chunk))
  let assert [starlet.StreamError(starlet.Provider("openai", msg, _))] = events
  assert msg == "Rate limit exceeded"
}

pub fn response_id_accessor_test() {
  let turn =
    starlet.Turn(
      text: "Hi",
      tool_calls: [],
      ext: openai.Ext(
        response_id: option.Some("resp_abc"),
        reasoning_effort: option.None,
        reasoning_summary: option.None,
      ),
    )
  assert openai.response_id(turn) == option.Some("resp_abc")
}

pub fn reasoning_summary_accessor_test() {
  let turn =
    starlet.Turn(
      text: "Hi",
      tool_calls: [],
      ext: openai.Ext(
        response_id: option.None,
        reasoning_effort: option.None,
        reasoning_summary: option.Some("I thought carefully."),
      ),
    )
  assert openai.reasoning_summary(turn) == option.Some("I thought carefully.")
}

pub fn list_models_response_success_test() {
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
        ]),
      ),
    ])
    |> json.to_string
  let resp = response.new(200) |> response.set_body(body)
  let assert Ok(models) = openai.list_models_response(resp)
  assert models == [openai.Model(id: "gpt-4o", owned_by: "openai")]
}

pub fn list_models_response_rate_limited_test() {
  let resp =
    response.new(429)
    |> response.set_header("retry-after", "30")
    |> response.set_body("")
  let assert Error(starlet.RateLimited(option.Some(30))) =
    openai.list_models_response(resp)
}

pub fn credentials_with_base_url_success_test() {
  let assert Ok(creds) =
    openai.credentials_with_base_url(
      api_key: "test-key",
      base_url: "https://proxy.example.com/openai",
    )
  let chat = openai.chat("gpt-4o") |> starlet.user("Hello")
  let req = openai.request(chat, creds)
  assert string.contains(req.path, "/openai/v1/responses")
}

pub fn credentials_with_base_url_invalid_url_test() {
  let assert Error(starlet.InvalidUrl(_)) =
    openai.credentials_with_base_url(api_key: "test-key", base_url: "://")
}

pub fn continue_from_sets_response_id_test() {
  let chat = openai.chat("gpt-5-nano")
  let chat = openai.continue_from(chat, "resp_abc123")
  assert chat.ext.response_id == option.Some("resp_abc123")
}

pub fn reset_response_id_clears_id_test() {
  let chat = openai.chat("gpt-5-nano")
  let chat = openai.continue_from(chat, "resp_abc123")
  let chat = openai.reset_response_id(chat)
  assert chat.ext.response_id == option.None
}

pub fn decode_response_with_reasoning_summary_test() {
  let body =
    json.object([
      #("id", json.string("resp_789")),
      #(
        "output",
        json.preprocessed_array([
          json.object([
            #("type", json.string("reasoning")),
            #(
              "summary",
              json.preprocessed_array([
                json.object([
                  #("type", json.string("summary_text")),
                  #("text", json.string("I thought about it carefully.")),
                ]),
              ]),
            ),
          ]),
          json.object([
            #("type", json.string("message")),
            #(
              "content",
              json.preprocessed_array([
                json.object([
                  #("type", json.string("output_text")),
                  #("text", json.string("Here is the answer.")),
                ]),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(decoded) = openai.decode_response(body)
  assert decoded.text == "Here is the answer."
  assert decoded.reasoning_summary
    == option.Some("I thought about it carefully.")
  assert decoded.response_id == "resp_789"
}

pub fn request_builds_correct_http_request_test() {
  let creds = openai.credentials("test-key")
  let chat =
    openai.chat("gpt-5-nano")
    |> starlet.user("Hello")

  let req = openai.request(chat, creds)
  assert req.method == http.Post
  assert string.contains(req.path, "/v1/responses")
  let assert Ok(ct) = list.key_find(req.headers, "content-type")
  assert ct == "application/json"
  let assert Ok(auth) = list.key_find(req.headers, "authorization")
  assert string.starts_with(auth, "Bearer")
}

pub fn list_models_request_builds_correct_http_request_test() {
  let creds = openai.credentials("test-key")
  let req = openai.list_models_request(creds)
  assert req.method == http.Get
  assert string.contains(req.path, "/v1/models")
  let assert Ok(auth) = list.key_find(req.headers, "authorization")
  assert auth == "Bearer test-key"
}

pub fn encode_request_with_json_schema_test() {
  let output_schema = schema.object([schema.prop("name", schema.string())])

  let chat =
    openai.chat("gpt-5-nano")
    |> starlet.with_json_output(schema: output_schema)
    |> starlet.user("Give me a name")

  openai.encode_request(chat)
  |> json.to_string
  |> birdie.snap("openai encode request with json schema")
}

pub fn stream_feed_function_call_delta_without_added_test() {
  let state = openai.stream_init()

  let #(_state, events) =
    openai.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("response.function_call_arguments.delta")),
          #("output_index", json.int(0)),
          #("delta", json.string("{\"city\":")),
        ])
        |> json.to_string,
      )),
    )

  let assert [starlet.StreamError(starlet.Decode(msg))] = events
  assert string.contains(msg, "unknown output_index")
}

pub fn stream_feed_output_item_done_without_added_test() {
  let state = openai.stream_init()

  let #(_state, events) =
    openai.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("response.output_item.done")),
          #("output_index", json.int(0)),
          #(
            "item",
            json.object([
              #("type", json.string("function_call")),
              #("call_id", json.string("call_999")),
              #("name", json.string("get_weather")),
              #("arguments", json.string("{}")),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )

  let assert [starlet.StreamError(starlet.Decode(msg))] = events
  assert string.contains(msg, "unknown output_index")
}

pub fn stream_feed_garbled_json_emits_error_test() {
  let state = openai.stream_init()
  let #(_state, events) =
    openai.stream_feed(state, to_bits(sse_event("not valid json")))
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
    make_chat("gpt-5-nano")
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What's the weather in Paris?")

  let state = openai.stream_init()

  let #(state, _) =
    openai.stream_feed(
      state,
      to_bits(output_item_added_event(0, "call_abc", "get_weather")),
    )

  let args = json.object([#("city", json.string("Paris"))]) |> json.to_string
  let #(state, _) =
    openai.stream_feed(state, to_bits(function_call_delta_event(0, args)))
  let #(state, _) =
    openai.stream_feed(
      state,
      to_bits(output_item_done_event(0, "call_abc", "get_weather", args)),
    )

  let turn = openai.stream_done(chat, state)
  let assert [call] = turn.tool_calls
  assert call.id == "call_abc"
  assert call.name == "get_weather"

  let chat = starlet.append_turn(chat, turn)
  let result =
    tool.success(call, output: json.object([#("temp", json.int(22))]))
  let chat = starlet.with_tool_results(chat, results: [result])

  openai.encode_request(chat)
  |> json.to_string
  |> birdie.snap("openai stream tool call round trip")
}

pub fn assistant_with_tool_calls_appends_message_test() {
  let arguments_json =
    json.object([#("city", json.string("Paris"))]) |> json.to_string
  let assert Ok(arguments) = json.parse(arguments_json, decode.dynamic)
  let call = tool.Call(id: "call_1", name: "get_weather", arguments:)
  let result =
    tool.success(call, output: json.object([#("temp", json.int(22))]))

  let chat =
    make_chat("gpt-5-nano")
    |> starlet.with_tools([])
    |> starlet.with_ext(openai.Ext(
      response_id: option.Some("resp_stale"),
      reasoning_effort: option.None,
      reasoning_summary: option.Some("stale summary"),
    ))
    |> starlet.user("Weather?")
    |> openai.assistant_with_tool_calls("Looking up...", [call])
    |> starlet.with_tool_results(results: [result])
    |> starlet.user("Thanks")

  let assert [
    starlet.UserMessage("Weather?"),
    starlet.AssistantMessage("Looking up...", [returned]),
    starlet.ToolResultMessage(call_id: "call_1", ..),
    starlet.UserMessage("Thanks"),
  ] = chat.messages
  assert returned.id == "call_1"
  assert chat.ext.response_id == option.None
  assert chat.ext.reasoning_summary == option.None
}

pub fn from_messages_resets_response_id_and_summary_test() {
  let chat =
    make_chat("gpt-5-nano")
    |> starlet.with_ext(openai.Ext(
      response_id: option.Some("resp_stale"),
      reasoning_effort: option.None,
      reasoning_summary: option.Some("old summary"),
    ))
  let messages = [
    starlet.UserMessage("Hi"),
    starlet.AssistantMessage("Hello", []),
    starlet.UserMessage("Again"),
  ]
  let assert Ok(chat) = openai.from_messages(chat, messages)

  assert chat.messages == messages
  assert chat.ext.response_id == option.None
  assert chat.ext.reasoning_summary == option.None
}

pub fn from_messages_rejects_empty_test() {
  let chat = make_chat("gpt-5-nano")
  assert openai.from_messages(chat, [])
    == Error(starlet.InvalidArgument(
      "from_messages requires at least one message",
    ))
}
