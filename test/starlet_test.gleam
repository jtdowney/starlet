import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import jscheam/schema
import starlet
import starlet/tool
import unitest

pub fn main() -> Nil {
  unitest.run(
    unitest.Options(..unitest.default_options(), ignored_tags: ["integration"]),
  )
}

pub fn turn_text_accessor_test() {
  let turn = starlet.make_turn_for_testing("Hello world")
  assert starlet.text(turn) == "Hello world"
}

pub fn append_turn_adds_assistant_message_test() {
  let chat =
    starlet.new_chat("test-model", Nil)
    |> starlet.user("Hello")

  let turn = starlet.Turn(text: "Hi there!", tool_calls: [], ext: Nil)

  let chat = starlet.append_turn(chat, turn)

  assert chat.messages
    == [starlet.UserMessage("Hello"), starlet.AssistantMessage("Hi there!", [])]
}

pub fn system_prompt_sets_before_messages_test() {
  let chat =
    starlet.new_chat("test-model", Nil)
    |> starlet.system("Be helpful")
    |> starlet.user("Hello")

  assert chat.system_prompt == option.Some("Be helpful")
}

pub fn temperature_is_set_test() {
  let chat =
    starlet.new_chat("test-model", Nil)
    |> starlet.temperature(0.7)
    |> starlet.user("Hello")

  assert chat.temperature == option.Some(0.7)
}

pub fn max_tokens_is_set_test() {
  let chat =
    starlet.new_chat("test-model", Nil)
    |> starlet.max_tokens(500)
    |> starlet.user("Hello")

  assert chat.max_tokens == option.Some(500)
}

pub fn assistant_adds_few_shot_example_test() {
  let chat =
    starlet.new_chat("test-model", Nil)
    |> starlet.user("What is 2+2?")
  let chat =
    starlet.Chat(
      ..chat,
      messages: list.append(chat.messages, [starlet.AssistantMessage("4", [])]),
    )
  let chat = starlet.user(chat, "What is 3+3?")

  assert chat.messages
    == [
      starlet.UserMessage("What is 2+2?"),
      starlet.AssistantMessage("4", []),
      starlet.UserMessage("What is 3+3?"),
    ]
}

pub fn has_tool_calls_true_test() {
  let turn =
    starlet.Turn(
      text: "",
      tool_calls: [tool.Call(id: "1", name: "test", arguments: dynamic.nil())],
      ext: Nil,
    )
  assert starlet.has_tool_calls(turn) == True
}

pub fn has_tool_calls_false_test() {
  let turn: starlet.Turn(starlet.ToolsOn, starlet.FreeText, Nil) =
    starlet.Turn(text: "Hello", tool_calls: [], ext: Nil)
  assert starlet.has_tool_calls(turn) == False
}

pub fn apply_tool_results_with_failing_tool_test() {
  let chat =
    starlet.new_chat("test-model", Nil)
    |> starlet.with_tools([])
    |> starlet.user("test")

  let call = tool.Call(id: "1", name: "broken", arguments: dynamic.nil())
  let turn = starlet.Turn(text: "", tool_calls: [call], ext: chat.ext)
  let chat = starlet.append_turn(chat, turn)
  let result =
    starlet.apply_tool_results(chat, calls: [call], with: fn(_call) {
      Error(tool.ExecutionFailed("boom"))
    })
  let assert Error(starlet.Tool(tool.ExecutionFailed("boom"))) = result
}

pub fn with_json_output_transitions_format_test() {
  let chat =
    starlet.new_chat("test-model", Nil)
    |> starlet.with_json_output(
      schema.object([
        schema.prop("name", schema.String),
      ]),
    )
    |> starlet.user("Give me a name")

  let assert option.Some(_) = chat.json_schema
}

pub fn with_free_text_clears_schema_test() {
  let chat =
    starlet.new_chat("test-model", Nil)
    |> starlet.with_json_output(
      schema.object([
        schema.prop("name", schema.String),
      ]),
    )
    |> starlet.with_free_text

  assert chat.json_schema == option.None
}

pub fn tools_accessor_returns_definitions_test() {
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
    starlet.new_chat("test-model", Nil)
    |> starlet.with_tools([weather_tool])

  assert starlet.tools(chat) == [weather_tool]
}

pub fn tool_calls_accessor_returns_list_test() {
  let call = tool.Call(id: "1", name: "test", arguments: dynamic.nil())
  let turn: starlet.Turn(starlet.ToolsOn, starlet.FreeText, Nil) =
    starlet.Turn(text: "", tool_calls: [call], ext: Nil)
  assert starlet.tool_calls(turn) == [call]
}

pub fn json_accessor_extracts_content_test() {
  let turn: starlet.Turn(starlet.ToolsOff, starlet.JsonFormat, Nil) =
    starlet.Turn(text: "{\"name\":\"Alice\"}", tool_calls: [], ext: Nil)
  assert starlet.json(turn) == "{\"name\":\"Alice\"}"
}

pub fn with_tool_results_adds_messages_test() {
  let chat =
    starlet.new_chat("test-model", Nil)
    |> starlet.with_tools([])
    |> starlet.user("test")

  let results = [
    tool.ToolResult(
      id: "call_1",
      name: "get_weather",
      output: json.object([#("temp", json.int(22))]),
    ),
  ]

  let turn = starlet.Turn(text: "", tool_calls: [], ext: chat.ext)
  let chat = starlet.append_turn(chat, turn)
  let chat = starlet.with_tool_results(chat, results: results)

  let assert [
    starlet.UserMessage("test"),
    starlet.AssistantMessage(_, _),
    starlet.ToolResultMessage("call_1", "get_weather", _),
  ] = chat.messages
}

pub fn apply_tool_results_happy_path_test() {
  let chat =
    starlet.new_chat("test-model", Nil)
    |> starlet.with_tools([])
    |> starlet.user("test")

  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let call = tool.Call(id: "call_1", name: "get_weather", arguments:)

  let turn = starlet.Turn(text: "", tool_calls: [call], ext: chat.ext)
  let chat = starlet.append_turn(chat, turn)
  let result =
    starlet.apply_tool_results(chat, calls: [call], with: fn(call) {
      Ok(tool.success(call, json.object([#("temp", json.int(22))])))
    })

  let assert Ok(chat) = result
  let assert [
    starlet.UserMessage("test"),
    starlet.AssistantMessage(_, _),
    starlet.ToolResultMessage(_, _, _),
  ] = chat.messages
}

pub fn map_transport_error_passes_through_success_test() {
  let result: Result(String, String) = Ok("response")
  let assert Ok(value) = starlet.map_transport_error(result)
  assert value == "response"
}

pub fn map_transport_error_converts_error_to_transport_test() {
  let result: Result(String, String) = Error("connection refused")
  let assert Error(starlet.Transport(message)) =
    starlet.map_transport_error(result)
  assert message == "\"connection refused\""
}
