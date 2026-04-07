import birdie
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import starlet.{
  AssistantMessage, Chat, Decode, Request, ToolResultMessage, UserMessage, chat,
}
import starlet/openai_compat
import starlet/openai_compat/thinking
import starlet/tool

fn default_ext() -> openai_compat.Ext {
  openai_compat.Ext(
    dialect: thinking.Tags,
    thinking_config: None,
    thinking: None,
    thinking_by_index: [],
    interleaved_thinking: True,
  )
}

pub fn encode_simple_request_test() {
  let req =
    Request(
      model: "gpt-4o",
      system_prompt: None,
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai_compat.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai_compat encode simple request")
}

pub fn encode_request_with_system_prompt_test() {
  let req =
    Request(
      model: "gpt-4o",
      system_prompt: Some("Be helpful"),
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai_compat.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai_compat encode request with system prompt")
}

pub fn encode_request_with_options_test() {
  let req =
    Request(
      model: "gpt-4o",
      system_prompt: None,
      messages: [UserMessage("Hello")],
      tools: [],
      temperature: Some(0.7),
      max_tokens: Some(1000),
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai_compat.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai_compat encode request with options")
}

pub fn encode_request_with_conversation_test() {
  let req =
    Request(
      model: "gpt-4o",
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

  openai_compat.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai_compat encode request with conversation")
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
      model: "gpt-4o",
      system_prompt: None,
      messages: [UserMessage("What's the weather in Paris?")],
      tools: [weather_tool],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai_compat.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai_compat encode request with tools")
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
    ])

  let req =
    Request(
      model: "gpt-4o",
      system_prompt: None,
      messages: [UserMessage("Tell me about France")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: Some(schema),
      timeout_ms: 60_000,
    )

  openai_compat.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai_compat encode request with json schema")
}

pub fn decode_simple_response_test() {
  let body =
    json.object([
      #(
        "choices",
        json.preprocessed_array([
          json.object([
            #(
              "message",
              json.object([
                #("role", json.string("assistant")),
                #("content", json.string("Hello there!")),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(response, thinking)) =
    openai_compat.decode_response(body, default_ext())
  assert response.text == "Hello there!"
  assert thinking == None
}

pub fn decode_response_with_tool_calls_test() {
  let args = json.object([#("city", json.string("Paris"))]) |> json.to_string
  let body =
    json.object([
      #(
        "choices",
        json.preprocessed_array([
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
                      #("type", json.string("function")),
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
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(response, _thinking)) =
    openai_compat.decode_response(body, default_ext())
  assert response.text == ""

  let assert [call] = response.tool_calls
  assert call.id == "call_abc"
  assert call.name == "get_weather"
  let assert Ok("Paris") =
    decode.run(call.arguments, decode.at(["city"], decode.string))
}

pub fn decode_invalid_json_returns_error_test() {
  let body = "not json"
  let assert Error(Decode(_)) =
    openai_compat.decode_response(body, default_ext())
}

pub fn decode_empty_choices_test() {
  let body =
    json.object([#("choices", json.preprocessed_array([]))])
    |> json.to_string

  let assert Ok(#(response, _thinking)) =
    openai_compat.decode_response(body, default_ext())
  assert response.text == ""
  assert response.tool_calls == []
}

pub fn encode_request_with_reasoning_effort_test() {
  let req =
    Request(
      model: "deepseek-r1",
      system_prompt: None,
      messages: [UserMessage("Solve step by step")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  let config =
    thinking.config_for_dialect(thinking.Generic, thinking.EffortHigh)
  let ext =
    openai_compat.Ext(
      dialect: thinking.Generic,
      thinking_config: Some(config),
      thinking: None,
      thinking_by_index: [],
      interleaved_thinking: True,
    )

  openai_compat.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("openai_compat encode request with reasoning_effort high")
}

pub fn encode_request_with_reasoning_format_test() {
  let req =
    Request(
      model: "llama-3.3-70b",
      system_prompt: None,
      messages: [UserMessage("Solve step by step")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  let config = thinking.config_for_dialect(thinking.Groq, thinking.EffortHigh)
  let ext =
    openai_compat.Ext(
      dialect: thinking.Groq,
      thinking_config: Some(config),
      thinking: None,
      thinking_by_index: [],
      interleaved_thinking: True,
    )

  openai_compat.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("openai_compat encode request with reasoning_format parsed")
}

pub fn encode_request_with_disable_reasoning_test() {
  let req =
    Request(
      model: "glm-z1-air",
      system_prompt: None,
      messages: [UserMessage("Quick answer")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  let config =
    thinking.Config(
      request: thinking.RequestDisable(True),
      response: thinking.ResponseNone,
      context: thinking.ContextDoNotSend,
      strip_from_content: False,
    )
  let ext =
    openai_compat.Ext(
      dialect: thinking.Tags,
      thinking_config: Some(config),
      thinking: None,
      thinking_by_index: [],
      interleaved_thinking: True,
    )

  openai_compat.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("openai_compat encode request with disable_reasoning")
}

pub fn encode_request_with_zai_thinking_test() {
  let req =
    Request(
      model: "deepseek-reasoner",
      system_prompt: None,
      messages: [UserMessage("Think about this")],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  let config =
    thinking.Config(
      request: thinking.RequestZai(True),
      response: thinking.ResponseNone,
      context: thinking.ContextDoNotSend,
      strip_from_content: False,
    )
  let ext =
    openai_compat.Ext(
      dialect: thinking.Tags,
      thinking_config: Some(config),
      thinking: None,
      thinking_by_index: [],
      interleaved_thinking: True,
    )

  openai_compat.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("openai_compat encode request with zai thinking enabled")
}

pub fn decode_response_with_reasoning_content_field_test() {
  let body =
    json.object([
      #(
        "choices",
        json.preprocessed_array([
          json.object([
            #(
              "message",
              json.object([
                #("role", json.string("assistant")),
                #("content", json.string("The answer is 42.")),
                #(
                  "reasoning_content",
                  json.string("Let me think... I need to calculate..."),
                ),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let config =
    thinking.config_for_dialect(thinking.Generic, thinking.EffortHigh)
  let ext =
    openai_compat.Ext(
      dialect: thinking.Generic,
      thinking_config: Some(config),
      thinking: None,
      thinking_by_index: [],
      interleaved_thinking: True,
    )

  let assert Ok(#(response, thinking)) =
    openai_compat.decode_response(body, ext)
  assert response.text == "The answer is 42."
  assert thinking == Some("Let me think... I need to calculate...")
}

pub fn decode_response_with_reasoning_field_test() {
  let body =
    json.object([
      #(
        "choices",
        json.preprocessed_array([
          json.object([
            #(
              "message",
              json.object([
                #("role", json.string("assistant")),
                #("content", json.string("The answer is 42.")),
                #("reasoning", json.string("Step 1: analyze the question...")),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let config = thinking.config_for_dialect(thinking.Groq, thinking.EffortHigh)
  let ext =
    openai_compat.Ext(
      dialect: thinking.Groq,
      thinking_config: Some(config),
      thinking: None,
      thinking_by_index: [],
      interleaved_thinking: True,
    )

  let assert Ok(#(response, thinking)) =
    openai_compat.decode_response(body, ext)
  assert response.text == "The answer is 42."
  assert thinking == Some("Step 1: analyze the question...")
}

pub fn decode_response_with_think_tags_test() {
  let body =
    json.object([
      #(
        "choices",
        json.preprocessed_array([
          json.object([
            #(
              "message",
              json.object([
                #("role", json.string("assistant")),
                #(
                  "content",
                  json.string(
                    "<think>Let me think about this...</think>The answer is 42.",
                  ),
                ),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let config = thinking.config_for_dialect(thinking.Tags, thinking.EffortHigh)
  let ext =
    openai_compat.Ext(
      dialect: thinking.Tags,
      thinking_config: Some(config),
      thinking: None,
      thinking_by_index: [],
      interleaved_thinking: True,
    )

  let assert Ok(#(response, thinking)) =
    openai_compat.decode_response(body, ext)
  assert response.text == "The answer is 42."
  assert thinking == Some("Let me think about this...")
}

pub fn decode_response_with_think_tags_no_strip_test() {
  let body =
    json.object([
      #(
        "choices",
        json.preprocessed_array([
          json.object([
            #(
              "message",
              json.object([
                #("role", json.string("assistant")),
                #(
                  "content",
                  json.string(
                    "<think>Let me think about this...</think>The answer is 42.",
                  ),
                ),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let config =
    thinking.Config(
      request: thinking.RequestNone,
      response: thinking.ResponseThinkTags,
      context: thinking.ContextDoNotSend,
      strip_from_content: False,
    )
  let ext =
    openai_compat.Ext(
      dialect: thinking.Tags,
      thinking_config: Some(config),
      thinking: None,
      thinking_by_index: [],
      interleaved_thinking: True,
    )

  let assert Ok(#(response, thinking)) =
    openai_compat.decode_response(body, ext)
  assert response.text
    == "<think>Let me think about this...</think>The answer is 42."
  assert thinking == Some("Let me think about this...")
}

pub fn decode_response_without_thinking_config_ignores_fields_test() {
  let body =
    json.object([
      #(
        "choices",
        json.preprocessed_array([
          json.object([
            #(
              "message",
              json.object([
                #("role", json.string("assistant")),
                #("content", json.string("The answer is 42.")),
                #("reasoning_content", json.string("This should be ignored")),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(#(response, thinking)) =
    openai_compat.decode_response(body, default_ext())
  assert response.text == "The answer is 42."
  assert thinking == None
}

pub fn encode_request_with_tool_calls_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let tool_call = tool.Call(id: "call_123", name: "get_weather", arguments:)

  let req =
    Request(
      model: "gpt-4o",
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

  openai_compat.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai_compat encode request with tool calls")
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
      model: "gpt-4o",
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

  openai_compat.encode_request(req, default_ext())
  |> json.to_string
  |> birdie.snap("openai_compat encode request with tool result")
}

pub fn encode_request_with_context_send_as_field_test() {
  let config =
    thinking.Config(
      request: thinking.RequestEffort("high"),
      response: thinking.ResponseFields(["reasoning_content"]),
      context: thinking.ContextSendAsField("reasoning_content"),
      strip_from_content: False,
    )
  let ext =
    openai_compat.Ext(
      dialect: thinking.Tags,
      thinking_config: Some(config),
      thinking: None,
      thinking_by_index: [],
      interleaved_thinking: True,
    )

  let req =
    Request(
      model: "deepseek-r1",
      system_prompt: None,
      messages: [
        UserMessage("First question"),
        AssistantMessage("First answer", []),
        UserMessage("Follow up"),
      ],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai_compat.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("openai_compat encode request with context send as field")
}

pub fn encode_request_with_context_send_with_tags_test() {
  let config =
    thinking.Config(
      request: thinking.RequestNone,
      response: thinking.ResponseThinkTags,
      context: thinking.ContextSendWithTags,
      strip_from_content: True,
    )
  let ext =
    openai_compat.Ext(
      dialect: thinking.Tags,
      thinking_config: Some(config),
      thinking: None,
      thinking_by_index: [],
      interleaved_thinking: True,
    )

  let req =
    Request(
      model: "deepseek-r1",
      system_prompt: None,
      messages: [
        UserMessage("First question\nWith detail"),
        AssistantMessage("First answer with \"quotes\"", []),
        UserMessage("Follow up"),
      ],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai_compat.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("openai_compat encode request with context send with tags")
}

pub fn encode_request_with_context_send_with_tags_preserves_history_test() {
  let config =
    thinking.Config(
      request: thinking.RequestNone,
      response: thinking.ResponseThinkTags,
      context: thinking.ContextSendWithTags,
      strip_from_content: True,
    )
  let ext =
    openai_compat.Ext(
      dialect: thinking.Tags,
      thinking_config: Some(config),
      thinking: None,
      thinking_by_index: [],
      interleaved_thinking: True,
    )

  let req =
    Request(
      model: "deepseek-r1",
      system_prompt: None,
      messages: [
        UserMessage("First question"),
        AssistantMessage("<think>Old reasoning</think>First answer", []),
        UserMessage("Second question"),
        AssistantMessage("Second answer", []),
        UserMessage("Follow up"),
      ],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai_compat.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("openai_compat encode request preserves thinking history")
}

pub fn encode_request_preserves_reasoning_context_across_turns_test() {
  let config =
    thinking.Config(
      request: thinking.RequestEffort("high"),
      response: thinking.ResponseFields(["reasoning_content"]),
      context: thinking.ContextSendAsField("reasoning_content"),
      strip_from_content: False,
    )
  let ext =
    openai_compat.Ext(
      dialect: thinking.Together,
      thinking_config: Some(config),
      thinking: Some("Reasoning two"),
      thinking_by_index: [#(3, "Reasoning two"), #(1, "Reasoning one")],
      interleaved_thinking: True,
    )

  let req =
    Request(
      model: "deepseek-r1",
      system_prompt: None,
      messages: [
        UserMessage("First question"),
        AssistantMessage("First answer", []),
        UserMessage("Second question"),
        AssistantMessage("Second answer", []),
        UserMessage("Follow up"),
      ],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai_compat.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("openai_compat encode request preserves reasoning context")
}

pub fn encode_request_without_interleaved_thinking_omits_history_test() {
  let config =
    thinking.Config(
      request: thinking.RequestEffort("high"),
      response: thinking.ResponseFields(["reasoning_content"]),
      context: thinking.ContextSendAsField("reasoning_content"),
      strip_from_content: False,
    )
  let client =
    openai_compat.new("https://example.com", "test", thinking.Together)
  let chat =
    chat(client, "deepseek-r1")
    |> openai_compat.with_thinking_config(config)
    |> openai_compat.with_interleaved_thinking
    |> openai_compat.without_interleaved_thinking
  let Chat(ext:, ..) = chat

  let req =
    Request(
      model: "deepseek-r1",
      system_prompt: None,
      messages: [
        UserMessage("First question"),
        AssistantMessage("First answer", []),
        UserMessage("Follow up"),
      ],
      tools: [],
      temperature: None,
      max_tokens: None,
      json_schema: None,
      timeout_ms: 60_000,
    )

  openai_compat.encode_request(req, ext)
  |> json.to_string
  |> birdie.snap("openai_compat encode request without interleaved thinking")
}

pub fn config_for_dialect_test() {
  let fireworks_high =
    thinking.config_for_dialect(thinking.Generic, thinking.EffortHigh)
  assert fireworks_high.request == thinking.RequestEffort("high")

  let fireworks_medium =
    thinking.config_for_dialect(thinking.Generic, thinking.EffortMedium)
  assert fireworks_medium.request == thinking.RequestEffort("medium")

  let fireworks_low =
    thinking.config_for_dialect(thinking.Generic, thinking.EffortLow)
  assert fireworks_low.request == thinking.RequestEffort("low")

  let fireworks_none =
    thinking.config_for_dialect(thinking.Generic, thinking.EffortNone)
  assert fireworks_none.request == thinking.RequestNone

  let together_high =
    thinking.config_for_dialect(thinking.Together, thinking.EffortHigh)
  assert together_high.request == thinking.RequestEffort("high")

  let groq_high =
    thinking.config_for_dialect(thinking.Groq, thinking.EffortHigh)
  assert groq_high.request == thinking.RequestFormat("parsed")

  let groq_none =
    thinking.config_for_dialect(thinking.Groq, thinking.EffortNone)
  assert groq_none.request == thinking.RequestFormat("hidden")

  let cerebras =
    thinking.config_for_dialect(thinking.Cerebras, thinking.EffortHigh)
  assert cerebras.request == thinking.RequestFormat("parsed")

  let llama_cpp =
    thinking.config_for_dialect(thinking.LlamaCpp, thinking.EffortHigh)
  assert llama_cpp.request == thinking.RequestNone

  let generic = thinking.config_for_dialect(thinking.Tags, thinking.EffortHigh)
  assert generic.response == thinking.ResponseThinkTags
  assert generic.strip_from_content == True
}
