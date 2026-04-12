import example_utils as utils
import gleam/httpc
import gleam/io
import gleam/option
import gleam/result
import starlet
import starlet/openai

pub fn main() {
  use api_key <- utils.require_env("OPENAI_API_KEY")
  run_example(api_key)
}

fn run_example(api_key: String) {
  let creds = openai.credentials(api_key)

  let result = {
    let msg =
      "What is the sum of all prime numbers between 1 and 20? Think through this step by step."

    let chat =
      openai.chat("gpt-5-nano")
      |> openai.with_reasoning(effort: openai.ReasoningHigh)
      |> starlet.user(msg)

    io.println("User: " <> msg)
    io.println("")

    use turn <- result.try(send_chat(chat, creds))

    case openai.reasoning_summary(turn) {
      option.Some(summary) -> {
        io.println("=== GPT's Reasoning Summary ===")
        io.println(summary)
        io.println("")
      }
      option.None -> io.println("(No reasoning summary)")
    }

    io.println("=== GPT's Response ===")
    io.println(starlet.text(turn))

    Ok(Nil)
  }

  case result {
    Ok(_) -> Nil
    Error(err) -> io.println("Error: " <> utils.error_to_string(err))
  }
}

fn send_chat(
  chat: starlet.Chat(tools, format, starlet.Ready, openai.Ext),
  creds: openai.Credentials,
) -> Result(starlet.Turn(tools, format, openai.Ext), starlet.Error) {
  let assert Ok(resp) = openai.request(chat, creds) |> httpc.send
  openai.response(chat, resp)
}
