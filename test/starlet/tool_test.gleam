import birdie
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import starlet/tool

pub fn function_creates_definition_test() {
  let def =
    tool.function(
      name: "get_weather",
      description: "Get the weather",
      parameters: json.object([]),
    )

  let tool.Function(name, description, _params) = def
  assert name == "get_weather"
  assert description == "Get the weather"
}

pub fn success_creates_tool_result_test() {
  let call = tool.Call(id: "call_1", name: "test", arguments: dynamic.nil())
  let result = tool.success(call, json.int(42))

  assert result.id == "call_1"
  assert result.name == "test"
}

pub fn error_creates_result_with_message_test() {
  let call = tool.Call(id: "call_1", name: "test", arguments: dynamic.nil())
  let result = tool.error(call, "something went wrong")

  assert result.id == "call_1"
  assert result.name == "test"
}

pub fn dispatch_routes_to_correct_handler_test() {
  let handler =
    tool.dispatch([
      #("add", fn(call: tool.Call) {
        Ok(tool.success(call, json.string("added")))
      }),
      #("sub", fn(call: tool.Call) {
        Ok(tool.success(call, json.string("subtracted")))
      }),
    ])

  let call = tool.Call(id: "1", name: "add", arguments: dynamic.nil())
  let assert Ok(result) = handler(call)
  assert result.name == "add"
}

pub fn dispatch_returns_not_found_for_unknown_test() {
  let handler = tool.dispatch([])

  let call = tool.Call(id: "1", name: "unknown", arguments: dynamic.nil())
  let assert Error(tool.NotFound("unknown")) = handler(call)
}

pub fn handler_creates_tuple_test() {
  let #(name, _run) =
    tool.handler("my_tool", fn(_args) { Ok(json.string("ok")) })

  assert name == "my_tool"
}

pub fn handler_wraps_result_in_success_test() {
  let #(_name, run) =
    tool.handler("my_tool", fn(_args) { Ok(json.string("ok")) })

  let call = tool.Call(id: "call_1", name: "my_tool", arguments: dynamic.nil())
  let assert Ok(result) = run(call)
  assert result.id == "call_1"
  assert result.name == "my_tool"
}

pub fn handler_propagates_error_test() {
  let #(_name, run) =
    tool.handler("my_tool", fn(_args) { Error(tool.ExecutionFailed("boom")) })

  let call = tool.Call(id: "call_1", name: "my_tool", arguments: dynamic.nil())
  let assert Error(tool.ExecutionFailed("boom")) = run(call)
}

pub fn parse_arguments_decodes_valid_json_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let call = tool.Call(id: "1", name: "test", arguments:)

  let decoder = {
    use city <- decode.field("city", decode.string)
    decode.success(city)
  }

  let assert Ok("Paris") = tool.parse_arguments(call, decoder)
}

pub fn parse_arguments_returns_error_for_invalid_decode_test() {
  let assert Ok(arguments) = json.parse("123", decode.dynamic)
  let call = tool.Call(id: "1", name: "test", arguments:)

  let decoder = {
    use city <- decode.field("city", decode.string)
    decode.success(city)
  }
  let assert Error(tool.InvalidArguments(_)) =
    tool.parse_arguments(call, decoder)
}

pub fn typed_handler_decodes_arguments_test() {
  let weather_decoder = {
    use city <- decode.field("city", decode.string)
    decode.success(city)
  }

  let #(_name, handler) =
    tool.typed_handler("get_weather", weather_decoder, fn(city) {
      Ok(json.string("Weather in " <> city <> ": sunny"))
    })

  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let call = tool.Call(id: "call_123", name: "get_weather", arguments:)

  let assert Ok(result) = handler(call)
  assert result.id == "call_123"
  assert result.name == "get_weather"
}

pub fn typed_handler_returns_invalid_arguments_on_decode_error_test() {
  let weather_decoder = {
    use city <- decode.field("city", decode.string)
    decode.success(city)
  }

  let #(_name, handler) =
    tool.typed_handler("get_weather", weather_decoder, fn(_city) {
      Ok(json.string("should not reach"))
    })

  let arguments =
    json.object([#("wrong_field", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let call = tool.Call(id: "call_123", name: "get_weather", arguments:)

  let assert Error(tool.InvalidArguments(_)) = handler(call)
}

pub fn typed_handler_propagates_execution_error_test() {
  let decoder = decode.string

  let #(_name, handler) =
    tool.typed_handler("failing", decoder, fn(_val) {
      Error(tool.ExecutionFailed("something broke"))
    })

  let arguments = json.string("test") |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let call = tool.Call(id: "1", name: "failing", arguments:)

  let assert Error(tool.ExecutionFailed("something broke")) = handler(call)
}

pub fn to_string_formats_call_test() {
  let arguments =
    json.object([#("city", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let call = tool.Call(id: "call_1", name: "get_weather", arguments:)

  tool.to_string(call)
  |> birdie.snap("tool to_string formats call")
}
