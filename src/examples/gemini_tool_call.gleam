import envoy
import examples/utils
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import starlet
import starlet/gemini
import starlet/tool

pub fn main() {
  let api_key = envoy.get("GEMINI_API_KEY") |> result.unwrap("")

  case api_key {
    "" -> io.println("Error: GEMINI_API_KEY environment variable not set")
    _ -> run_example(api_key)
  }
}

fn run_example(api_key: String) {
  let client = gemini.new(api_key)

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

  let calculator_tool =
    tool.function(
      name: "calculate",
      description: "Perform a mathematical calculation",
      parameters: json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "expression",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string("A math expression like '2 + 2' or '10 * 5'"),
                ),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["expression"], json.string)),
      ]),
    )

  let dispatcher =
    tool.dispatch([
      tool.handler("get_weather", fn(_args) {
        Ok(
          json.object([
            #("temperature", json.string("22°C")),
            #("condition", json.string("Sunny")),
            #("humidity", json.string("45%")),
          ]),
        )
      }),
      tool.handler("calculate", fn(_args) {
        Ok(json.object([#("result", json.int(42))]))
      }),
    ])

  let result = {
    let msg1 = "What's the weather like in Paris?"
    let msg2 = "Thanks! What's 6 times 7?"
    let msg3 = "Can you summarize what you told me?"

    let chat =
      starlet.chat(client, "gemini-2.5-flash")
      |> starlet.system(
        "You are a helpful assistant. Use tools when asked about weather or calculations.",
      )
      |> starlet.with_tools([weather_tool, calculator_tool])
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
      io.println("Gemini: " <> starlet.text(turn))
      Ok(chat)
    }

    starlet.ToolCall(chat:, turn: _, calls:) -> {
      io.println("Tool calls requested:")
      list.each(calls, fn(call) { io.println("  - " <> tool.to_string(call)) })

      use chat <- result.try(starlet.apply_tool_results(chat, calls, dispatcher))

      use step <- result.try(starlet.step(chat))
      case step {
        starlet.Done(chat: final_chat, turn:) -> {
          io.println("Gemini: " <> starlet.text(turn))
          Ok(final_chat)
        }
        starlet.ToolCall(chat: final_chat, turn:, calls: _) -> {
          io.println(
            "Gemini (partial): "
            <> starlet.text(turn)
            <> " [more tools requested]",
          )
          Ok(final_chat)
        }
      }
    }
  }
}
