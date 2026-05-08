import envoy
import gleam/bit_array
import gleam/dynamic/decode
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/result
import starlet
import starlet/tool

pub fn weather_decoder() -> decode.Decoder(String) {
  use city <- decode.field("city", decode.string)
  decode.success(city)
}

pub fn get_weather(city: String) -> Result(Json, tool.Error) {
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

pub fn multiply_decoder() -> decode.Decoder(MultiplyArgs) {
  use a <- decode.field("a", decode.int)
  use b <- decode.field("b", decode.int)
  decode.success(MultiplyArgs(a:, b:))
}

pub fn multiply(args: MultiplyArgs) -> Result(Json, tool.Error) {
  Ok(json.object([#("result", json.int(args.a * args.b))]))
}

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

pub type Person {
  Person(name: String, age: Int, city: String)
}

pub fn person_decoder() -> decode.Decoder(Person) {
  use name <- decode.field("name", decode.string)
  use age <- decode.field("age", decode.int)
  use city <- decode.field("city", decode.string)
  decode.success(Person(name:, age:, city:))
}

pub fn format_http_error(err: httpc.HttpError) -> String {
  case err {
    httpc.UnexpectedResponse(resp) -> {
      let body = case bit_array.to_string(resp.body) {
        Ok(s) -> s
        Error(_) -> "<binary>"
      }
      "HTTP " <> int.to_string(resp.status) <> ": " <> body
    }
    httpc.FailedToConnect(_, _) -> "failed to connect"
    httpc.ResponseTimeout -> "response timed out"
    httpc.SocketClosedRemotely -> "connection closed"
    httpc.InvalidUtf8Response -> "invalid UTF-8 in response"
  }
}

pub fn require_env(var: String, then run: fn(String) -> Nil) -> Nil {
  case envoy.get(var) {
    Ok(value) -> run(value)
    Error(_) ->
      io.println_error("Error: " <> var <> " environment variable not set")
  }
}

pub fn tool_dispatcher() -> tool.Handler {
  tool.dispatch([
    tool.handler("get_weather", weather_decoder(), get_weather),
    tool.handler("multiply", multiply_decoder(), multiply),
  ])
}

pub type SendFn(ext) =
  fn(starlet.Chat(starlet.ToolsOn, starlet.FreeText, starlet.Ready, ext)) ->
    Result(starlet.Turn(starlet.ToolsOn, starlet.FreeText, ext), starlet.Error)

pub fn handle_round(
  chat: starlet.Chat(starlet.ToolsOn, starlet.FreeText, starlet.Ready, ext),
  send send: SendFn(ext),
  dispatcher dispatcher: tool.Handler,
  round round: Int,
  label label: String,
) -> Result(
  starlet.Chat(starlet.ToolsOn, starlet.FreeText, starlet.Responded, ext),
  starlet.Error,
) {
  io.println("--- Round " <> int.to_string(round) <> " ---")

  use turn <- result.try(send(chat))

  case starlet.has_tool_calls(turn) {
    False -> {
      io.println(label <> ": " <> starlet.text(turn))
      Ok(starlet.append_turn(chat, turn))
    }

    True -> {
      let calls = starlet.tool_calls(turn)
      io.println("Tool calls requested:")
      list.each(calls, fn(call) { io.println("  - " <> tool.to_string(call)) })

      let chat = starlet.append_turn(chat, turn)
      use chat <- result.try(starlet.apply_tool_results(chat, calls, dispatcher))

      use final_turn <- result.try(send(chat))
      io.println(label <> ": " <> starlet.text(final_turn))
      Ok(starlet.append_turn(chat, final_turn))
    }
  }
}
