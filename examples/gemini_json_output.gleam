import envoy
import examples/utils
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/result
import gleam/string
import jscheam/schema
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
  let creds = gemini.credentials(api_key)

  let person_schema =
    schema.object([
      schema.prop("name", schema.string()),
      schema.prop("age", schema.integer()),
      schema.prop("city", schema.string()),
    ])

  let result = {
    let msg =
      "Extract the person info: John Smith is 30 years old and lives in Paris."

    let chat =
      gemini.chat(creds, "gemini-2.5-flash")
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
  chat: starlet.Chat(tools, starlet.JsonFormat, starlet.Ready, gemini.Ext),
  creds: gemini.Credentials,
) -> Result(
  starlet.Turn(tools, starlet.JsonFormat, gemini.Ext),
  starlet.StarletError,
) {
  let assert Ok(req) = gemini.request(chat, creds)
  let assert Ok(resp) = httpc.send(req)
  gemini.response(resp)
}
