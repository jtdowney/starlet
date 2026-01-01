//// Internal HTTP utilities shared across providers.

import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string

/// Sets the port on a request if provided.
pub fn set_optional_port(
  req: request.Request(String),
  port: Option(Int),
) -> request.Request(String) {
  case port {
    Some(p) -> request.set_port(req, p)
    _ -> req
  }
}

/// Parses the Retry-After header value from response headers.
pub fn parse_retry_after(headers: List(#(String, String))) -> Option(Int) {
  list.find(headers, fn(h) {
    let #(k, _) = h
    string.lowercase(k) == "retry-after"
  })
  |> result.try(fn(h) {
    let #(_, v) = h
    int.parse(v)
  })
  |> option.from_result
}
