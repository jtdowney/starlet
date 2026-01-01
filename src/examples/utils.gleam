import gleam/int
import gleam/option.{None, Some}
import starlet
import starlet/tool

pub fn error_to_string(err: starlet.StarletError) -> String {
  case err {
    starlet.Transport(msg) -> "Transport error: " <> msg
    starlet.Http(status, body) ->
      "HTTP " <> int.to_string(status) <> ": " <> body
    starlet.Decode(msg) -> "Decode error: " <> msg
    starlet.Provider(provider, msg, _raw) -> provider <> " error: " <> msg
    starlet.Tool(tool_err) ->
      case tool_err {
        tool.NotFound(name) -> "Tool not found: " <> name
        tool.InvalidArguments(msg) -> "Invalid arguments: " <> msg
        tool.ExecutionFailed(msg) -> "Tool execution failed: " <> msg
      }
    starlet.RateLimited(retry_after) ->
      case retry_after {
        Some(seconds) ->
          "Rate limited, retry after " <> int.to_string(seconds) <> "s"
        None -> "Rate limited"
      }
  }
}
