import envoy
import gleam/json
import gleam/result
import gleam/string
import starlet
import starlet/ollama
import starlet/tool

fn guard(next: fn() -> Nil) -> Nil {
  let run = envoy.get("OLLAMA_INTEGRATION_TEST") |> result.unwrap("false")
  case run {
    "1" | "true" -> next()
    _ -> Nil
  }
}

pub fn simple_chat_test() -> Nil {
  use <- guard

  let client = ollama.new("http://localhost:11434")

  let chat =
    starlet.chat(client, "qwen3:0.6b")
    |> starlet.system("Reply with exactly one word.")
    |> starlet.user("Say hello")

  let assert Ok(#(_chat, turn)) = starlet.send(chat)
  let response = starlet.text(turn)

  assert string.length(response) > 0
}

pub fn tool_calling_test() -> Nil {
  use <- guard

  let client = ollama.new("http://localhost:11434")

  let weather_tool =
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

  let chat =
    starlet.chat(client, "qwen3:0.6b")
    |> starlet.system(
      "You are a helpful assistant. Use the get_weather tool when asked about weather.",
    )
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What is the weather in Paris?")

  let assert Ok(starlet.ToolCall(chat:, turn: _, calls:)) = starlet.step(chat)
  let assert [call] = calls
  assert call.name == "get_weather"

  let tool_result =
    tool.success(
      call,
      json.object([
        #("temperature", json.int(22)),
        #("condition", json.string("sunny")),
      ]),
    )
  let chat = starlet.with_tool_results(chat, [tool_result])

  let assert Ok(starlet.Done(chat: _, turn:)) = starlet.step(chat)
  let response = starlet.text(turn)

  assert string.length(response) > 0
}
