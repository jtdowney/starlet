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
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

  let chat =
    ollama.chat("qwen3:0.6b")
    |> starlet.system("You are a helpful assistant.")
    |> starlet.user("What is the capital of France?")

  let assert Ok(resp) = ollama.request(chat, creds) |> httpc.send

  case ollama.response(chat, resp) {
    Ok(turn) -> io.println(starlet.text(turn))
    Error(_) -> io.println("Request failed")
  }
}
```

## Features

- Sans-IO: pure request/response functions, bring your own HTTP client
- Tool calling with automatic dispatch
- Structured JSON output with schema validation
- Streaming via server-sent events
- Extended thinking for supported models
- Erlang and JavaScript targets

## Missing Features

- Image inputs
- Provider built-in tools (web search, code execution)

## Supported Providers

- Ollama (`starlet/ollama`)
- OpenAI (`starlet/openai`)
- Anthropic (`starlet/anthropic`)
- Google Gemini (`starlet/gemini`)

## Examples

### Multi-turn Conversations

```gleam
import gleam/httpc
import gleam/io
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

  let result = {
    let chat =
      ollama.chat("qwen3:0.6b")
      |> starlet.user("Hello!")

    use turn <- result.try(send_chat(chat, creds))

    let chat =
      chat
      |> starlet.append_turn(turn)
      |> starlet.user("How are you?")

    use turn <- result.try(send_chat(chat, creds))

    Ok(starlet.text(turn))
  }

  case result {
    Ok(text) -> io.println(text)
    Error(_) -> io.println("Request failed")
  }
}

fn send_chat(chat, creds) {
  let assert Ok(resp) = ollama.request(chat, creds) |> httpc.send
  ollama.response(chat, resp)
}
```

### Tool Calling

```gleam
import gleam/dynamic/decode
import gleam/httpc
import gleam/json
import gleam/result
import starlet
import starlet/ollama
import starlet/tool

pub fn main() {
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

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
    ollama.chat("qwen3:0.6b")
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
  let assert Ok(resp) = ollama.request(chat, creds) |> httpc.send
  ollama.response(chat, resp)
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
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

  let person_schema =
    schema.object([
      schema.prop("name", schema.string()),
      schema.prop("age", schema.integer()),
    ])

  let chat =
    ollama.chat("qwen3:0.6b")
    |> starlet.with_json_output(person_schema)
    |> starlet.user("Extract: Alice is 30 years old.")

  let assert Ok(resp) = ollama.request(chat, creds) |> httpc.send
  use turn <- result.try(ollama.response(chat, resp))

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
import gleam/io
import gleam/option.{None, Some}
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

  let chat =
    ollama.chat("qwen3:0.6b")
    |> ollama.with_thinking(mode: ollama.ThinkingOn)
    |> starlet.user("What is the sum of primes between 1 and 20?")

  let assert Ok(resp) = ollama.request(chat, creds) |> httpc.send
  use turn <- result.try(ollama.response(chat, resp))

  case ollama.thinking(turn) {
    Some(thinking) -> io.println("Thinking: " <> thinking)
    None -> Nil
  }

  Ok(starlet.text(turn))
}
```

### Streaming

> **Note:** This example uses an unreleased streaming API from [gleam_httpc#50](https://github.com/gleam-lang/httpc/pull/50).

```gleam
import gleam/erlang/process
import gleam/httpc
import gleam/io
import gleam/list
import starlet
import starlet/ollama

pub fn main() {
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

  let chat =
    ollama.chat("qwen3:0.6b")
    |> starlet.user("What is the capital of France?")

  let req = ollama.stream_request(chat, creds)

  let config = httpc.configure() |> httpc.timeout(30_000)
  let assert Ok(request_id) = httpc.dispatch_stream_request(config, req)

  let selector =
    process.new_selector()
    |> httpc.select_stream_messages(httpc.raw_stream_mapper())

  let state = ollama.stream_init()
  case process.selector_receive(from: selector, within: 30_000) {
    Ok(httpc.StreamStart(id, _headers, pid)) if id == request_id -> {
      httpc.receive_next_stream_message(pid)
      let state = stream_loop(selector, pid, request_id, state)

      let turn = ollama.stream_done(chat, state)
      io.println(starlet.text(turn))
    }
    _ -> io.println_error("Error: streaming failed")
  }
}

fn stream_loop(
  selector: process.Selector(httpc.StreamMessage),
  pid: process.Pid,
  request_id: httpc.RequestIdentifier,
  state: ollama.StreamState,
) -> ollama.StreamState {
  case process.selector_receive(from: selector, within: 30_000) {
    Ok(httpc.StreamChunk(id, data)) if id == request_id -> {
      let #(state, events) = ollama.stream_feed(state, data)
      list.each(events, fn(event) {
        case event {
          starlet.TextDelta(text) -> io.print(text)
          _ -> Nil
        }
      })
      httpc.receive_next_stream_message(pid)
      stream_loop(selector, pid, request_id, state)
    }
    Ok(httpc.StreamEnd(id, _)) if id == request_id -> state
    _ -> state
  }
}
```

### Listing Models

```gleam
import gleam/httpc
import gleam/io
import gleam/list
import starlet
import starlet/ollama

pub fn main() {
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")
  let assert Ok(resp) =
    ollama.list_models_request(creds) |> httpc.send

  case ollama.list_models_response(resp) {
    Ok(models) ->
      list.each(models, fn(model) {
        io.println(model.name <> " (" <> model.size <> ")")
      })
    Error(_) -> io.println("Failed to list models")
  }
}
```
