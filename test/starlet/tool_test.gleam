import birdie
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import starlet/tool

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

pub fn dynamic_handler_wraps_result_in_success_test() {
  let #(_name, run) =
    tool.dynamic_handler("my_tool", fn(_args) { Ok(json.string("ok")) })

  let call = tool.Call(id: "call_1", name: "my_tool", arguments: dynamic.nil())
  let assert Ok(result) = run(call)
  assert result.id == "call_1"
  assert result.name == "my_tool"
}

pub fn dynamic_handler_propagates_error_test() {
  let #(_name, run) =
    tool.dynamic_handler("my_tool", fn(_args) {
      Error(tool.ExecutionFailed("boom"))
    })

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

pub fn handler_decodes_arguments_test() {
  let weather_decoder = {
    use city <- decode.field("city", decode.string)
    decode.success(city)
  }

  let #(_name, handler) =
    tool.handler("get_weather", weather_decoder, fn(city) {
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

pub fn handler_returns_invalid_arguments_on_decode_error_test() {
  let weather_decoder = {
    use city <- decode.field("city", decode.string)
    decode.success(city)
  }

  let #(_name, handler) =
    tool.handler("get_weather", weather_decoder, fn(_city) {
      Ok(json.string("should not reach"))
    })

  let arguments =
    json.object([#("wrong_field", json.string("Paris"))])
    |> json.to_string
  let assert Ok(arguments) = json.parse(arguments, decode.dynamic)
  let call = tool.Call(id: "call_123", name: "get_weather", arguments:)

  let assert Error(tool.InvalidArguments(_)) = handler(call)
}

pub fn handler_propagates_execution_error_test() {
  let decoder = decode.string

  let #(_name, handler) =
    tool.handler("failing", decoder, fn(_val) {
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
