import envoy
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/result
import gleam/string
import jscheam/schema
import starlet
import starlet/openai_compat
import starlet/openai_compat/thinking
import unitest

pub fn simple_chat_test() -> Nil {
  use <- unitest.tag("integration")

  let api_key = envoy.get("SYNTHETIC_API_KEY") |> result.unwrap("")
  let client =
    openai_compat.new(
      "https://api.synthetic.new/openai/v1",
      api_key,
      thinking.Generic,
    )

  let chat =
    starlet.chat(client, "hf:moonshotai/Kimi-K2-Thinking")
    |> starlet.system("Reply with exactly one word.")
    |> starlet.user("Say hello")

  let assert Ok(#(_chat, turn)) = starlet.send(chat)
  let response = starlet.text(turn)

  assert string.length(response) > 0
}

pub fn json_output_test() -> Nil {
  use <- unitest.tag("integration")

  let api_key = envoy.get("SYNTHETIC_API_KEY") |> result.unwrap("")
  let client =
    openai_compat.new(
      "https://api.synthetic.new/openai/v1",
      api_key,
      thinking.Generic,
    )

  let person_schema =
    schema.object([
      schema.prop("name", schema.string()),
      schema.prop("age", schema.integer()),
      schema.prop("city", schema.string()),
    ])
    |> schema.disallow_additional_props()

  let chat =
    starlet.chat(client, "hf:moonshotai/Kimi-K2-Thinking")
    |> starlet.system(
      "You are a helpful assistant that extracts structured data.",
    )
    |> starlet.with_json_output(person_schema)
    |> starlet.user(
      "Extract the person info: John Smith is 30 years old and lives in Paris.",
    )

  let assert Ok(#(_chat, turn)) = starlet.send(chat)
  let json_string = starlet.json(turn)

  let person_decoder = {
    use name <- decode.field("name", decode.string)
    use age <- decode.field("age", decode.int)
    use city <- decode.field("city", decode.string)
    decode.success(#(name, age, city))
  }

  let assert Ok(#(name, age, city)) = json.parse(json_string, person_decoder)
  assert name == "John Smith"
  assert age == 30
  assert city == "Paris"
}

pub fn reasoning_test() -> Nil {
  use <- unitest.tag("integration")

  let api_key = envoy.get("SYNTHETIC_API_KEY") |> result.unwrap("")
  let client =
    openai_compat.new(
      "https://api.synthetic.new/openai/v1",
      api_key,
      thinking.Generic,
    )

  let chat =
    starlet.chat(client, "hf:moonshotai/Kimi-K2-Thinking")
    |> openai_compat.with_reasoning(thinking.EffortHigh)
    |> starlet.user("What is the sum of all prime numbers between 1 and 20?")

  let assert Ok(#(chat, turn1)) = starlet.send(chat)
  let response1 = starlet.text(turn1)

  assert string.length(response1) > 0
  let assert Some(_) = openai_compat.thinking(turn1)

  let chat =
    chat
    |> starlet.user("Now multiply that result by 3.")

  let assert Ok(#(_chat, turn2)) = starlet.send(chat)
  let response2 = starlet.text(turn2)

  assert string.length(response2) > 0
  let assert Some(_) = openai_compat.thinking(turn2)
  Nil
}
