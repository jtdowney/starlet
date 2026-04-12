import example_utils as utils
import gleam/httpc
import gleam/io
import gleam/option
import gleam/result
import starlet
import starlet/gemini

pub fn main() {
  use api_key <- utils.require_env("GEMINI_API_KEY")
  run_example(api_key)
}

fn run_example(api_key: String) {
  let creds = gemini.credentials(api_key)

  let result = {
    let msg =
      "What is the sum of all prime numbers between 1 and 20? Think through this step by step."

    let assert Ok(chat) =
      gemini.chat("gemini-2.5-flash")
      |> gemini.with_thinking(budget: gemini.ThinkingDynamic)
    let chat = chat |> starlet.user(msg)

    io.println("User: " <> msg)
    io.println("")

    use turn <- result.try(send_chat(chat, creds))

    case gemini.thinking(turn) {
      option.Some(thinking) -> {
        io.println("=== Gemini's Thinking ===")
        io.println(thinking)
        io.println("")
      }
      option.None -> io.println("(No thinking content)")
    }

    io.println("=== Gemini's Response ===")
    io.println(starlet.text(turn))

    Ok(Nil)
  }

  case result {
    Ok(_) -> Nil
    Error(err) -> io.println("Error: " <> utils.error_to_string(err))
  }
}

fn send_chat(
  chat: starlet.Chat(tools, format, starlet.Ready, gemini.Ext),
  creds: gemini.Credentials,
) -> Result(starlet.Turn(tools, format, gemini.Ext), starlet.Error) {
  let assert Ok(resp) = gemini.request(chat, creds) |> httpc.send
  gemini.response(chat, resp)
}
