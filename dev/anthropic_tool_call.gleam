import example_utils as utils
import gleam/httpc
import gleam/io
import gleam/result
import starlet
import starlet/anthropic

pub fn main() {
  use api_key <- utils.require_env("ANTHROPIC_API_KEY")
  run_example(api_key)
}

fn run_example(api_key: String) {
  let creds = anthropic.credentials(api_key)
  let dispatcher = utils.tool_dispatcher()

  let send = fn(chat) {
    let assert Ok(resp) = anthropic.request(chat, creds) |> httpc.send
    anthropic.response(chat, resp)
  }

  let result = {
    let msg1 = "What's the weather like in Paris?"
    let msg2 = "Thanks! What's 6 times 7?"
    let msg3 = "Can you summarize what you told me?"

    let chat =
      anthropic.chat("claude-haiku-4-5-20251001")
      |> starlet.system(
        "You are a helpful assistant. Use tools when asked about weather or multiplication.",
      )
      |> starlet.with_tools([utils.weather_tool(), utils.multiply_tool()])
      |> starlet.user(msg1)

    io.println("User: " <> msg1)
    io.println("")

    use chat <- result.try(utils.handle_round(
      chat,
      send:,
      dispatcher:,
      round: 1,
      label: "Claude",
    ))

    let chat = starlet.user(chat, msg2)

    io.println("User: " <> msg2)
    io.println("")

    use chat <- result.try(utils.handle_round(
      chat,
      send:,
      dispatcher:,
      round: 2,
      label: "Claude",
    ))

    let chat = starlet.user(chat, msg3)

    io.println("User: " <> msg3)
    io.println("")

    use _chat <- result.try(utils.handle_round(
      chat,
      send:,
      dispatcher:,
      round: 3,
      label: "Claude",
    ))

    Ok(Nil)
  }

  case result {
    Ok(_) -> io.println("\nConversation completed successfully!")
    Error(err) -> io.println("Error: " <> starlet.error_to_string(err))
  }
}
