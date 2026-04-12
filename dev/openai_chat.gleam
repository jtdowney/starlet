import example_utils as utils
import gleam/httpc
import gleam/io
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
    let msg1 = "What is the capital of France?"
    let msg2 = "What is its population?"

    let chat =
      openai.chat("gpt-5-nano")
      |> starlet.system("You are a helpful assistant. Be concise.")
      |> starlet.user(msg1)

    use turn <- result.try(send_chat(chat, creds))
    io.println("User: " <> msg1)
    io.println("GPT: " <> starlet.text(turn))
    io.println("")

    let chat =
      chat
      |> starlet.append_turn(turn)
      |> starlet.user(msg2)

    use turn <- result.try(send_chat(chat, creds))
    io.println("User: " <> msg2)
    io.println("GPT: " <> starlet.text(turn))

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
