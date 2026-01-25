//// Internal HTTP utilities shared across providers.

import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri, Uri}

/// Applies defaults to a URI for missing scheme and host.
pub fn with_defaults(
  base_uri: Uri,
  default_scheme: String,
  default_host: String,
) -> Uri {
  Uri(
    ..base_uri,
    scheme: base_uri.scheme |> option.or(Some(default_scheme)),
    host: base_uri.host |> option.or(Some(default_host)),
  )
}

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
  list.find(headers, fn(header) {
    let #(key, _) = header
    string.lowercase(key) == "retry-after"
  })
  |> result.try(fn(header) {
    let #(_, value) = header
    int.parse(value)
  })
  |> option.from_result
}
