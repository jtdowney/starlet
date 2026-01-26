import envoy
import examples/utils
import gleam/httpc
import gleam/int
import gleam/io
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
  let creds = anthropic.credentials(api_key)

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
      anthropic.chat(creds, "claude-haiku-4-5-20251001")
      |> starlet.system(
        "You are a helpful assistant. Use tools when asked about weather or multiplication.",
      )
      |> starlet.with_tools([utils.weather_tool(), utils.multiply_tool()])
      |> starlet.user(msg1)

    io.println("User: " <> msg1)
    io.println("")

    use chat <- result.try(handle_round(chat, creds, dispatcher, 1))

    let chat = starlet.user(chat, msg2)

    io.println("User: " <> msg2)
    io.println("")

    use chat <- result.try(handle_round(chat, creds, dispatcher, 2))

    let chat = starlet.user(chat, msg3)

    io.println("User: " <> msg3)
    io.println("")

    use _chat <- result.try(handle_round(chat, creds, dispatcher, 3))

    Ok(Nil)
  }

  case result {
    Ok(_) -> io.println("\nConversation completed successfully!")
    Error(err) -> io.println("Error: " <> utils.error_to_string(err))
  }
}

fn handle_round(
  chat: starlet.Chat(
    starlet.ToolsOn,
    starlet.FreeText,
    starlet.Ready,
    anthropic.Ext,
  ),
  creds: anthropic.Credentials,
  dispatcher: tool.Handler,
  round: Int,
) -> Result(
  starlet.Chat(starlet.ToolsOn, starlet.FreeText, starlet.Ready, anthropic.Ext),
  starlet.StarletError,
) {
  io.println("--- Round " <> int.to_string(round) <> " ---")

  use turn <- result.try(send_chat(chat, creds))

  case starlet.has_tool_calls(turn) {
    False -> {
      io.println("Claude: " <> starlet.text(turn))
      Ok(starlet.append_turn(chat, turn))
    }

    True -> {
      let calls = starlet.tool_calls(turn)
      io.println("Tool calls requested:")
      list.each(calls, fn(call) { io.println("  - " <> tool.to_string(call)) })

      let chat = starlet.append_turn(chat, turn)
      use chat <- result.try(starlet.apply_tool_results(chat, calls, dispatcher))

      use final_turn <- result.try(send_chat(chat, creds))
      io.println("Claude: " <> starlet.text(final_turn))
      Ok(starlet.append_turn(chat, final_turn))
    }
  }
}

fn send_chat(
  chat: starlet.Chat(
    starlet.ToolsOn,
    starlet.FreeText,
    starlet.Ready,
    anthropic.Ext,
  ),
  creds: anthropic.Credentials,
) -> Result(
  starlet.Turn(starlet.ToolsOn, starlet.FreeText, anthropic.Ext),
  starlet.StarletError,
) {
  let assert Ok(req) = anthropic.request(chat, creds)
  let assert Ok(resp) = httpc.send(req)
  anthropic.response(resp)
}
