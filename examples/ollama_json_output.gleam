import examples/utils
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/result
import gleam/string
import jscheam/schema
import starlet
import starlet/ollama

pub fn main() {
  let creds = ollama.credentials("http://localhost:11434")

  let person_schema =
    schema.object([
      schema.prop("name", schema.string()),
      schema.prop("age", schema.integer()),
      schema.prop("city", schema.string()),
    ])
    |> schema.disallow_additional_props()

  let result = {
    let msg =
      "Extract the person info: John Smith is 30 years old and lives in Paris."

    let chat =
      ollama.chat(creds, "qwen3:0.6b")
      |> starlet.system(
        "You are a helpful assistant that extracts structured data.",
      )
      |> starlet.with_json_output(person_schema)
      |> starlet.user(msg)

    io.println("User: " <> msg)
    io.println("")

    use turn <- result.try(send_chat(chat, creds))

    let json_string = starlet.json(turn)
    io.println("Raw JSON: " <> json_string)
    io.println("")

    case json.parse(json_string, utils.person_decoder()) {
      Ok(person) -> {
        io.println("Parsed person:")
        io.println("  Name: " <> person.name)
        io.println("  Age: " <> int.to_string(person.age))
        io.println("  City: " <> person.city)
        Ok(Nil)
      }
      Error(err) -> {
        io.println("Failed to parse JSON: " <> string.inspect(err))
        Ok(Nil)
      }
    }
  }

  case result {
    Ok(_) -> Nil
    Error(err) -> io.println("Error: " <> utils.error_to_string(err))
  }
}

fn send_chat(
  chat: starlet.Chat(tools, starlet.JsonFormat, starlet.Ready, ollama.Ext),
  creds: ollama.Credentials,
) -> Result(
  starlet.Turn(tools, starlet.JsonFormat, ollama.Ext),
  starlet.StarletError,
) {
  let assert Ok(req) = ollama.request(chat, creds)
  let assert Ok(resp) = httpc.send(req)
  ollama.response(resp)
}
