import envoy
import examples/utils
import gleam/io
import gleam/option.{Some}
import gleam/result
import starlet
import starlet/openai

pub fn main() {
  let api_key = envoy.get("OPENAI_API_KEY") |> result.unwrap("")

  case api_key {
    "" -> io.println("Error: OPENAI_API_KEY environment variable not set")
    _ -> run_example(api_key)
  }
}

fn run_example(api_key: String) {
  let client = openai.new(api_key)

  let result = {
    let msg =
      "What is the sum of all prime numbers between 1 and 20? Think through this step by step."

    let chat =
      starlet.chat(client, "gpt-5-nano")
      |> openai.with_reasoning(openai.ReasoningHigh)
      |> starlet.user(msg)

    io.println("User: " <> msg)
    io.println("")

    use #(_chat, turn) <- result.try(starlet.send(chat))

    case openai.reasoning_summary(turn) {
      Some(summary) -> {
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
