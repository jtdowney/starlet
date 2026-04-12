import birdie
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import qcheck
import starlet/tool

fn make_arguments(pairs: List(#(String, Json))) -> Dynamic {
  let assert Ok(arguments) =
    json.object(pairs) |> json.to_string |> json.parse(decode.dynamic)
  arguments
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

pub fn dynamic_handler_wraps_result_in_success_test() {
  let #(name, run) =
    tool.dynamic_handler("my_tool", fn(_args) { Ok(json.string("ok")) })

  let call = tool.Call(id: "call_1", name: "my_tool", arguments: dynamic.nil())
  let assert Ok(result) = run(call)
  assert name == "my_tool"
  assert result.id == "call_1"
  assert result.name == "my_tool"
  assert result.output == json.string("ok")
}

pub fn dynamic_handler_propagates_error_test() {
  let #(_name, run) =
    tool.dynamic_handler("my_tool", fn(_args) {
      Error(tool.ExecutionFailed("boom"))
    })

  let call = tool.Call(id: "call_1", name: "my_tool", arguments: dynamic.nil())
  let assert Error(tool.ExecutionFailed("boom")) = run(call)
}

pub fn handler_decodes_arguments_test() {
  let weather_decoder = {
    use city <- decode.field("city", decode.string)
    decode.success(city)
  }

  let #(name, handler) =
    tool.handler("get_weather", weather_decoder, fn(city) {
      Ok(json.string("Weather in " <> city <> ": sunny"))
    })

  let arguments = make_arguments([#("city", json.string("Paris"))])
  let call = tool.Call(id: "call_123", name: "get_weather", arguments:)

  let assert Ok(result) = handler(call)
  assert name == "get_weather"
  assert result.id == "call_123"
  assert result.name == "get_weather"
  assert result.output == json.string("Weather in Paris: sunny")
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

  let arguments = make_arguments([#("wrong_field", json.string("Paris"))])
  let call = tool.Call(id: "call_123", name: "get_weather", arguments:)

  let assert Error(tool.InvalidArguments(_)) = handler(call)
}

pub fn handler_propagates_execution_error_test() {
  let decoder = decode.string

  let #(_name, handler) =
    tool.handler("failing", decoder, fn(_val) {
      Error(tool.ExecutionFailed("something broke"))
    })

  let assert Ok(arguments) =
    json.string("test") |> json.to_string |> json.parse(decode.dynamic)
  let call = tool.Call(id: "1", name: "failing", arguments:)

  let assert Error(tool.ExecutionFailed("something broke")) = handler(call)
}

pub fn to_string_formats_call_test() {
  let arguments = make_arguments([#("city", json.string("Paris"))])
  let call = tool.Call(id: "call_1", name: "get_weather", arguments:)

  tool.to_string(call)
  |> birdie.snap("tool to_string formats call")
}

pub fn tool_error_test() {
  let call = tool.Call(id: "call_1", name: "my_tool", arguments: dynamic.nil())
  let result = tool.error(call, "something went wrong")
  assert result.id == "call_1"
  assert result.name == "my_tool"
  assert result.output
    == json.object([#("error", json.string("something went wrong"))])
}

pub fn dynamic_to_json_roundtrips_strings_test() {
  use string_value <- qcheck.given(qcheck.string())
  let original = json.to_string(json.string(string_value))
  let assert Ok(dyn) = json.parse(original, decode.dynamic)
  let roundtripped = json.to_string(tool.dynamic_to_json(dyn))
  assert original == roundtripped
}

pub fn dynamic_to_json_roundtrips_ints_test() {
  use int_value <- qcheck.given(qcheck.uniform_int())
  let original = json.to_string(json.int(int_value))
  let assert Ok(dyn) = json.parse(original, decode.dynamic)
  let roundtripped = json.to_string(tool.dynamic_to_json(dyn))
  assert original == roundtripped
}

pub fn dynamic_to_json_roundtrips_floats_test() {
  use float_value <- qcheck.given(qcheck.float())
  let original = json.to_string(json.float(float_value))
  let assert Ok(dyn) = json.parse(original, decode.dynamic)
  let roundtripped = json.to_string(tool.dynamic_to_json(dyn))
  assert original == roundtripped
}

pub fn dynamic_to_json_roundtrips_objects_test() {
  use string_value <- qcheck.given(qcheck.string())
  let original =
    json.to_string(
      json.object([#("key", json.string(string_value)), #("n", json.int(42))]),
    )
  let assert Ok(dyn) = json.parse(original, decode.dynamic)
  let roundtripped = json.to_string(tool.dynamic_to_json(dyn))
  assert original == roundtripped
}

pub fn dynamic_to_json_null_test() {
  let original = json.to_string(json.null())
  let assert Ok(dyn) = json.parse(original, decode.dynamic)
  let roundtripped = json.to_string(tool.dynamic_to_json(dyn))
  assert original == roundtripped
}

pub fn dynamic_to_json_bool_test() {
  let original = json.to_string(json.bool(True))
  let assert Ok(dyn) = json.parse(original, decode.dynamic)
  let roundtripped = json.to_string(tool.dynamic_to_json(dyn))
  assert original == roundtripped
}

pub fn dynamic_to_json_array_test() {
  let original =
    json.to_string(json.preprocessed_array([json.int(1), json.string("two")]))
  let assert Ok(dyn) = json.parse(original, decode.dynamic)
  let roundtripped = json.to_string(tool.dynamic_to_json(dyn))
  assert original == roundtripped
}
