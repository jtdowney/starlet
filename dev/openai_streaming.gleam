import example_utils as utils
import gleam/erlang/process
import gleam/httpc
import gleam/io
import gleam/list
import starlet
import starlet/openai

pub fn main() {
  use api_key <- utils.require_env("OPENAI_API_KEY")
  run_example(api_key)
}

fn run_example(api_key: String) {
  let creds = openai.credentials(api_key)

  let chat =
    openai.chat("gpt-4o-mini")
    |> starlet.system("You are a helpful assistant. Be concise.")
    |> starlet.user("What is the capital of France?")

  let req = openai.stream_request(chat, creds)

  let config = httpc.configure() |> httpc.timeout(30_000)
  let assert Ok(request_id) = httpc.dispatch_stream_request(config, req)

  let selector =
    process.new_selector()
    |> httpc.select_stream_messages(httpc.raw_stream_mapper())

  io.print("OpenAI: ")
  let state = openai.stream_init()
  case process.selector_receive(from: selector, within: 30_000) {
    Ok(httpc.StreamStart(id, _headers, pid)) if id == request_id -> {
      httpc.receive_next_stream_message(pid)
      let state = stream_loop(selector, pid, request_id, state)
      io.println("")

      let turn = openai.stream_done(chat, state)
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
  state: openai.StreamState,
) -> openai.StreamState {
  case process.selector_receive(from: selector, within: 30_000) {
    Ok(httpc.StreamChunk(id, data)) if id == request_id -> {
      let #(state, events) = openai.stream_feed(state, data)
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
