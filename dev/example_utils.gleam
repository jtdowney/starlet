import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/option.{None, Some}
import starlet
import starlet/tool.{type ToolError}

pub fn error_to_string(err: starlet.StarletError) -> String {
  case err {
    starlet.Transport(msg) -> "Transport error: " <> msg
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
