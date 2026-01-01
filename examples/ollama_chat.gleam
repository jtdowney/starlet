import examples/utils
import gleam/io
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let client = ollama.new("http://localhost:11434")

  let result = {
    let msg1 = "What is the capital of France?"
    let msg2 = "What is its population?"

    let chat =
      starlet.chat(client, "qwen3:0.6b")
      |> starlet.system("You are a helpful assistant. Be concise.")
      |> starlet.user(msg1)

    use #(chat, turn) <- result.try(starlet.send(chat))
    io.println("User: " <> msg1)
    io.println("Ollama: " <> starlet.text(turn))
    io.println("")

    let chat = starlet.user(chat, msg2)

    use #(_chat, turn) <- result.try(starlet.send(chat))
    io.println("User: " <> msg2)
    io.println("Ollama: " <> starlet.text(turn))

    Ok(Nil)
  }

  case result {
    Ok(_) -> Nil
    Error(err) -> io.println("Error: " <> utils.error_to_string(err))
  }
}
