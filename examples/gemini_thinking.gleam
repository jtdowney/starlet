import envoy
import examples/utils
import gleam/io
import gleam/option.{Some}
import gleam/result
import starlet
import starlet/gemini

pub fn main() {
  let api_key = envoy.get("GEMINI_API_KEY") |> result.unwrap("")

  case api_key {
    "" -> io.println("Error: GEMINI_API_KEY environment variable not set")
    _ -> run_example(api_key)
  }
}

fn run_example(api_key: String) {
  let client = gemini.new(api_key)

  let result = {
    let msg =
      "What is the sum of all prime numbers between 1 and 20? Think through this step by step."

    let assert Ok(chat) =
      starlet.chat(client, "gemini-2.5-flash")
      |> gemini.with_thinking(gemini.ThinkingDynamic)
    let chat = chat |> starlet.user(msg)

    io.println("User: " <> msg)
    io.println("")

    use #(_chat, turn) <- result.try(starlet.send(chat))

    case gemini.thinking(turn) {
      Some(thinking) -> {
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
