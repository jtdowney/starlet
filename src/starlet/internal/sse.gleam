//// SSE (Server-Sent Events) and NDJSON line parsers.
////
//// Buffers incoming bytes and splits them into individual event payloads.
//// The SSE parser handles `data:` fields, multi-line data, comments, and
//// keep-alive lines. The NDJSON parser splits on single newlines.

import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{type Option}
import gleam/string
import splitter

pub type Buffer {
  Buffer(pending: BitArray)
}

pub fn new() -> Buffer {
  Buffer(pending: <<>>)
}

pub fn feed(
  buffer: Buffer,
  data data: BitArray,
) -> #(Buffer, List(#(Option(String), String))) {
  let combined = bit_array.append(buffer.pending, data)
  let #(text, trailing) = decode_utf8_safe(combined)
  case text {
    "" -> #(Buffer(pending: combined), [])
    _ -> {
      let block_separator = splitter.new(["\r\n\r\n", "\n\n", "\r\r"])
      let #(blocks, remaining) = split_all(text, block_separator, [])
      let parsed = list.filter_map(blocks, parse_event_block)
      let pending = bit_array.append(bit_array.from_string(remaining), trailing)
      #(Buffer(pending:), parsed)
    }
  }
}

fn parse_event_block(block: String) -> Result(#(Option(String), String), Nil) {
  let line_separator = splitter.new(["\r\n", "\n", "\r"])
  let #(lines, remaining) = split_all(block, line_separator, [])
  let lines = case remaining {
    "" -> lines
    rest -> list.append(lines, [rest])
  }
  let event_type =
    list.find_map(lines, fn(line) {
      case line {
        "event: " <> rest -> Ok(rest)
        "event:" <> rest -> Ok(rest)
        _ -> Error(Nil)
      }
    })
    |> option.from_result
  let data_lines =
    list.filter_map(lines, fn(line) {
      case line {
        "data: " <> rest -> Ok(rest)
        "data:" <> rest -> Ok(rest)
        _ -> Error(Nil)
      }
    })
  case data_lines {
    [] -> Error(Nil)
    _ -> Ok(#(event_type, string.join(data_lines, "\n")))
  }
}

pub type NdjsonBuffer {
  NdjsonBuffer(pending: BitArray)
}

pub fn new_ndjson() -> NdjsonBuffer {
  NdjsonBuffer(pending: <<>>)
}

pub fn feed_ndjson(
  buffer: NdjsonBuffer,
  data data: BitArray,
) -> #(NdjsonBuffer, List(String)) {
  let combined = bit_array.append(buffer.pending, data)
  let #(text, trailing) = decode_utf8_safe(combined)
  case text {
    "" -> #(NdjsonBuffer(pending: combined), [])
    _ -> {
      let line_separator = splitter.new(["\r\n", "\n", "\r"])
      let #(lines, remaining) = split_all(text, line_separator, [])
      let non_empty = list.filter(lines, fn(line) { line != "" })
      let pending = bit_array.append(bit_array.from_string(remaining), trailing)
      #(NdjsonBuffer(pending:), non_empty)
    }
  }
}

fn split_all(
  text: String,
  separator: splitter.Splitter,
  acc: List(String),
) -> #(List(String), String) {
  case splitter.split(separator, text) {
    #(chunk, "", "") -> #(list.reverse(acc), chunk)
    #(chunk, _delimiter, rest) -> split_all(rest, separator, [chunk, ..acc])
  }
}

fn decode_utf8_safe(data: BitArray) -> #(String, BitArray) {
  case bit_array.to_string(data) {
    Ok(text) -> #(text, <<>>)
    Error(Nil) -> trim_trailing_utf8(data, bit_array.byte_size(data), 1)
  }
}

fn trim_trailing_utf8(
  data: BitArray,
  len: Int,
  drop: Int,
) -> #(String, BitArray) {
  use <- bool.guard(drop > 3 || drop >= len, #("", data))
  let prefix_len = len - drop
  case bit_array.slice(data, 0, prefix_len) {
    Error(Nil) -> #("", data)
    Ok(prefix) ->
      case bit_array.to_string(prefix) {
        Error(Nil) -> trim_trailing_utf8(data, len, drop + 1)
        Ok(text) -> {
          let tail = case bit_array.slice(data, prefix_len, drop) {
            Ok(tail) -> tail
            Error(Nil) -> <<>>
          }
          #(text, tail)
        }
      }
  }
}
