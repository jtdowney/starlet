import examples/utils
import gleam/httpc
import gleam/io
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let creds = ollama.credentials("http://localhost:11434")

  let result = {
    let msg1 = "What is the capital of France?"
    let msg2 = "What is its population?"

    let chat =
      ollama.chat(creds, "qwen3:0.6b")
      |> starlet.system("You are a helpful assistant. Be concise.")
      |> starlet.user(msg1)

    use turn <- result.try(send_chat(chat, creds))
    io.println("User: " <> msg1)
    io.println("Ollama: " <> starlet.text(turn))
    io.println("")

    let chat =
      chat
      |> starlet.append_turn(turn)
      |> starlet.user(msg2)

    use turn <- result.try(send_chat(chat, creds))
    io.println("User: " <> msg2)
    io.println("Ollama: " <> starlet.text(turn))

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
