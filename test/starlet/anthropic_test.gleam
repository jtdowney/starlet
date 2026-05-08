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
  anthropic.chat(model)
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

pub fn encode_request_with_conversation_test() {
  let chat =
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.user("Hello")
    |> anthropic.assistant("Hi there!")
    |> starlet.user("How are you?")

  anthropic.encode_request(chat)
  |> json.to_string
  |> birdie.snap("anthropic encode request with conversation")
}

pub fn encode_request_respects_explicit_max_tokens_test() {
  let chat =
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.max_tokens(1000)
    |> starlet.user("Hello")

  anthropic.encode_request(chat)
  |> json.to_string
  |> birdie.snap("anthropic encode request with explicit max tokens")
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

  let chat =
    anthropic.chat("claude-haiku-4-5-20251001")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

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

pub fn encode_request_with_multi_turn_tool_use_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "toolu_123", name: "get_weather", arguments:)
  let tool_result = json.object([#("temp", json.int(22))]) |> json.to_string

  let chat =
    anthropic.chat("claude-haiku-4-5-20251001")
    |> starlet.with_tools([])
    |> starlet.user("What's the weather in Paris?")

  let chat =
    starlet.Chat(..chat, messages: [
      starlet.UserMessage("What's the weather in Paris?"),
      starlet.AssistantMessage("", [tool_call]),
      starlet.ToolResultMessage("toolu_123", "get_weather", tool_result),
      starlet.AssistantMessage("It's 22°C in Paris!", []),
      starlet.UserMessage("Now check London too"),
    ])

  anthropic.encode_request(chat)
  |> json.to_string
  |> birdie.snap("anthropic encode request with multi turn tool use")
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
  let chat = anthropic.chat("claude-haiku-4-5-20251001")
  let chat = starlet.max_tokens(chat, 32_000)
  let assert Ok(chat) = anthropic.with_thinking(chat, budget: 16_384)
  let chat = starlet.user(chat, "Think step by step")

  anthropic.encode_request(chat)
  |> json.to_string
  |> birdie.snap("anthropic encode request with thinking")
}

pub fn thinking_accessor_test() {
  let turn =
    starlet.Turn(
      text: "answer",
      tool_calls: [],
      ext: anthropic.Ext(
        thinking_budget: option.None,
        thinking: option.Some("I reasoned about this."),
      ),
    )
  assert anthropic.thinking(turn) == option.Some("I reasoned about this.")
}

pub fn list_models_response_success_test() {
  let body =
    json.object([
      #(
        "data",
        json.preprocessed_array([
          json.object([
            #("id", json.string("claude-sonnet-4-20250514")),
            #("type", json.string("model")),
            #("display_name", json.string("Claude Sonnet 4")),
            #("created_at", json.string("2025-05-14T00:00:00Z")),
          ]),
        ]),
      ),
    ])
    |> json.to_string
  let resp = response.new(200) |> response.set_body(body)
  let assert Ok(models) = anthropic.list_models_response(resp)
  assert models
    == [
      anthropic.Model(
        id: "claude-sonnet-4-20250514",
        display_name: "Claude Sonnet 4",
      ),
    ]
}

pub fn list_models_response_rate_limited_test() {
  let resp =
    response.new(429)
    |> response.set_header("retry-after", "30")
    |> response.set_body("")
  let assert Error(starlet.RateLimited(option.Some(30))) =
    anthropic.list_models_response(resp)
}

pub fn credentials_with_base_url_success_test() {
  let assert Ok(creds) =
    anthropic.credentials_with_base_url(
      api_key: "test-key",
      base_url: "https://proxy.example.com/anthropic",
    )
  let chat =
    anthropic.chat("claude-haiku-4-5-20251001")
    |> starlet.user("Hello")
  let req = anthropic.request(chat, creds)
  assert string.contains(req.path, "/anthropic/v1/messages")
}

pub fn credentials_with_base_url_invalid_url_test() {
  let assert Error(starlet.InvalidUrl(_)) =
    anthropic.credentials_with_base_url(api_key: "test-key", base_url: "://")
}

pub fn with_thinking_valid_budget_test() {
  let chat = anthropic.chat("claude-haiku-4-5-20251001")

  let assert Ok(_chat) = anthropic.with_thinking(chat, budget: 1024)
  let assert Ok(_chat) = anthropic.with_thinking(chat, budget: 16_384)
}

