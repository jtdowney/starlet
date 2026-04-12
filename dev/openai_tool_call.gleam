import example_utils as utils
import gleam/httpc
import gleam/io
import gleam/result
import starlet
import starlet/openai

pub fn main() {
  use api_key <- utils.require_env("OPENAI_API_KEY")
  run_example(api_key)
}

fn run_example(api_key: String) {
  let creds = openai.credentials(api_key)
  let dispatcher = utils.tool_dispatcher()

  let send = fn(chat) {
    let assert Ok(resp) = openai.request(chat, creds) |> httpc.send
    openai.response(chat, resp)
  }

  let result = {
    let msg1 = "What's the weather like in Tokyo? Also, what's 6 times 7?"
    let msg2 = "Thanks! Now what about the weather in Paris?"
    let msg3 = "Can you summarize what you told me?"

    let chat =
      openai.chat("gpt-5-nano")
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
      label: "GPT",
    ))

    let chat = starlet.user(chat, msg2)

    io.println("User: " <> msg2)
    io.println("")

    use chat <- result.try(utils.handle_round(
      chat,
      send:,
      dispatcher:,
      round: 2,
      label: "GPT",
    ))

    let chat = starlet.user(chat, msg3)

    io.println("User: " <> msg3)
    io.println("")

    use _chat <- result.try(utils.handle_round(
      chat,
      send:,
      dispatcher:,
      round: 3,
      label: "GPT",
    ))

    Ok(Nil)
  }

  case result {
    Ok(_) -> io.println("\nConversation completed successfully!")
    Error(err) -> io.println("Error: " <> utils.error_to_string(err))
  }
}
