import gleam/http
import gleam/http/response
import gleam/json
import gleam/option
import starlet
import starlet/internal/http as internal_http

pub fn base_request_with_full_url_test() {
  let assert Ok(#(req, path_prefix)) =
    internal_http.base_request(
      "https://api.example.com",
      default_scheme: "https",
      default_host: "default.com",
    )
  assert req.scheme == http.Https
  assert req.host == "api.example.com"
  assert path_prefix == ""
}

pub fn base_request_with_path_prefix_test() {
  let assert Ok(#(req, path_prefix)) =
    internal_http.base_request(
      "https://proxy.example.com/llm",
      default_scheme: "https",
      default_host: "default.com",
    )
  assert req.host == "proxy.example.com"
  assert path_prefix == "/llm"
}

pub fn base_request_with_trailing_slash_test() {
  let assert Ok(#(_req, path_prefix)) =
    internal_http.base_request(
      "https://api.example.com/",
      default_scheme: "https",
      default_host: "default.com",
    )
  assert path_prefix == ""
}

pub fn base_request_with_path_prefix_trailing_slash_test() {
  let assert Ok(#(_req, path_prefix)) =
    internal_http.base_request(
      "https://proxy.example.com/llm/",
      default_scheme: "https",
      default_host: "default.com",
    )
  assert path_prefix == "/llm"
}

pub fn base_request_with_port_test() {
  let assert Ok(#(req, _path_prefix)) =
    internal_http.base_request(
      "http://localhost:11434",
      default_scheme: "http",
      default_host: "localhost",
    )
  assert req.host == "localhost"
  assert req.port == option.Some(11_434)
}

pub fn base_request_applies_default_scheme_test() {
  let assert Ok(#(req, _path_prefix)) =
    internal_http.base_request(
      "//api.example.com",
      default_scheme: "https",
      default_host: "default.com",
    )
  assert req.scheme == http.Https
}

pub fn base_request_empty_host_applies_default_test() {
  let assert Ok(#(req, _path_prefix)) =
    internal_http.base_request(
      "https://",
      default_scheme: "https",
      default_host: "default.com",
    )
  assert req.host == "default.com"
}

pub fn base_request_invalid_url_test() {
  let assert Error(starlet.InvalidUrl(url)) =
    internal_http.base_request(
      "://",
      default_scheme: "https",
      default_host: "default.com",
    )
  assert url == "://"
}

pub fn parse_retry_after_valid_test() {
  let headers = [#("retry-after", "30")]
  let result = internal_http.parse_retry_after(headers)
  assert result == Ok(30)
}

pub fn parse_retry_after_missing_test() {
  let headers = [#("content-type", "application/json")]
  let result = internal_http.parse_retry_after(headers)
  assert result == Error(Nil)
}

pub fn parse_retry_after_non_integer_test() {
  let headers = [#("retry-after", "not-a-number")]
  let result = internal_http.parse_retry_after(headers)
  assert result == Error(Nil)
}

pub fn parse_retry_after_float_test() {
  let headers = [#("retry-after", "1.5")]
  let result = internal_http.parse_retry_after(headers)
  assert result == Ok(2)
}

pub fn parse_retry_after_float_whole_number_test() {
  let headers = [#("retry-after", "30.0")]
  let result = internal_http.parse_retry_after(headers)
  assert result == Ok(30)
}

pub fn parse_retry_after_case_insensitive_test() {
  let headers = [#("Retry-After", "60")]
  let result = internal_http.parse_retry_after(headers)
  assert result == Ok(60)
}

pub fn decode_error_response_valid_test() {
  let body =
    json.object([
      #(
        "error",
        json.object([#("message", json.string("rate limit exceeded"))]),
      ),
    ])
    |> json.to_string

  assert internal_http.decode_error_response(body) == Ok("rate limit exceeded")
}

pub fn decode_error_response_malformed_json_test() {
  assert internal_http.decode_error_response("not json") == Error(Nil)
}

pub fn decode_error_response_missing_message_test() {
  let body =
    json.object([#("error", json.object([]))])
    |> json.to_string

  assert internal_http.decode_error_response(body) == Error(Nil)
}

pub fn handle_error_response_rate_limited_test() {
  let resp =
    response.new(429)
    |> response.set_header("retry-after", "30")
    |> response.set_body("")
  let result =
    internal_http.handle_error_response(
      resp,
      provider: "test",
      decode_error: fn(_) { Error(Nil) },
    )
  assert result == starlet.RateLimited(option.Some(30))
}

pub fn handle_error_response_provider_error_test() {
  let resp = response.new(400) |> response.set_body("error body")
  let result =
    internal_http.handle_error_response(
      resp,
      provider: "test",
      decode_error: fn(_) { Ok("decoded message") },
    )
  assert result
    == starlet.Provider(
      provider: "test",
      message: "decoded message",
      raw: "error body",
    )
}

pub fn handle_error_response_fallback_test() {
  let resp = response.new(500) |> response.set_body("raw error")
  let result =
    internal_http.handle_error_response(
      resp,
      provider: "test",
      decode_error: fn(_) { Error(Nil) },
    )
  assert result == starlet.Http(status: 500, body: "raw error")
}

pub fn handle_error_status_rate_limited_test() {
  let resp =
    response.new(429)
    |> response.set_header("retry-after", "60")
    |> response.set_body("")
  let result = internal_http.handle_error_status(resp)
  assert result == starlet.RateLimited(option.Some(60))
}

pub fn handle_error_status_non_429_test() {
  let resp = response.new(503) |> response.set_body("Service Unavailable")
  let result = internal_http.handle_error_status(resp)
  assert result == starlet.Http(status: 503, body: "Service Unavailable")
}
