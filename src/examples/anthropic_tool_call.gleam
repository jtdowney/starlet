import envoy
import examples/utils
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import starlet
import starlet/anthropic
import starlet/tool

pub fn main() {
  let api_key = envoy.get("ANTHROPIC_API_KEY") |> result.unwrap("")

  case api_key {
    "" -> io.println("Error: ANTHROPIC_API_KEY environment variable not set")
    _ -> run_example(api_key)
  }
}

fn run_example(api_key: String) {
  let client = anthropic.new(api_key)

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

  let multiply_tool =
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

  let dispatcher =
    tool.dispatch([
      tool.handler("get_weather", utils.weather_decoder(), utils.get_weather),
      tool.handler("multiply", utils.multiply_decoder(), utils.multiply),
    ])

  let result = {
    let msg1 = "What's the weather like in Paris?"
    let msg2 = "Thanks! What's 6 times 7?"
    let msg3 = "Can you summarize what you told me?"

    let chat =
      starlet.chat(client, "claude-haiku-4-5-20251001")
      |> starlet.system(
        "You are a helpful assistant. Use tools when asked about weather or multiplication.",
      )
      |> starlet.with_tools([weather_tool, multiply_tool])
      |> starlet.user(msg1)

    io.println("User: " <> msg1)
    io.println("")

    use chat <- result.try(handle_round(chat, dispatcher, 1))

    let chat = starlet.user(chat, msg2)

    io.println("User: " <> msg2)
    io.println("")

    use chat <- result.try(handle_round(chat, dispatcher, 2))

    let chat = starlet.user(chat, msg3)

    io.println("User: " <> msg3)
    io.println("")

    use _chat <- result.try(handle_round(chat, dispatcher, 3))

    Ok(Nil)
  }

  case result {
    Ok(_) -> io.println("\nConversation completed successfully!")
    Error(err) -> io.println("Error: " <> utils.error_to_string(err))
  }
}

fn handle_round(
  chat: starlet.Chat(starlet.ToolsOn, starlet.FreeText, starlet.Ready, ext),
  dispatcher: tool.Handler,
  round: Int,
) -> Result(
  starlet.Chat(starlet.ToolsOn, starlet.FreeText, starlet.Ready, ext),
  starlet.StarletError,
) {
  io.println("--- Round " <> int.to_string(round) <> " ---")

  use step <- result.try(starlet.step(chat))

  case step {
    starlet.Done(chat:, turn:) -> {
      io.println("Claude: " <> starlet.text(turn))
      Ok(chat)
    }

    starlet.ToolCall(chat:, turn: _, calls:) -> {
      io.println("Tool calls requested:")
      list.each(calls, fn(call) { io.println("  - " <> tool.to_string(call)) })

      use chat <- result.try(starlet.apply_tool_results(chat, calls, dispatcher))

      use step <- result.try(starlet.step(chat))
      case step {
        starlet.Done(chat: final_chat, turn:) -> {
          io.println("Claude: " <> starlet.text(turn))
          Ok(final_chat)
        }
        starlet.ToolCall(chat: final_chat, turn:, calls: _) -> {
          io.println(
            "Claude (partial): "
            <> starlet.text(turn)
            <> " [more tools requested]",
          )
          Ok(final_chat)
        }
      }
    }
  }
}