pub fn with_thinking_invalid_budget_test() {
  let chat = anthropic.chat("claude-haiku-4-5-20251001")

  let assert Error(starlet.InvalidArgument(msg)) =
    anthropic.with_thinking(chat, budget: 1023)
  assert string.contains(msg, "1024")
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
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.user("Hello")

  anthropic.encode_stream_request(chat)
  |> json.to_string
  |> birdie.snap("anthropic encode stream request")
}

pub fn stream_feed_text_delta_test() {
  let state = anthropic.stream_init()
  let chunk =
    sse_event(
      json.object([
        #("type", json.string("content_block_delta")),
        #("index", json.int(0)),
        #(
          "delta",
          json.object([
            #("type", json.string("text_delta")),
            #("text", json.string("Hello")),
          ]),
        ),
      ])
      |> json.to_string,
    )
  let #(_state, events) = anthropic.stream_feed(state, to_bits(chunk))
  assert events == [starlet.TextDelta("Hello")]
}

pub fn stream_feed_thinking_delta_test() {
  let state = anthropic.stream_init()
  let chunk =
    sse_event(
      json.object([
        #("type", json.string("content_block_delta")),
        #("index", json.int(0)),
        #(
          "delta",
          json.object([
            #("type", json.string("thinking_delta")),
            #("thinking", json.string("Let me reason...")),
          ]),
        ),
      ])
      |> json.to_string,
    )
  let #(_state, events) = anthropic.stream_feed(state, to_bits(chunk))
  assert events == [starlet.ThinkingDelta("Let me reason...")]
}

pub fn stream_feed_tool_call_test() {
  let state = anthropic.stream_init()

  // tool_use start
  let #(state, events1) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_start")),
          #("index", json.int(0)),
          #(
            "content_block",
            json.object([
              #("type", json.string("tool_use")),
              #("id", json.string("toolu_123")),
              #("name", json.string("get_weather")),
              #("input", json.object([])),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )
  assert events1 == [starlet.ToolCallStart("toolu_123", "get_weather")]

  // input_json_delta
  let #(state, events2) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_delta")),
          #("index", json.int(0)),
          #(
            "delta",
            json.object([
              #("type", json.string("input_json_delta")),
              #("partial_json", json.string("{\"city\":")),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )
  assert events2 == [starlet.ToolCallDelta("toolu_123", "{\"city\":")]

  // more args
  let #(state, events3) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_delta")),
          #("index", json.int(0)),
          #(
            "delta",
            json.object([
              #("type", json.string("input_json_delta")),
              #("partial_json", json.string("\"Paris\"}")),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )
  assert events3 == [starlet.ToolCallDelta("toolu_123", "\"Paris\"}")]

  // content_block_stop finalizes the tool call
  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_stop")),
          #("index", json.int(0)),
        ])
        |> json.to_string,
      )),
    )

  let chat = make_chat("claude-haiku-4-5-20251001") |> starlet.user("x")
  let turn = anthropic.stream_done(chat, state)
  let assert [call] = turn.tool_calls
  assert call.id == "toolu_123"
  assert call.name == "get_weather"
  let assert Ok("Paris") =
    decode.run(call.arguments, decode.at(["city"], decode.string))
}

pub fn stream_feed_tool_call_with_incomplete_json_preserves_raw_test() {
  let state = anthropic.stream_init()

  // tool_use start
  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_start")),
          #("index", json.int(0)),
          #(
            "content_block",
            json.object([
              #("type", json.string("tool_use")),
              #("id", json.string("toolu_bad")),
              #("name", json.string("broken")),
              #("input", json.object([])),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )

  // Incomplete JSON args
  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_delta")),
          #("index", json.int(0)),
          #(
            "delta",
            json.object([
              #("type", json.string("input_json_delta")),
              #("partial_json", json.string("{\"key\":")),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )

  // content_block_stop finalizes with incomplete JSON
  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_stop")),
          #("index", json.int(0)),
        ])
        |> json.to_string,
      )),
    )

  let chat = make_chat("claude-haiku-4-5-20251001") |> starlet.user("x")
  let turn = anthropic.stream_done(chat, state)
  let assert [call] = turn.tool_calls
  assert call.id == "toolu_bad"
  assert call.name == "broken"
  // Raw JSON string is preserved as Dynamic
  let assert Ok("{\"key\":") = decode.run(call.arguments, decode.string)
}

