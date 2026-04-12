# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Starlet is a Gleam library providing a unified, provider-agnostic interface for LLM APIs (OpenAI, Anthropic, Ollama, Google Gemini). The core design uses **typestate** to enforce correct API usage at compile time—tools and JSON output constraints are opt-in features that unlock additional APIs only when enabled.

## Commands

```bash
gleam test              # Run all tests
gleam test -- test/starlet_test.gleam  # Run a specific test file
gleam format src test   # Format code
gleam format --check src test  # Check formatting (CI)
gleam add <package>     # Add dependency (always use this for latest version)
gleam run               # Run the project
```

## Architecture

### Sans-IO Design

Providers are pure: they build `Request` values and decode `Response` values but never perform HTTP.
Each provider exposes:
- `request(chat, creds)` / `response(chat, http_resp)` — single-turn
- `stream_request(chat, creds)` / `stream_init()` / `stream_feed(state, chunk)` / `stream_done(state)` — streaming via SSE
- `encode_request(chat)` / `decode_response(body)` — lower-level pure encode/decode
- `list_models_request(creds)` / `list_models_response(http_resp)` — model listing

### Typestate Design

The library uses phantom types to track capabilities at compile time:

- `Chat(tools, format, state, ext)` — conversation builder with four type parameters:
  - `tools`: `ToolsOff` | `ToolsOn` — whether tool calling is enabled
  - `format`: `FreeText` | `JsonFormat` — output format constraint
  - `state`: `Empty` | `Ready` — whether chat has messages and can be sent
  - `ext`: `NoExt` | provider-specific — extension data for provider-specific features

- `Turn(tools, format, ext)` — model response with accessors gated by typestate:
  - `tool_calls(turn)` only compiles when `tools = ToolsOn`
  - `json(turn)` only compiles when `format = JsonFormat`

### Module Structure

```
starlet              # Entry point, builder, send/step, Error type
starlet/tool         # Tool definitions, Call/Result types, dispatch helpers
starlet/openai       # OpenAI provider adapter
starlet/anthropic    # Anthropic provider adapter
starlet/ollama       # Ollama provider adapter
starlet/gemini       # Google Gemini provider adapter
starlet/internal/http # Shared HTTP helpers (not public API)
starlet/internal/sse  # SSE stream parsing (not public API)
```

### Key Design Decisions

1. **Sans-IO** — providers are pure functions; callers own the HTTP client (httpc, hackney, etc.)
2. **`Chat` is the state** — users don't manually manage history; conversation state flows through the builder
3. **Provider-aware tool results** — `apply_tool_results` handles the different sequencing rules:
   - Anthropic: `tool_result` blocks must immediately follow `tool_use`
   - OpenAI: `function_call_output` paired by `call_id`
   - Ollama: `{role: "tool", tool_name, content}` messages
4. **Unified error handling** — `starlet.Error` type covers HTTP, decode, provider, tool, and rate-limit errors

### Provider Mapping

| Feature | OpenAI Responses | Anthropic Messages | Ollama /api/chat | Gemini |
|---------|------------------|-------------------|------------------|--------|
| Tool defs | function tool schema | `tools[]` + `input_schema` | OpenAI-chat style | `functionDeclarations` |
| Tool results | `function_call_output` + `call_id` | `tool_result` blocks, strict order | `{role:"tool"}` | `functionResponse` parts |
| Structured output | `text` config | `output_format` + beta header | `format: "json"` | `responseMimeType` |

## Examples

Working examples for each provider are in `dev/`:
- **OpenAI**: `openai_chat.gleam`, `openai_tool_call.gleam`, `openai_json_output.gleam`, `openai_reasoning.gleam`, `openai_streaming.gleam`, `openai_list_models.gleam`
- **Anthropic**: `anthropic_chat.gleam`, `anthropic_tool_call.gleam`, `anthropic_json_output.gleam`, `anthropic_thinking.gleam`, `anthropic_streaming.gleam`, `anthropic_list_models.gleam`
- **Ollama**: `ollama_chat.gleam`, `ollama_tool_call.gleam`, `ollama_thinking.gleam`, `ollama_json_output.gleam`, `ollama_streaming.gleam`, `ollama_list_models.gleam`
- **Gemini**: `gemini_chat.gleam`, `gemini_tool_call.gleam`, `gemini_json_output.gleam`, `gemini_thinking.gleam`, `gemini_streaming.gleam`, `gemini_list_models.gleam`

Run examples with: `gleam run -m <name>` (e.g., `gleam run -m ollama_chat`)
