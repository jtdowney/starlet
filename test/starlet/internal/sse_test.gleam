import gleam/bit_array
import gleam/list
import gleam/option
import gleam/string
import qcheck
import starlet/internal/sse

fn to_bits(s: String) -> BitArray {
  bit_array.from_string(s)
}

// --- SSE Buffer tests ---

pub fn parse_single_complete_event_test() {
  let buffer = sse.new()
  let #(_buffer, events) = sse.feed(buffer, to_bits("data: hello\n\n"))
  assert events == [#(option.None, "hello")]
}

pub fn parse_multiple_events_in_one_chunk_test() {
  let buffer = sse.new()
  let #(_buffer, events) =
    sse.feed(buffer, to_bits("data: first\n\ndata: second\n\n"))
  assert events == [#(option.None, "first"), #(option.None, "second")]
}

pub fn buffer_partial_event_across_chunks_test() {
  let buffer = sse.new()
  let #(buffer, events1) = sse.feed(buffer, to_bits("data: hel"))
  assert events1 == []
  let #(_buffer, events2) = sse.feed(buffer, to_bits("lo\n\n"))
  assert events2 == [#(option.None, "hello")]
}

pub fn filter_sse_comments_test() {
  let buffer = sse.new()
  let #(_buffer, events) =
    sse.feed(buffer, to_bits(": keep-alive\n\ndata: real\n\n"))
  assert events == [#(option.None, "real")]
}

pub fn handle_empty_blocks_test() {
  let buffer = sse.new()
  let #(_buffer, events) = sse.feed(buffer, to_bits("\n\ndata: hello\n\n"))
  assert events == [#(option.None, "hello")]
}

pub fn pass_through_done_marker_test() {
  let buffer = sse.new()
  let #(_buffer, events) = sse.feed(buffer, to_bits("data: [DONE]\n\n"))
  assert events == [#(option.None, "[DONE]")]
}

pub fn handle_multiline_data_field_test() {
  let buffer = sse.new()
  let #(_buffer, events) =
    sse.feed(buffer, to_bits("data: line1\ndata: line2\n\n"))
  assert events == [#(option.None, "line1\nline2")]
}

pub fn handle_event_type_lines_test() {
  let buffer = sse.new()
  let #(_buffer, events) =
    sse.feed(buffer, to_bits("event: message\ndata: hello\n\n"))
  assert events == [#(option.Some("message"), "hello")]
}

pub fn split_on_double_newline_only_test() {
  let buffer = sse.new()
  let #(buffer, events1) = sse.feed(buffer, to_bits("data: hello\n"))
  assert events1 == []
  let #(_buffer, events2) = sse.feed(buffer, to_bits("\n"))
  assert events2 == [#(option.None, "hello")]
}

pub fn arbitrary_split_produces_same_events_test() {
  use stream <- qcheck.given(qcheck.non_empty_string())
  let full_sse = "data: " <> stream <> "\n\n"
  let full_bytes = to_bits(full_sse)

  // Feed all at once
  let #(_, expected) = sse.feed(sse.new(), full_bytes)

  // Feed byte-by-byte
  let bytes = bit_array.to_string(full_bytes) |> unwrap_string
  let chars = string.to_graphemes(bytes)
  let #(_, actual) =
    list.fold(chars, #(sse.new(), []), fn(acc, char) {
      let #(buf, events) = acc
      let #(buf, new_events) = sse.feed(buf, to_bits(char))
      #(buf, list.append(events, new_events))
    })

  assert expected == actual
}

// --- NDJSON Buffer tests ---

pub fn ndjson_parse_single_line_test() {
  let buffer = sse.new_ndjson()
  let #(_buffer, lines) = sse.feed_ndjson(buffer, to_bits("{\"done\":false}\n"))
  assert lines == ["{\"done\":false}"]
}

pub fn ndjson_parse_multiple_lines_test() {
  let buffer = sse.new_ndjson()
  let #(_buffer, lines) =
    sse.feed_ndjson(buffer, to_bits("{\"a\":1}\n{\"b\":2}\n"))
  assert lines == ["{\"a\":1}", "{\"b\":2}"]
}

pub fn ndjson_buffer_partial_line_test() {
  let buffer = sse.new_ndjson()
  let #(buffer, lines1) = sse.feed_ndjson(buffer, to_bits("{\"partial"))
  assert lines1 == []
  let #(_buffer, lines2) = sse.feed_ndjson(buffer, to_bits("\":true}\n"))
  assert lines2 == ["{\"partial\":true}"]
}

pub fn ndjson_skip_empty_lines_test() {
  let buffer = sse.new_ndjson()
  let #(_buffer, lines) = sse.feed_ndjson(buffer, to_bits("\n{\"a\":1}\n\n"))
  assert lines == ["{\"a\":1}"]
}

// --- SSE CRLF tests ---

pub fn parse_event_with_crlf_test() {
  let buffer = sse.new()
  let #(_buffer, events) = sse.feed(buffer, to_bits("data: hello\r\n\r\n"))
  assert events == [#(option.None, "hello")]
}

pub fn parse_event_with_bare_cr_test() {
  let buffer = sse.new()
  let #(_buffer, events) = sse.feed(buffer, to_bits("data: hello\r\r"))
  assert events == [#(option.None, "hello")]
}

pub fn parse_multiline_event_with_crlf_test() {
  let buffer = sse.new()
  let #(_buffer, events) =
    sse.feed(buffer, to_bits("data: line1\r\ndata: line2\r\n\r\n"))
  assert events == [#(option.None, "line1\nline2")]
}

pub fn parse_multiple_events_with_crlf_test() {
  let buffer = sse.new()
  let #(_buffer, events) =
    sse.feed(buffer, to_bits("data: first\r\n\r\ndata: second\r\n\r\n"))
  assert events == [#(option.None, "first"), #(option.None, "second")]
}

// --- NDJSON CRLF tests ---

pub fn ndjson_parse_with_crlf_test() {
  let buffer = sse.new_ndjson()
  let #(_buffer, lines) =
    sse.feed_ndjson(buffer, to_bits("{\"done\":false}\r\n"))
  assert lines == ["{\"done\":false}"]
}

pub fn ndjson_parse_with_bare_cr_test() {
  let buffer = sse.new_ndjson()
  let #(_buffer, lines) =
    sse.feed_ndjson(buffer, to_bits("{\"a\":1}\r{\"b\":2}\r"))
  assert lines == ["{\"a\":1}", "{\"b\":2}"]
}

pub fn ndjson_parse_multiple_with_crlf_test() {
  let buffer = sse.new_ndjson()
  let #(_buffer, lines) =
    sse.feed_ndjson(buffer, to_bits("{\"a\":1}\r\n{\"b\":2}\r\n"))
  assert lines == ["{\"a\":1}", "{\"b\":2}"]
}

// --- UTF-8 split-chunk handling ---

pub fn feed_split_multibyte_utf8_buffers_correctly_test() {
  let buffer = sse.new()
  // é is 0xC3 0xA9 — split across two chunks
  let #(buffer, events1) = sse.feed(buffer, <<"data: caf":utf8, 0xC3>>)
  assert events1 == []
  let #(_buffer, events2) = sse.feed(buffer, <<0xA9, "\n\n":utf8>>)
  assert events2 == [#(option.None, "café")]
}

pub fn feed_emits_complete_events_before_split_utf8_test() {
  let buffer = sse.new()
  // Complete event "first" followed by partial event with split UTF-8
  let #(buffer, events1) =
    sse.feed(buffer, <<"data: first\n\ndata: caf":utf8, 0xC3>>)
  assert events1 == [#(option.None, "first")]
  let #(_buffer, events2) = sse.feed(buffer, <<0xA9, "\n\n":utf8>>)
  assert events2 == [#(option.None, "café")]
}

pub fn ndjson_feed_split_multibyte_utf8_buffers_correctly_test() {
  let buffer = sse.new_ndjson()
  // é is 0xC3 0xA9 — split across two chunks
  let #(buffer, lines1) =
    sse.feed_ndjson(buffer, <<"{\"text\":\"caf":utf8, 0xC3>>)
  assert lines1 == []
  let #(_buffer, lines2) = sse.feed_ndjson(buffer, <<0xA9, "\"}\n":utf8>>)
  assert lines2 == ["{\"text\":\"café\"}"]
}

pub fn ndjson_emits_complete_lines_before_split_utf8_test() {
  let buffer = sse.new_ndjson()
  // Complete line followed by partial line with split UTF-8
  let #(buffer, lines1) =
    sse.feed_ndjson(buffer, <<"{\"a\":1}\n{\"text\":\"caf":utf8, 0xC3>>)
  assert lines1 == ["{\"a\":1}"]
  let #(_buffer, lines2) = sse.feed_ndjson(buffer, <<0xA9, "\"}\n":utf8>>)
  assert lines2 == ["{\"text\":\"café\"}"]
}

pub fn ndjson_arbitrary_split_produces_same_lines_test() {
  use content <- qcheck.given(qcheck.non_empty_string())
  let full_ndjson = content <> "\n"
  let full_bytes = to_bits(full_ndjson)

  let #(_, expected) = sse.feed_ndjson(sse.new_ndjson(), full_bytes)

  let bytes = bit_array.to_string(full_bytes) |> unwrap_string
  let chars = string.to_graphemes(bytes)
  let #(_, actual) =
    list.fold(chars, #(sse.new_ndjson(), []), fn(acc, char) {
      let #(buf, lines) = acc
      let #(buf, new_lines) = sse.feed_ndjson(buf, to_bits(char))
      #(buf, list.append(lines, new_lines))
    })

  assert expected == actual
}

pub fn parse_data_without_space_test() {
  let buffer = sse.new()
  let #(_buffer, events) = sse.feed(buffer, to_bits("data:hello\n\n"))
  assert events == [#(option.None, "hello")]
}

fn unwrap_string(result: Result(String, Nil)) -> String {
  let assert Ok(s) = result
  s
}
