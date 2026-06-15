//// Thinking/reasoning configuration for OpenAI-compatible providers.
////
//// Most users should use `openai_compat.with_reasoning()` instead of
//// this module directly. This module provides advanced configuration
//// for edge cases or unsupported providers.

import gleam/option.{type Option, None, Some}
import gleam/string

/// Provider dialect for OpenAI-compatible APIs.
/// Each dialect knows how to encode reasoning requests and decode responses.
pub type Dialect {
  /// Generic: reasoning_effort param, reasoning_content response field
  Generic
  /// Together AI: reasoning_effort param, reasoning/reasoning_content fields
  Together
  /// Groq: reasoning_format param, reasoning field or think tags
  Groq
  /// Cerebras: reasoning_format param, reasoning field
  Cerebras
  /// Local llama.cpp/vLLM: no request param, reasoning_content field
  LlamaCpp
  /// Tags: no request param, parse <think> tags from content
  Tags
}

/// Reasoning effort level.
pub type Effort {
  EffortNone
  EffortLow
  EffortMedium
  EffortHigh
}

/// How to request thinking/reasoning from the provider.
pub type Request {
  /// Don't send any reasoning params
  RequestNone
  /// Send `reasoning_effort: "low"|"medium"|"high"`
  RequestEffort(String)
  /// Send `reasoning_format: "parsed"|"raw"|"hidden"`
  RequestFormat(String)
  /// Send `disable_reasoning: true|false`
  RequestDisable(Bool)
  /// Send `thinking: { type: "enabled"|"disabled" }` (Z.ai style)
  RequestZai(Bool)
}

/// How to extract thinking from the response.
pub type Response {
  /// Don't look for thinking in the response
  ResponseNone
  /// Look for thinking in these message fields
  ResponseFields(List(String))
  /// Parse `<think>...</think>` tags from the content
  ResponseThinkTags
}

/// How to include thinking in multi-turn context.
pub type Context {
  /// Don't include thinking in subsequent requests (default)
  ContextDoNotSend
  /// Include thinking as a JSON field on assistant messages
  ContextSendAsField(String)
  /// Embed thinking as `<think>...</think>` tags in message content
  ContextSendWithTags
}

/// Advanced configuration for thinking/reasoning behavior.
/// Most users should use `openai_compat.with_reasoning()` instead.
pub type Config {
  Config(
    request: Request,
    response: Response,
    context: Context,
    strip_from_content: Bool,
  )
}

/// Build the appropriate config for a dialect and effort level.
@internal
pub fn config_for_dialect(dialect: Dialect, effort: Effort) -> Config {
  case dialect {
    Generic -> generic_effort_config(effort)
    Together -> together_config(effort)
    Groq -> groq_config(effort)
    Cerebras -> cerebras_config(effort)
    LlamaCpp -> llama_cpp_config(effort)
    Tags -> tags_config(effort)
  }
}

fn generic_effort_config(effort: Effort) -> Config {
  Config(
    request: case effort {
      EffortNone -> RequestNone
      EffortLow -> RequestEffort("low")
      EffortMedium -> RequestEffort("medium")
      EffortHigh -> RequestEffort("high")
    },
    response: ResponseFields(["reasoning_content"]),
    context: ContextSendAsField("reasoning_content"),
    strip_from_content: False,
  )
}

fn together_config(effort: Effort) -> Config {
  Config(
    request: case effort {
      EffortNone -> RequestNone
      EffortLow -> RequestEffort("low")
      EffortMedium -> RequestEffort("medium")
      EffortHigh -> RequestEffort("high")
    },
    response: ResponseFields(["reasoning_content", "reasoning"]),
    context: ContextSendAsField("reasoning_content"),
    strip_from_content: False,
  )
}

fn groq_config(effort: Effort) -> Config {
  case effort {
    EffortNone ->
      Config(
        request: RequestFormat("hidden"),
        response: ResponseNone,
        context: ContextDoNotSend,
        strip_from_content: False,
      )
    _ ->
      Config(
        request: RequestFormat("parsed"),
        response: ResponseFields(["reasoning"]),
        context: ContextSendAsField("reasoning"),
        strip_from_content: False,
      )
  }
}

fn cerebras_config(effort: Effort) -> Config {
  case effort {
    EffortNone ->
      Config(
        request: RequestFormat("hidden"),
        response: ResponseNone,
        context: ContextDoNotSend,
        strip_from_content: False,
      )
    _ ->
      Config(
        request: RequestFormat("parsed"),
        response: ResponseFields(["reasoning"]),
        context: ContextSendAsField("reasoning"),
        strip_from_content: False,
      )
  }
}

fn llama_cpp_config(_effort: Effort) -> Config {
  Config(
    request: RequestNone,
    response: ResponseFields(["reasoning_content"]),
    context: ContextSendAsField("reasoning_content"),
    strip_from_content: False,
  )
}

fn tags_config(_effort: Effort) -> Config {
  Config(
    request: RequestNone,
    response: ResponseThinkTags,
    context: ContextSendWithTags,
    strip_from_content: True,
  )
}

/// Get the list of fields to check for thinking content.
@internal
pub fn get_response_fields(config: Option(Config)) -> List(String) {
  case config {
    Some(Config(response: ResponseFields(fields), ..)) -> fields
    _ -> []
  }
}

/// Process text and extracted thinking based on config.
/// Returns (final_text, thinking_content).
@internal
pub fn process(
  text: String,
  thinking_from_fields: Option(String),
  config: Option(Config),
) -> #(String, Option(String)) {
  case config {
    None -> #(text, None)
    Some(cfg) ->
      case thinking_from_fields {
        Some(thinking) -> #(text, Some(thinking))
        None ->
          case cfg.response {
            ResponseThinkTags -> parse_think_tags(text, cfg.strip_from_content)
            _ -> #(text, None)
          }
      }
  }
}

/// Parse <think>...</think> tags from text.
@internal
pub fn parse_think_tags(text: String, strip: Bool) -> #(String, Option(String)) {
  case string.split_once(text, "<think>") {
    Ok(#(before, after_open)) ->
      case string.split_once(after_open, "</think>") {
        Ok(#(thinking_content, after_close)) -> {
          let thinking = Some(string.trim(thinking_content))
          let final_text = case strip {
            True -> string.trim(before <> after_close)
            False -> text
          }
          #(final_text, thinking)
        }
        Error(_) -> #(text, None)
      }
    Error(_) -> #(text, None)
  }
}
