# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-01-01

### Added

- **Provider-agnostic API**: Unified interface for interacting with LLMs across multiple providers
- **Typestate pattern**: Compile-time enforcement of correct API usage through phantom types
- **Conversational state management**: Chat history flows through the builder automatically

#### Core Features

- **Tool calling**: Define tools with JSON schemas and handle function calls
- **Structured output**: Generate JSON responses constrained by JSON schemas
- **Multi-turn conversations**: Maintain conversation context across multiple exchanges

[0.1.0]: https://github.com/jtdowney/starlet/releases/tag/v0.1.0
