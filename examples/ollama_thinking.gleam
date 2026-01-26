import envoy
import examples/utils
import gleam/httpc
import gleam/io
import gleam/option.{Some}
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let base_url =
    envoy.get("OLLAMA_BASE_URL") |> result.unwrap("http://localhost:11434")

  run_example(base_url)
}

fn run_example(base_url: String) {
  let creds = ollama.credentials(base_url)

  let result = {
    let msg =
      "What is the sum of all prime numbers between 1 and 20? Think through this step by step."

    let chat =
      ollama.chat(creds, "qwen3:0.6b")
      |> ollama.with_thinking(ollama.ThinkingEnabled)
      |> starlet.user(msg)

    io.println("User: " <> msg)
    io.println("")

    use turn <- result.try(send_chat(chat, creds))

    case ollama.thinking(turn) {
      Some(thinking) -> {
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
) -> Result(starlet.Turn(tools, format, ollama.Ext), starlet.StarletError) {
  let assert Ok(req) = ollama.request(chat, creds)
  let assert Ok(resp) = httpc.send(req)
  ollama.response(resp)
}
