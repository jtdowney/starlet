import envoy
import examples/utils
import gleam/httpc
import gleam/io
import gleam/option.{Some}
import gleam/result
import starlet
import starlet/anthropic

pub fn main() {
  let api_key = envoy.get("ANTHROPIC_API_KEY") |> result.unwrap("")

  case api_key {
    "" -> io.println("Error: ANTHROPIC_API_KEY environment variable not set")
    _ -> run_example(api_key)
  }
}

fn run_example(api_key: String) {
  let creds = anthropic.credentials(api_key)

  let result = {
    let msg =
      "What is the sum of all prime numbers between 1 and 20? Think through this step by step."

    let assert Ok(chat) =
      anthropic.chat(creds, "claude-haiku-4-5-20251001")
      |> anthropic.with_thinking(16_384)
    let chat =
      chat
      |> starlet.max_tokens(32_000)
      |> starlet.user(msg)

    io.println("User: " <> msg)
    io.println("")

    use turn <- result.try(send_chat(chat, creds))

    case anthropic.thinking(turn) {
      Some(thinking) -> {
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
) -> Result(starlet.Turn(tools, format, anthropic.Ext), starlet.StarletError) {
  let assert Ok(req) = anthropic.request(chat, creds)
  let assert Ok(resp) = httpc.send(req)
  anthropic.response(resp)
}
