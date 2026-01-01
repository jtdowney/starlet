//// Tool definitions and dispatch helpers for function calling.
////
//// ## Defining Tools
////
//// ```gleam
//// import gleam/json
//// import starlet/tool
////
//// let weather_tool =
////   tool.function(
////     name: "get_weather",
////     description: "Get current weather for a city",
////     parameters: json.object([
////       #("type", json.string("object")),
////       #("properties", json.object([
////         #("city", json.object([#("type", json.string("string"))])),
////       ])),
////     ]),
////   )
//// ```
////
//// ## Handling Tool Calls
////
//// ```gleam
//// let city_decoder = {
////   use city <- decode.field("city", decode.string)
////   decode.success(city)
//// }
////
//// let dispatcher = tool.dispatch([
////   tool.handler("get_weather", city_decoder, fn(city) {
////     let temp = case city {
////       "Tokyo" -> 18
////       _ -> 22
////     }
////     Ok(json.object([#("temp", json.int(temp))]))
////   }),
//// ])
//// ```

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/string

/// A tool the model can call. Currently only function tools are supported.
pub type Definition {
  Function(name: String, description: String, parameters: Json)
}

/// A tool invocation from the model's response.
/// The `arguments` field contains the parsed JSON arguments as a Dynamic value.
/// Use [`parse_arguments`](#parse_arguments) to extract typed values.
pub type Call {
  Call(id: String, name: String, arguments: Dynamic)
}

/// The result of executing a tool call.
pub type ToolResult {
  ToolResult(id: String, name: String, output: Json)
}

/// Errors that can occur during tool execution.
pub type ToolError {
  NotFound(name: String)
  InvalidArguments(message: String)
  ExecutionFailed(message: String)
}

/// A function that handles a tool call and returns a result.
pub type Handler =
  fn(Call) -> Result(ToolResult, ToolError)

/// Create a function tool definition.
pub fn function(
  name name: String,
  description description: String,
  parameters parameters: Json,
) -> Definition {
  Function(name:, description:, parameters:)
}

/// Create a successful tool result from a call.
pub fn success(call: Call, output: Json) -> ToolResult {
  ToolResult(id: call.id, name: call.name, output:)
}

/// Create an error result (encoded as JSON with error message).
pub fn error(call: Call, message: String) -> ToolResult {
  ToolResult(
    id: call.id,
    name: call.name,
    output: json.object([#("error", json.string(message))]),
  )
}

/// Create a dispatcher that routes calls to the right handler by name.
pub fn dispatch(handlers: List(#(String, Handler))) -> Handler {
  fn(call: Call) {
    let maybe_tool_call =
      list.find(handlers, fn(h) {
        let #(name, _) = h
        name == call.name
      })
    case maybe_tool_call {
      Ok(#(_, handle)) -> handle(call)
      Error(_) -> Error(NotFound(call.name))
    }
  }
}

/// Decode the arguments from a tool call into a typed value.
pub fn parse_arguments(
  call: Call,
  decoder: decode.Decoder(a),
) -> Result(a, ToolError) {
  case decode.run(call.arguments, decoder) {
    Ok(value) -> Ok(value)
    Error(errors) ->
      InvalidArguments("Failed to decode: " <> string.inspect(errors))
      |> Error
  }
}

/// Formats a tool call for display, e.g. `get_weather({"city":"Paris"})`.
/// Useful for logging and debugging.
pub fn to_string(call: Call) -> String {
  let args = json.to_string(dynamic_to_json(call.arguments))
  call.name <> "(" <> args <> ")"
}

/// Create a handler tuple from name and a function that receives Dynamic arguments.
/// For most cases, prefer `handler` which provides automatic argument decoding.
pub fn dynamic_handler(
  name: String,
  run: fn(Dynamic) -> Result(Json, ToolError),
) -> #(String, Handler) {
  #(name, fn(call: Call) {
    case run(call.arguments) {
      Ok(output) -> Ok(success(call, output))
      Error(e) -> Error(e)
    }
  })
}

/// Create a handler tuple that automatically decodes arguments to a typed value.
///
/// Example:
/// ```gleam
/// let decoder = {
///   use city <- decode.field("city", decode.string)
///   decode.success(city)
/// }
///
/// let #(name, run) =
///   tool.handler("get_weather", decoder, fn(city) {
///     Ok(json.string("Weather in " <> city))
///   })
/// ```
pub fn handler(
  name: String,
  decoder: decode.Decoder(a),
  run: fn(a) -> Result(Json, ToolError),
) -> #(String, Handler) {
  #(name, fn(call: Call) {
    case parse_arguments(call, decoder) {
      Ok(args) ->
        case run(args) {
          Ok(output) -> Ok(success(call, output))
          Error(e) -> Error(e)
        }
      Error(e) -> Error(e)
    }
  })
}

/// Convert a Dynamic value to Json for encoding.
/// Used by providers to serialize tool call arguments back to wire format.
@internal
pub fn dynamic_to_json(dyn: Dynamic) -> Json {
  let decoder =
    decode.one_of(decode.string |> decode.map(json.string), or: [
      decode.int |> decode.map(json.int),
      decode.float |> decode.map(json.float),
      decode.bool |> decode.map(json.bool),
      decode_null(),
      decode_list(),
      decode_object(),
    ])

  case decode.run(dyn, decoder) {
    Ok(j) -> j
    Error(_) -> json.null()
  }
}

fn decode_null() -> decode.Decoder(Json) {
  decode.new_primitive_decoder("null", fn(dyn) {
    case dynamic.classify(dyn) {
      "Nil" -> Ok(json.null())
      _ -> Error(json.null())
    }
  })
}

fn decode_list() -> decode.Decoder(Json) {
  use items <- decode.then(decode.list(decode.dynamic))
  decode.success(json.array(list.map(items, dynamic_to_json), fn(x) { x }))
}

fn decode_object() -> decode.Decoder(Json) {
  use d <- decode.then(decode.dict(decode.string, decode.dynamic))
  let pairs =
    dict.to_list(d)
    |> list.map(fn(p) {
      let #(k, v) = p
      #(k, dynamic_to_json(v))
    })
  decode.success(json.object(pairs))
}
