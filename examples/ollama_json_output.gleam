import examples/utils
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/result
import gleam/string
import jscheam/schema
import starlet
import starlet/ollama

pub type Person {
  Person(name: String, age: Int, city: String)
}

fn person_decoder() -> decode.Decoder(Person) {
  use name <- decode.field("name", decode.string)
  use age <- decode.field("age", decode.int)
  use city <- decode.field("city", decode.string)
  decode.success(Person(name:, age:, city:))
}

pub fn main() {
  let client = ollama.new("http://localhost:11434")

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
      starlet.chat(client, "qwen3:0.6b")
      |> starlet.system(
        "You are a helpful assistant that extracts structured data.",
      )
      |> starlet.with_json_output(person_schema)
      |> starlet.user(msg)

    io.println("User: " <> msg)
    io.println("")

    use #(_chat, turn) <- result.try(starlet.send(chat))

    let json_string = starlet.json(turn)
    io.println("Raw JSON: " <> json_string)
    io.println("")

    case json.parse(json_string, person_decoder()) {
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
