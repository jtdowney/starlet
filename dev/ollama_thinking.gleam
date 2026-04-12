import example_utils as utils
import gleam/httpc
import gleam/io
import gleam/option
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

  let result = {
    let msg =
      "What is the sum of all prime numbers between 1 and 20? Think through this step by step."

    let chat =
      ollama.chat("qwen3:0.6b")
      |> ollama.with_thinking(mode: ollama.ThinkingOn)
      |> starlet.user(msg)

    io.println("User: " <> msg)
    io.println("")

    use turn <- result.try(send_chat(chat, creds))

    case ollama.thinking(turn) {
      option.Some(thinking) -> {
        io.println("=== Model's Thinking ===")
        io.println(thinking)
        io.println("")
      }
      option.None -> io.println("(No thinking content)")
    }

    io.println("=== Model's Response ===")
    io.println(starlet.text(turn))

    Ok(Nil)
  }

  case result {
    Ok(_) -> Nil
    Error(err) -> io.println("Error: " <> utils.error_to_string(err))
  }
}

fn send_chat(
  chat: starlet.Chat(tools, format, starlet.Ready, ollama.Ext),
  creds: ollama.Credentials,
) -> Result(starlet.Turn(tools, format, ollama.Ext), starlet.Error) {
  let assert Ok(resp) = ollama.request(chat, creds) |> httpc.send
  ollama.response(chat, resp)
}
