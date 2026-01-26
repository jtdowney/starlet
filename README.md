# starlet

[![Package Version](https://img.shields.io/hexpm/v/starlet)](https://hex.pm/packages/starlet)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/starlet/)

A unified, provider-agnostic interface for LLM APIs in Gleam.

Starlet uses a **sans-IO architecture**: it provides pure functions for building HTTP requests and decoding responses, but never performs IO itself. Bring your own HTTP client.

## Installation

```sh
gleam add starlet
```

## Quick Start

```gleam
import gleam/httpc
import gleam/io
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let creds = ollama.credentials("http://localhost:11434")

  let chat =
    ollama.chat(creds, "qwen3:0.6b")
    |> starlet.system("You are a helpful assistant.")
    |> starlet.user("What is the capital of France?")

  let assert Ok(req) = ollama.request(chat, creds)
  let assert Ok(resp) = httpc.send(req)

  case ollama.response(resp) {
    Ok(turn) -> io.println(starlet.text(turn))
    Error(_) -> io.println("Request failed")
  }
}
```

## Features

- **Sans-IO design**: Pure request/response functions — use any HTTP client
- **Tool use**: Function calling with automatic dispatch
- **Structured output**: JSON responses with schema validation
- **Reasoning**: Extended thinking for supported models
- **Cross-platform**: Works on Erlang and JavaScript targets

## Missing Features

- Streaming responses
- Image inputs
- Provider built-in tools (web search, code execution)

## Supported Providers

- **Ollama** — `starlet/ollama`
- **OpenAI** — `starlet/openai`
- **Anthropic** — `starlet/anthropic`
- **Google Gemini** — `starlet/gemini`

## Examples

### Multi-turn Conversations

```gleam
import gleam/httpc
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let creds = ollama.credentials("http://localhost:11434")

  let result = {
    let chat =
      ollama.chat(creds, "qwen3:0.6b")
      |> starlet.user("Hello!")

    use turn <- result.try(send_chat(chat, creds))

    let chat =
      chat
      |> starlet.append_turn(turn)
      |> starlet.user("How are you?")

    use turn <- result.try(send_chat(chat, creds))

    Ok(starlet.text(turn))
  }
}

fn send_chat(chat, creds) {
  let assert Ok(req) = ollama.request(chat, creds)
  let assert Ok(resp) = httpc.send(req)
  ollama.response(resp)
}
```

### Tool Calling

```gleam
import gleam/dynamic/decode
import gleam/httpc
import gleam/json
import gleam/list
import gleam/result
import starlet
import starlet/ollama
import starlet/tool

pub fn main() {
  let creds = ollama.credentials("http://localhost:11434")

  let weather_tool =
    tool.function(
      name: "get_weather",
      description: "Get weather for a city",
      parameters: json.object([
        #("type", json.string("object")),
        #("properties", json.object([
          #("city", json.object([#("type", json.string("string"))])),
        ])),
      ]),
    )

  let city_decoder = {
    use city <- decode.field("city", decode.string)
    decode.success(city)
  }

  let dispatcher =
    tool.dispatch([
      tool.handler("get_weather", city_decoder, fn(city) {
        Ok(json.object([
          #("temp", json.int(22)),
          #("condition", json.string("sunny in " <> city)),
        ]))
      }),
    ])

  let chat =
    ollama.chat(creds, "qwen3:0.6b")
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What's the weather in Tokyo?")

  let assert Ok(turn) = send_chat(chat, creds)

  case starlet.has_tool_calls(turn) {
    False -> starlet.text(turn)
    True -> {
      let calls = starlet.tool_calls(turn)
      let chat = starlet.append_turn(chat, turn)
      let assert Ok(chat) = starlet.apply_tool_results(chat, calls, dispatcher)

      let assert Ok(turn) = send_chat(chat, creds)
      starlet.text(turn)
    }
  }
}

fn send_chat(chat, creds) {
  let assert Ok(req) = ollama.request(chat, creds)
  let assert Ok(resp) = httpc.send(req)
  ollama.response(resp)
}
```

### Structured JSON Output

```gleam
import gleam/dynamic/decode
import gleam/httpc
import gleam/json
import gleam/result
import jscheam/schema
import starlet
import starlet/ollama

pub type Person {
  Person(name: String, age: Int)
}

fn person_decoder() -> decode.Decoder(Person) {
  use name <- decode.field("name", decode.string)
  use age <- decode.field("age", decode.int)
  decode.success(Person(name:, age:))
}

pub fn main() {
  let creds = ollama.credentials("http://localhost:11434")

  let person_schema =
    schema.object([
      schema.prop("name", schema.string()),
      schema.prop("age", schema.integer()),
    ])

  let chat =
    ollama.chat(creds, "qwen3:0.6b")
    |> starlet.with_json_output(person_schema)
    |> starlet.user("Extract: Alice is 30 years old.")

  let assert Ok(req) = ollama.request(chat, creds)
  let assert Ok(resp) = httpc.send(req)
  use turn <- result.try(ollama.response(resp))

  let json_string = starlet.json(turn)

  case json.parse(json_string, person_decoder()) {
    Ok(person) -> Ok(person)  // person.name == "Alice", person.age == 30
    Error(_) -> Error(starlet.Decode("Failed to parse person"))
  }
}
```

### Reasoning (Extended Thinking)

```gleam
import gleam/httpc
import gleam/option.{None, Some}
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let creds = ollama.credentials("http://localhost:11434")

  let chat =
    ollama.chat(creds, "qwen3:0.6b")
    |> ollama.with_thinking(ollama.ThinkingEnabled)
    |> starlet.user("What is the sum of primes between 1 and 20?")

  let assert Ok(req) = ollama.request(chat, creds)
  let assert Ok(resp) = httpc.send(req)
  use turn <- result.try(ollama.response(resp))

  case ollama.thinking(turn) {
    Some(thinking) -> io.println("Thinking: " <> thinking)
    None -> Nil
  }

  Ok(starlet.text(turn))
}
```
