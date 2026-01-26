import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/option.{None, Some}
import starlet
import starlet/tool.{type ToolError}

pub fn error_to_string(err: starlet.StarletError) -> String {
  case err {
    starlet.Http(status, body) ->
      "HTTP " <> int.to_string(status) <> ": " <> body
    starlet.Decode(msg) -> "Decode error: " <> msg
    starlet.Provider(provider, msg, _raw) -> provider <> " error: " <> msg
    starlet.Tool(tool_err) ->
      case tool_err {
        tool.NotFound(name) -> "Tool not found: " <> name
        tool.InvalidArguments(msg) -> "Invalid arguments: " <> msg
        tool.ExecutionFailed(msg) -> "Tool execution failed: " <> msg
      }
    starlet.RateLimited(retry_after) ->
      case retry_after {
        Some(seconds) ->
          "Rate limited, retry after " <> int.to_string(seconds) <> "s"
        None -> "Rate limited"
      }
  }
}

pub fn weather_decoder() -> Decoder(String) {
  use city <- decode.field("city", decode.string)
  decode.success(city)
}

pub fn get_weather(city: String) -> Result(Json, ToolError) {
  let weather = case city {
    "Tokyo" ->
      json.object([
        #("temperature", json.int(18)),
        #("condition", json.string("cloudy")),
        #("humidity", json.int(65)),
      ])
    "Paris" ->
      json.object([
        #("temperature", json.int(22)),
        #("condition", json.string("sunny")),
        #("humidity", json.int(45)),
      ])
    "London" ->
      json.object([
        #("temperature", json.int(14)),
        #("condition", json.string("rainy")),
        #("humidity", json.int(80)),
      ])
    _ ->
      json.object([
        #("temperature", json.int(20)),
        #("condition", json.string("partly cloudy")),
        #("humidity", json.int(50)),
      ])
  }
  Ok(weather)
}

pub type MultiplyArgs {
  MultiplyArgs(a: Int, b: Int)
}

pub fn multiply_decoder() -> Decoder(MultiplyArgs) {
  use a <- decode.field("a", decode.int)
  use b <- decode.field("b", decode.int)
  decode.success(MultiplyArgs(a:, b:))
}

pub fn multiply(args: MultiplyArgs) -> Result(Json, ToolError) {
  Ok(json.object([#("result", json.int(args.a * args.b))]))
}

/// Tool definition for get_weather function.
pub fn weather_tool() -> tool.Definition {
  tool.function(
    name: "get_weather",
    description: "Get the current weather for a city",
    parameters: json.object([
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #(
            "city",
            json.object([
              #("type", json.string("string")),
              #("description", json.string("The city name")),
            ]),
          ),
        ]),
      ),
      #("required", json.array(["city"], json.string)),
    ]),
  )
}

/// Tool definition for multiply function.
pub fn multiply_tool() -> tool.Definition {
  tool.function(
    name: "multiply",
    description: "Multiply two integers together",
    parameters: json.object([
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #(
            "a",
            json.object([
              #("type", json.string("integer")),
              #("description", json.string("The first number")),
            ]),
          ),
          #(
            "b",
            json.object([
              #("type", json.string("integer")),
              #("description", json.string("The second number")),
            ]),
          ),
        ]),
      ),
      #("required", json.array(["a", "b"], json.string)),
    ]),
  )
}

/// Person type for JSON output examples.
pub type Person {
  Person(name: String, age: Int, city: String)
}

/// Decoder for Person type.
pub fn person_decoder() -> Decoder(Person) {
  use name <- decode.field("name", decode.string)
  use age <- decode.field("age", decode.int)
  use city <- decode.field("city", decode.string)
  decode.success(Person(name:, age:, city:))
}
