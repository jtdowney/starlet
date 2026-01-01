# starlet

[![Package Version](https://img.shields.io/hexpm/v/starlet)](https://hex.pm/packages/starlet)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/starlet/)

A unified, provider-agnostic interface for LLM APIs in Gleam.

## Installation

```sh
gleam add starlet
```

## Quick Start

```gleam
import gleam/io
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let client = ollama.new("http://localhost:11434")

  let chat =
    starlet.chat(client, "gpt-oss:20b")
    |> starlet.system("You are a helpful assistant.")
    |> starlet.user("What is the capital of France?")

  case starlet.send(chat) {
    Ok(#(_chat, turn)) -> io.println(starlet.text(turn))
    Error(_) -> io.println("Request failed")
  }
}
```

## Features

- **Tool use**: Support for tool calls and function calling
- **Structured output**: Generate JSON responses with structured data
- **Reasoning**: Support for setting budget/effort for reasoning models

## Missing Features

- Streaming responses
- Image generation
- Support for provider built in tools (like Web Search)

## Examples

### Multi-turn Conversations

```gleam
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let client = ollama.new("http://localhost:11434")

  let result = {
    let chat =
      starlet.chat(client, "gpt-oss:20b")
      |> starlet.user("Hello!")

    use #(chat, _turn) <- result.try(starlet.send(chat))

    let chat = starlet.user(chat, "How are you?")
    use #(_chat, turn) <- result.try(starlet.send(chat))

    Ok(starlet.text(turn))
  }

  // result contains the final response or first error
}
```

### Tool Calling

```gleam
import gleam/json
import gleam/result
import starlet
import starlet/ollama
import starlet/tool

pub fn main() {
  let client = ollama.new("http://localhost:11434")

  // Define a tool
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

  // Create a handler that executes tools
  let dispatcher =
    tool.dispatch([
      tool.handler("get_weather", fn(_args) {
        Ok(json.object([#("temp", json.int(22)), #("condition", json.string("sunny"))]))
      }),
    ])

  let chat =
    starlet.chat(client, "gpt-oss:20b")
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What's the weather in Tokyo?")

  // Use step/apply_tool_results loop to handle tool calls
  use step <- result.try(starlet.step(chat))
  case step {
    starlet.ToolCall(chat:, calls:, ..) -> {
      use chat <- result.try(starlet.apply_tool_results(chat, calls, dispatcher))
      starlet.send(chat)  // Continue after tools execute
    }
    starlet.Done(..) -> Ok(step)
  }
}
```

### Structured JSON Output

```gleam
import gleam/dynamic/decode
import gleam/json
import gleam/result
import jscheam/schema
import starlet
import starlet/ollama

// Define your output type
pub type Person {
  Person(name: String, age: Int)
}

// Create a decoder for the type
fn person_decoder() -> decode.Decoder(Person) {
  use name <- decode.field("name", decode.string)
  use age <- decode.field("age", decode.int)
  decode.success(Person(name:, age:))
}

pub fn main() {
  let client = ollama.new("http://localhost:11434")

  // Define the output schema (must match your type)
  let person_schema =
    schema.object([
      schema.prop("name", schema.string()),
      schema.prop("age", schema.integer()),
    ])

  let chat =
    starlet.chat(client, "gpt-oss:20b")
    |> starlet.with_json_output(person_schema)
    |> starlet.user("Extract: Alice is 30 years old.")

  use #(_chat, turn) <- result.try(starlet.send(chat))

  // Get the JSON string
  let json_string = starlet.json(turn)

  // Parse and decode into your type
  case json.parse(json_string, person_decoder()) {
    Ok(person) -> // person.name == "Alice", person.age == 30
    Error(_) -> // Handle decode error
  }
}
```

### Reasoning (Extended Thinking)

```gleam
import gleam/option.{None, Some}
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let client = ollama.new("http://localhost:11434")

  let chat =
    starlet.chat(client, "gpt-oss:20b")
    |> ollama.with_thinking(True)
    |> starlet.user("What is the sum of primes between 1 and 20?")

  use #(_chat, turn) <- result.try(starlet.send(chat))

  // Access thinking content (provider-specific)
  case ollama.thinking(turn) {
    Some(thinking) -> // The model's thinking process
    None -> // No thinking available
  }

  starlet.text(turn)  // The final answer
}
```
