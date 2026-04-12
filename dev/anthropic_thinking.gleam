import example_utils as utils
import gleam/httpc
import gleam/io
import gleam/option
import gleam/result
import starlet
import starlet/anthropic

pub fn main() {
  use api_key <- utils.require_env("ANTHROPIC_API_KEY")
  run_example(api_key)
}

fn run_example(api_key: String) {
  let creds = anthropic.credentials(api_key)

  let result = {
    let msg =
      "What is the sum of all prime numbers between 1 and 20? Think through this step by step."

    let assert Ok(chat) =
      anthropic.chat("claude-haiku-4-5-20251001")
      |> anthropic.with_thinking(budget: 16_384)
    let chat =
      chat
      |> starlet.max_tokens(32_000)
      |> starlet.user(msg)

    io.println("User: " <> msg)
    io.println("")

    use turn <- result.try(send_chat(chat, creds))

    case anthropic.thinking(turn) {
      option.Some(thinking) -> {
        io.println("=== Claude's Thinking ===")
        io.println(thinking)
        io.println("")
      }
      option.None -> io.println("(No thinking content)")
    }

    io.println("=== Claude's Response ===")
    io.println(starlet.text(turn))

    Ok(Nil)
  }

  case result {
    Ok(_) -> Nil
    Error(err) -> io.println("Error: " <> utils.error_to_string(err))
  }
}

fn send_chat(
  chat: starlet.Chat(tools, format, starlet.Ready, anthropic.Ext),
  creds: anthropic.Credentials,
) -> Result(starlet.Turn(tools, format, anthropic.Ext), starlet.Error) {
  let assert Ok(resp) = anthropic.request(chat, creds) |> httpc.send
  anthropic.response(chat, resp)
}
