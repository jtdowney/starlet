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
    starlet.chat(client, "qwen3:0.6b")
    |> starlet.system("You are a helpful assistant.")
    |> starlet.user("What is the capital of France?")

  case starlet.send(chat) {
    Ok(#(_chat, turn)) -> io.println(starlet.text(turn))
    Error(_) -> io.println("Request failed")
  }
}
```

## Features

- **Provider-agnostic**: Swap between Ollama, OpenAI, Anthropic without changing your code
- **Type-safe**: Typestate pattern ensures correct API usage at compile time
- **Conversational**: Chat state flows through the builder, maintaining history automatically
- **Tool use**: Support for tool calls and function calling
- **Structured output**: Generate JSON responses with structured data

## Missing Features

- Streaming responses
- Image generation
- Support for provider built in tools (like Web Search)

## Multi-turn Conversations

```gleam
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let client = ollama.new("http://localhost:11434")

  let result = {
    let chat =
      starlet.chat(client, "qwen3:0.6b")
      |> starlet.user("Hello!")

    use #(chat, _turn) <- result.try(starlet.send(chat))

    let chat = starlet.user(chat, "How are you?")
    use #(_chat, turn) <- result.try(starlet.send(chat))

    Ok(starlet.text(turn))
  }

  // result contains the final response or first error
}
```

## Providers

### Ollama

```gleam
import starlet/ollama

let client = ollama.new("http://localhost:11434")
```

### OpenAI

```gleam
import starlet/openai

let client = openai.new(api_key)
```

### Anthropic

```gleam
import starlet/anthropic

let client = anthropic.new(api_key)
```

Note: Anthropic requires `max_tokens` in every request. If not set via `starlet.max_tokens()`, a default of 4096 is used.
