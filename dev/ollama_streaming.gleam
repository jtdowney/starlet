import example_utils as utils
import gleam/erlang/process
import gleam/httpc
import gleam/io
import gleam/list
import starlet
import starlet/ollama

pub fn main() {
  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

  let chat =
    ollama.chat("qwen3:0.6b")
    |> starlet.system("You are a helpful assistant. Be concise.")
    |> starlet.user("What is the capital of France?")

  let req = ollama.stream_request(chat, creds)

  let config = httpc.configure() |> httpc.timeout(30_000)
  let assert Ok(request_id) = httpc.dispatch_stream_request(config, req)

  let selector =
    process.new_selector()
    |> httpc.select_stream_messages(httpc.raw_stream_mapper())

  io.print("Ollama: ")
  let state = ollama.stream_init()
  case process.selector_receive(from: selector, within: 30_000) {
    Ok(httpc.StreamStart(id, _headers, pid)) if id == request_id -> {
      httpc.receive_next_stream_message(pid)
      let state = stream_loop(selector, pid, request_id, state)
      io.println("")

      let turn = ollama.stream_done(chat, state)
      let _chat = starlet.append_turn(chat, turn)
      Nil
    }
    Ok(httpc.StreamError(_, err)) -> {
      io.println_error("Error: " <> utils.format_http_error(err))
    }
    Error(Nil) -> {
      io.println_error("Error: timed out waiting for response")
    }
    _ -> {
      io.println_error("Error: unexpected stream message")
    }
  }
}

fn stream_loop(
  selector: process.Selector(httpc.StreamMessage),
  pid: process.Pid,
  request_id: httpc.RequestIdentifier,
  state: ollama.StreamState,
) -> ollama.StreamState {
  case process.selector_receive(from: selector, within: 30_000) {
    Ok(httpc.StreamChunk(id, data)) if id == request_id -> {
      let #(state, events) = ollama.stream_feed(state, data)
      list.each(events, fn(event) {
        case event {
          starlet.TextDelta(text) -> io.print(text)
          starlet.StreamError(err) ->
            io.println_error("Error: " <> utils.error_to_string(err))
          starlet.ToolCallStart(_, _) -> Nil
          starlet.ToolCallDelta(_, _) -> Nil
          starlet.ThinkingDelta(_) -> Nil
          starlet.Done -> Nil
        }
      })
      httpc.receive_next_stream_message(pid)
      stream_loop(selector, pid, request_id, state)
    }
    Ok(httpc.StreamEnd(id, _)) if id == request_id -> state
    Ok(httpc.StreamError(_, err)) -> {
      io.println_error("Error: " <> utils.format_http_error(err))
      state
    }
    _ -> state
  }
}