pub fn stream_feed_message_stop_test() {
  let state = anthropic.stream_init()
  let chunk =
    sse_event(
      json.object([#("type", json.string("message_stop"))])
      |> json.to_string,
    )
  let #(_state, events) = anthropic.stream_feed(state, to_bits(chunk))
  assert events == [starlet.Done]
}

pub fn stream_done_assembles_turn_test() {
  let state = anthropic.stream_init()

  // Feed some text deltas
  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_delta")),
          #("index", json.int(0)),
          #(
            "delta",
            json.object([
              #("type", json.string("text_delta")),
              #("text", json.string("Hello")),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )
  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_delta")),
          #("index", json.int(0)),
          #(
            "delta",
            json.object([
              #("type", json.string("text_delta")),
              #("text", json.string(" world")),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )
  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([#("type", json.string("message_stop"))])
        |> json.to_string,
      )),
    )

  let chat = make_chat("claude-haiku-4-5-20251001") |> starlet.user("x")
  let turn = anthropic.stream_done(chat, state)
  assert turn.text == "Hello world"
  assert turn.tool_calls == []
  assert turn.ext
    == anthropic.Ext(thinking_budget: option.None, thinking: option.None)
}

pub fn stream_done_with_thinking_test() {
  let state = anthropic.stream_init()

  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_delta")),
          #("index", json.int(0)),
          #(
            "delta",
            json.object([
              #("type", json.string("thinking_delta")),
              #("thinking", json.string("reasoning...")),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )
  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_delta")),
          #("index", json.int(1)),
          #(
            "delta",
            json.object([
              #("type", json.string("text_delta")),
              #("text", json.string("answer")),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )

  let chat = make_chat("claude-haiku-4-5-20251001") |> starlet.user("x")
  let turn = anthropic.stream_done(chat, state)
  assert turn.text == "answer"
  assert turn.ext.thinking == option.Some("reasoning...")
}

pub fn stream_done_preserves_thinking_budget_test() {
  let state = anthropic.stream_init()
  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_delta")),
          #("index", json.int(0)),
          #(
            "delta",
            json.object([
              #("type", json.string("text_delta")),
              #("text", json.string("Hi")),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )

  let assert Ok(chat) =
    make_chat("claude-haiku-4-5-20251001")
    |> anthropic.with_thinking(budget: 16_384)
  let chat = starlet.user(chat, "x")
  let turn = anthropic.stream_done(chat, state)
  assert turn.ext.thinking_budget == option.Some(16_384)
}

pub fn response_preserves_thinking_budget_test() {
  let assert Ok(chat) =
    make_chat("claude-haiku-4-5-20251001")
    |> anthropic.with_thinking(budget: 16_384)
  let chat = starlet.user(chat, "x")
  let body =
    json.object([
      #(
        "content",
        json.preprocessed_array([
          json.object([
            #("type", json.string("text")),
            #("text", json.string("Hello")),
          ]),
        ]),
      ),
    ])
    |> json.to_string
  let resp = response.new(200) |> response.set_body(body)
  let assert Ok(turn) = anthropic.response(chat, resp)
  assert turn.ext.thinking_budget == option.Some(16_384)
}

pub fn stream_error_unparseable_test() {
  let state = anthropic.stream_init()
  let chunk =
    sse_event(
      json.object([
        #("type", json.string("error")),
        #("weird", json.string("format")),
      ])
      |> json.to_string,
    )
  let #(_state, events) = anthropic.stream_feed(state, to_bits(chunk))
  let assert [starlet.StreamError(starlet.Provider("anthropic", _, _))] = events
}

pub fn response_rate_limited_test() {
  let chat =
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.user("Hello")
  let resp =
    response.new(429)
    |> response.set_header("retry-after", "30")
    |> response.set_body("")
  let assert Error(starlet.RateLimited(option.Some(30))) =
    anthropic.response(chat, resp)
}

pub fn response_provider_error_test() {
  let chat =
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.user("Hello")
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
  let resp = response.new(401) |> response.set_body(body)
  let assert Error(starlet.Provider("anthropic", "Invalid API key", _)) =
    anthropic.response(chat, resp)
}

pub fn response_http_fallback_test() {
  let chat =
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.user("Hello")
  let resp = response.new(500) |> response.set_body("Internal Server Error")
  let assert Error(starlet.Http(500, "Internal Server Error")) =
    anthropic.response(chat, resp)
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

  let chat = anthropic.chat("claude-haiku-4-5-20251001")
  let chat = starlet.Chat(..chat, json_schema: option.Some(schema))
  let chat = starlet.user(chat, "Give me a name")

  anthropic.encode_request(chat)
  |> json.to_string
  |> birdie.snap("anthropic encode request with json schema")
}

pub fn request_builds_correct_http_request_test() {
  let creds = anthropic.credentials("test-key")
  let chat =
    anthropic.chat("claude-haiku-4-5-20251001")
    |> starlet.user("Hello")

  let req = anthropic.request(chat, creds)
  assert req.method == http.Post
  assert string.contains(req.path, "/v1/messages")
  let assert Ok(ct) = list.key_find(req.headers, "content-type")
  assert ct == "application/json"
  let assert Ok(api_key) = list.key_find(req.headers, "x-api-key")
  assert api_key == "test-key"
  let assert Ok(version) = list.key_find(req.headers, "anthropic-version")
  assert version == "2023-06-01"
}

pub fn list_models_request_builds_correct_http_request_test() {
  let creds = anthropic.credentials("test-key")
  let req = anthropic.list_models_request(creds)
  assert req.method == http.Get
  assert string.contains(req.path, "/v1/models")
  let assert Ok(api_key) = list.key_find(req.headers, "x-api-key")
  assert api_key == "test-key"
  let assert Ok(version) = list.key_find(req.headers, "anthropic-version")
  assert version == "2023-06-01"
}

pub fn request_with_thinking_sets_beta_header_test() {
  let creds = anthropic.credentials("test-key")
  let assert Ok(chat) =
    anthropic.chat("claude-haiku-4-5-20251001")
    |> anthropic.with_thinking(budget: 16_384)
  let chat =
    chat
    |> starlet.max_tokens(32_000)
    |> starlet.user("Hello")

  let req = anthropic.request(chat, creds)
  let assert Ok(beta) = list.key_find(req.headers, "anthropic-beta")
  assert string.contains(beta, "interleaved-thinking")
}

pub fn request_with_json_schema_no_beta_header_test() {
  let creds = anthropic.credentials("test-key")
  let schema =
    json.object([
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #("name", json.object([#("type", json.string("string"))])),
        ]),
      ),
    ])
  let chat = anthropic.chat("claude-haiku-4-5-20251001")
  let chat = starlet.Chat(..chat, json_schema: option.Some(schema))
  let chat = starlet.user(chat, "Give me a name")

  let req = anthropic.request(chat, creds)
  assert list.key_find(req.headers, "anthropic-beta") == Error(Nil)
}

pub fn stream_error_with_message_test() {
  let state = anthropic.stream_init()
  let chunk =
    sse_event(
      json.object([
        #("type", json.string("error")),
        #(
          "error",
          json.object([
            #("type", json.string("overloaded_error")),
            #("message", json.string("Server is overloaded")),
          ]),
        ),
      ])
      |> json.to_string,
    )
  let #(_state, events) = anthropic.stream_feed(state, to_bits(chunk))
  let assert [starlet.StreamError(starlet.Provider("anthropic", msg, _))] =
    events
  assert msg == "Server is overloaded"
}

// --- List Models Tests ---

pub fn decode_models_response_test() {
  let body =
    json.object([
      #(
        "data",
        json.preprocessed_array([
          json.object([
            #("id", json.string("claude-sonnet-4-20250514")),
            #("type", json.string("model")),
            #("display_name", json.string("Claude Sonnet 4")),
            #("created_at", json.string("2025-05-14T00:00:00Z")),
          ]),
          json.object([
            #("id", json.string("claude-haiku-4-5-20251001")),
            #("type", json.string("model")),
            #("display_name", json.string("Claude Haiku 4.5")),
            #("created_at", json.string("2025-10-01T00:00:00Z")),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(models) = anthropic.decode_models(body)
  assert models
    == [
      anthropic.Model(
        id: "claude-sonnet-4-20250514",
        display_name: "Claude Sonnet 4",
      ),
      anthropic.Model(
        id: "claude-haiku-4-5-20251001",
        display_name: "Claude Haiku 4.5",
      ),
    ]
}

pub fn decode_models_empty_list_test() {
  let body =
    json.object([#("data", json.preprocessed_array([]))])
    |> json.to_string

  let assert Ok(models) = anthropic.decode_models(body)
  assert models == []
}

pub fn decode_models_invalid_json_test() {
  let body = "not json"
  let assert Error(_) = anthropic.decode_models(body)
}

pub fn stream_feed_garbled_json_emits_error_test() {
  let state = anthropic.stream_init()
  let #(_state, events) =
    anthropic.stream_feed(state, to_bits(sse_event("not valid json")))
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
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What's the weather in Paris?")

  let state = anthropic.stream_init()

  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_start")),
          #("index", json.int(0)),
          #(
            "content_block",
            json.object([
              #("type", json.string("tool_use")),
              #("id", json.string("toolu_abc")),
              #("name", json.string("get_weather")),
              #("input", json.object([])),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )

  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_delta")),
          #("index", json.int(0)),
          #(
            "delta",
            json.object([
              #("type", json.string("input_json_delta")),
              #("partial_json", json.string("{\"city\":\"Paris\"}")),
            ]),
          ),
        ])
        |> json.to_string,
      )),
    )

  let #(state, _) =
    anthropic.stream_feed(
      state,
      to_bits(sse_event(
        json.object([
          #("type", json.string("content_block_stop")),
          #("index", json.int(0)),
        ])
        |> json.to_string,
      )),
    )

  let turn = anthropic.stream_done(chat, state)
  let assert [call] = turn.tool_calls
  assert call.id == "toolu_abc"
  assert call.name == "get_weather"

  let chat = starlet.append_turn(chat, turn)
  let result =
    tool.success(call, output: json.object([#("temp", json.int(22))]))
  let chat = starlet.with_tool_results(chat, results: [result])

  anthropic.encode_request(chat)
  |> json.to_string
  |> birdie.snap("anthropic stream tool call round trip")
}

pub fn assistant_with_tool_calls_appends_message_test() {
  let arguments_json =
    json.object([#("city", json.string("Paris"))]) |> json.to_string
  let assert Ok(arguments) = json.parse(arguments_json, decode.dynamic)
  let call = tool.Call(id: "toolu_1", name: "get_weather", arguments:)
  let result =
    tool.success(call, output: json.object([#("temp", json.int(22))]))

  let chat =
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.with_tools([])
    |> starlet.with_ext(anthropic.Ext(
      thinking_budget: option.None,
      thinking: option.Some("stale reasoning"),
    ))
    |> starlet.user("Weather?")
    |> anthropic.assistant_with_tool_calls("Looking up...", [call])
    |> starlet.with_tool_results(results: [result])
    |> starlet.user("Thanks")

  let assert [
    starlet.UserMessage("Weather?"),
    starlet.AssistantMessage("Looking up...", [returned]),
    starlet.ToolResultMessage(call_id: "toolu_1", ..),
    starlet.UserMessage("Thanks"),
  ] = chat.messages
  assert returned.id == "toolu_1"
  assert returned.name == "get_weather"
  assert chat.ext.thinking == option.None
}

pub fn from_messages_replaces_history_and_lands_in_ready_test() {
  let messages = [
    starlet.UserMessage("Hi"),
    starlet.AssistantMessage("Hello", []),
    starlet.UserMessage("How are you?"),
  ]
  let assert Ok(chat) =
    make_chat("claude-haiku-4-5-20251001")
    |> starlet.with_ext(anthropic.Ext(
      thinking_budget: option.None,
      thinking: option.Some("stale reasoning"),
    ))
    |> anthropic.from_messages(messages)
  let turn = starlet.Turn(text: "Fine.", tool_calls: [], ext: chat.ext)
  let chat = starlet.append_turn(chat, turn)

  assert chat.messages
    == [
      starlet.UserMessage("Hi"),
      starlet.AssistantMessage("Hello", []),
      starlet.UserMessage("How are you?"),
      starlet.AssistantMessage("Fine.", []),
    ]
  assert chat.ext.thinking == option.None
}

pub fn from_messages_rejects_empty_test() {
  let chat = make_chat("claude-haiku-4-5-20251001")
  assert anthropic.from_messages(chat, [])
    == Error(starlet.InvalidArgument(
      "from_messages requires at least one message",
    ))
}
