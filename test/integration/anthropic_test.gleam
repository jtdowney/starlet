import envoy
import gleam/dynamic/decode
import gleam/httpc
import gleam/json
import gleam/option.{Some}
import gleam/result
import gleam/string
import jscheam/schema
import starlet
import starlet/anthropic
import starlet/tool
import unitest

fn send_chat(
  chat: starlet.Chat(tools, format, starlet.Ready, anthropic.Ext),
  creds: anthropic.Credentials,
) -> Result(starlet.Turn(tools, format, anthropic.Ext), starlet.StarletError) {
  let assert Ok(req) = anthropic.request(chat, creds)
  let assert Ok(resp) = httpc.send(req)
  anthropic.response(resp)
}

pub fn simple_chat_test() -> Nil {
  use <- unitest.tag("integration")

  let api_key = envoy.get("ANTHROPIC_API_KEY") |> result.unwrap("")
  let creds = anthropic.credentials(api_key)

  let chat =
    anthropic.chat(creds, "claude-haiku-4-5-20251001")
    |> starlet.system("Reply with exactly one word.")
    |> starlet.user("Say hello")

  let assert Ok(turn) = send_chat(chat, creds)
  let response = starlet.text(turn)

  assert string.length(response) > 0
}

pub fn tool_calling_test() -> Nil {
  use <- unitest.tag("integration")

  let api_key = envoy.get("ANTHROPIC_API_KEY") |> result.unwrap("")
  let creds = anthropic.credentials(api_key)

  let weather_tool =
    tool.function(
      name: "get_weather",
      description: "Get the current weather for a city",
      parameters: json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "city",
              json.object([
                #("type", json.string("string")),
                #("description", json.string("The city name")),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["city"], json.string)),
      ]),
    )

  let chat =
    anthropic.chat(creds, "claude-haiku-4-5-20251001")
    |> starlet.system(
      "You are a helpful assistant. Use the get_weather tool when asked about weather.",
    )
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What is the weather in Paris?")

  let assert Ok(turn) = send_chat(chat, creds)
  let calls = starlet.tool_calls(turn)
  let assert [call] = calls
  assert call.name == "get_weather"

  let tool_result =
    tool.success(
      call,
      json.object([
        #("temperature", json.int(22)),
        #("condition", json.string("sunny")),
      ]),
    )
  let chat = starlet.append_turn(chat, turn)
  let chat = starlet.with_tool_results(chat, [tool_result])

  let assert Ok(turn) = send_chat(chat, creds)
  let response = starlet.text(turn)

  assert string.length(response) > 0
}

pub fn json_output_test() -> Nil {
  use <- unitest.tag("integration")

  let api_key = envoy.get("ANTHROPIC_API_KEY") |> result.unwrap("")
  let creds = anthropic.credentials(api_key)

  let person_schema =
    schema.object([
      schema.prop("name", schema.string()),
      schema.prop("age", schema.integer()),
      schema.prop("city", schema.string()),
    ])
    |> schema.disallow_additional_props()

  let chat =
    anthropic.chat(creds, "claude-haiku-4-5-20251001")
    |> starlet.system(
      "You are a helpful assistant that extracts structured data.",
    )
    |> starlet.with_json_output(person_schema)
    |> starlet.user(
      "Extract the person info: John Smith is 30 years old and lives in Paris.",
    )

  let assert Ok(turn) = send_chat(chat, creds)
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

pub fn thinking_test() -> Nil {
  use <- unitest.tag("integration")

  let api_key = envoy.get("ANTHROPIC_API_KEY") |> result.unwrap("")
  let creds = anthropic.credentials(api_key)

  let assert Ok(chat) =
    anthropic.chat(creds, "claude-haiku-4-5-20251001")
    |> anthropic.with_thinking(16_384)
  let chat =
    chat
    |> starlet.max_tokens(32_000)
    |> starlet.user("What is the sum of all prime numbers between 1 and 20?")

  let assert Ok(turn) = send_chat(chat, creds)
  let response = starlet.text(turn)

  assert string.length(response) > 0
  let assert Some(_) = anthropic.thinking(turn)
  Nil
}
