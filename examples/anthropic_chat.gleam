import envoy
import examples/utils
import gleam/io
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
  let client = anthropic.new(api_key)

  let result = {
    let msg1 = "What is the capital of France?"
    let msg2 = "What is its population?"

    let chat =
      starlet.chat(client, "claude-haiku-4-5-20251001")
      |> starlet.system("You are a helpful assistant. Be concise.")
      |> starlet.user(msg1)

    use #(chat, turn) <- result.try(starlet.send(chat))
    io.println("User: " <> msg1)
    io.println("Claude: " <> starlet.text(turn))
    io.println("")

    let chat = starlet.user(chat, msg2)

    use #(_chat, turn) <- result.try(starlet.send(chat))
    io.println("User: " <> msg2)
    io.println("Claude: " <> starlet.text(turn))

    Ok(Nil)
  }

  case result {
    Ok(_) -> Nil
    Error(err) -> io.println("Error: " <> utils.error_to_string(err))
  }
}
