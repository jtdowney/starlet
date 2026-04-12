//// Internal HTTP utilities shared across providers.

import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import starlet

/// Applies defaults to a URI for missing scheme and host.
pub fn with_defaults(
  base_uri: Uri,
  default_scheme scheme: String,
  default_host host: String,
) -> Uri {
  uri.Uri(
    ..base_uri,
    scheme: base_uri.scheme |> option.or(option.Some(scheme)),
    host: case base_uri.host {
      option.Some("") | option.None -> option.Some(host)
      option.Some(existing) -> option.Some(existing)
    },
  )
}

/// Builds a base HTTPS request for a known-good host without URL parsing.
/// Use in provider `credentials` functions where the base URL is a hard-coded constant.
pub fn default_base_request(host host: String) -> #(Request(String), String) {
  let req =
    request.new()
    |> request.set_scheme(http.Https)
    |> request.set_host(host)
  #(req, "")
}

/// Parses a base URL and returns a base HTTP request and the path prefix.
/// Providers append their API path to the returned path prefix.
pub fn base_request(
  base_url: String,
  default_scheme scheme: String,
  default_host host: String,
) -> Result(#(Request(String), String), starlet.Error) {
  use base_uri <- result.try(
    uri.parse(base_url)
    |> result.replace_error(starlet.InvalidUrl(base_url)),
  )
  let base_uri =
    with_defaults(base_uri, default_scheme: scheme, default_host: host)
  use http_request <- result.map(
    request.from_uri(base_uri)
    |> result.replace_error(starlet.InvalidUrl(base_url)),
  )
  let path_prefix = case string.ends_with(base_uri.path, "/") {
    True -> string.drop_end(base_uri.path, 1)
    False -> base_uri.path
  }
  #(http_request, path_prefix)
}

/// Parses the Retry-After header value from response headers.
pub fn parse_retry_after(headers: List(#(String, String))) -> Result(Int, Nil) {
  list.find(headers, fn(header) {
    let #(key, _) = header
    string.lowercase(key) == "retry-after"
  })
  |> result.try(fn(header) {
    let #(_, value) = header
    let value = string.trim(value)
    case int.parse(value) {
      Ok(seconds) -> Ok(seconds)
      Error(_) ->
        float.parse(value)
        |> result.map(float.round)
    }
  })
}

/// Decodes a standard error response body with `{"error": {"message": "..."}}` structure.
/// Used by providers to extract error messages from non-200 responses.
pub fn decode_error_response(body: String) -> Result(String, Nil) {
  let decoder = {
    use error <- decode.field("error", {
      use message <- decode.field("message", decode.string)
      decode.success(message)
    })
    decode.success(error)
  }
  json.parse(body, decoder)
  |> result.replace_error(Nil)
}

/// Handles non-200 HTTP response status codes with rate-limit and error decoding.
/// Providers pass their own error decoder since JSON structures vary.
pub fn handle_error_response(
  resp: Response(String),
  provider provider: String,
  decode_error decode_error: fn(String) -> Result(String, Nil),
) -> starlet.Error {
  case resp.status {
    429 -> {
      let retry_after = parse_retry_after(resp.headers) |> option.from_result
      starlet.RateLimited(retry_after)
    }
    status ->
      case decode_error(resp.body) {
        Ok(msg) -> starlet.Provider(provider:, message: msg, raw: resp.body)
        Error(Nil) -> starlet.Http(status:, body: resp.body)
      }
  }
}

/// Handles non-200 HTTP response status codes with rate-limit detection.
/// Simpler variant without provider-specific error decoding.
pub fn handle_error_status(resp: Response(String)) -> starlet.Error {
  case resp.status {
    429 -> {
      let retry_after = parse_retry_after(resp.headers) |> option.from_result
      starlet.RateLimited(retry_after)
    }
    status -> starlet.Http(status:, body: resp.body)
  }
}
