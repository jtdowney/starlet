import example_utils as utils
import gleam/httpc
import gleam/io
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")
  let dispatcher = utils.tool_dispatcher()

  let send = fn(chat) {
    let assert Ok(resp) = ollama.request(chat, creds) |> httpc.send
    ollama.response(chat, resp)
  }

  let result = {
    let msg1 = "What's the weather like in Paris?"
    let msg2 = "Thanks! What's 6 times 7?"
    let msg3 = "Can you summarize what you told me?"

    let chat =
      ollama.chat("qwen3:0.6b")
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
      label: "Ollama",
    ))

    let chat = starlet.user(chat, msg2)

    io.println("User: " <> msg2)
    io.println("")

    use chat <- result.try(utils.handle_round(
      chat,
      send:,
      dispatcher:,
      round: 2,
      label: "Ollama",
    ))

    let chat = starlet.user(chat, msg3)

    io.println("User: " <> msg3)
    io.println("")

    use _chat <- result.try(utils.handle_round(
      chat,
      send:,
      dispatcher:,
      round: 3,
      label: "Ollama",
    ))

    Ok(Nil)
  }

  case result {
    Ok(_) -> io.println("\nConversation completed successfully!")
    Error(err) -> io.println("Error: " <> utils.error_to_string(err))
  }
}
