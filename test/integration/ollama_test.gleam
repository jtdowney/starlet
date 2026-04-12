import gleam/dynamic/decode
import gleam/erlang/process
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import jscheam/schema
import starlet
import starlet/ollama
import starlet/tool
import unitest

fn send_chat(
  chat: starlet.Chat(tools, format, starlet.Ready, ollama.Ext),
  creds: ollama.Credentials,
) -> Result(starlet.Turn(tools, format, ollama.Ext), starlet.Error) {
  let assert Ok(resp) = ollama.request(chat, creds) |> httpc.send
  ollama.response(chat, resp)
}

pub fn simple_chat_test() -> Nil {
  use <- unitest.tag("integration")

  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

  let chat =
    ollama.chat("qwen3:0.6b")
    |> starlet.system("Reply with exactly one word.")
    |> starlet.user("Say hello")

  let assert Ok(turn) = send_chat(chat, creds)
  let response = starlet.text(turn)

  assert string.length(response) > 0
}

pub fn tool_calling_test() -> Nil {
  use <- unitest.tag("integration")

  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

  let weather_tool =
    tool.function(
      name: "get_weather",
      description: "Get the current weather for a city",
      parameters: json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "city",
              json.object([
                #("type", json.string("string")),
                #("description", json.string("The city name")),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["city"], json.string)),
      ]),
    )

  let chat =
    ollama.chat("qwen3:0.6b")
    |> starlet.system(
      "You are a helpful assistant. Use the get_weather tool when asked about weather.",
    )
    |> starlet.with_tools([weather_tool])
    |> starlet.user("What is the weather in Paris?")

  let assert Ok(turn) = send_chat(chat, creds)
  let calls = starlet.tool_calls(turn)
  let assert [call] = calls
  assert call.name == "get_weather"

  let tool_result =
    tool.success(
      call,
      json.object([
        #("temperature", json.int(22)),
        #("condition", json.string("sunny")),
      ]),
    )
  let chat = starlet.append_turn(chat, turn)
  let chat = starlet.with_tool_results(chat, [tool_result])

  let assert Ok(turn) = send_chat(chat, creds)
  let response = starlet.text(turn)

  assert string.length(response) > 0
}

pub fn thinking_test() -> Nil {
  use <- unitest.tag("integration")

  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

  let chat =
    ollama.chat("qwen3:0.6b")
    |> ollama.with_thinking(mode: ollama.ThinkingOn)
    |> starlet.user("What is the sum of all prime numbers between 1 and 20?")

  let assert Ok(turn) = send_chat(chat, creds)
  let response = starlet.text(turn)

  assert string.length(response) > 0
  let assert option.Some(_) = ollama.thinking(turn)
  Nil
}

pub fn json_output_test() -> Nil {
  use <- unitest.tag("integration")

  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

  let person_schema =
    schema.object([
      schema.prop("name", schema.string()),
      schema.prop("age", schema.integer()),
      schema.prop("city", schema.string()),
    ])
    |> schema.disallow_additional_props()

  let chat =
    ollama.chat("qwen3:0.6b")
    |> starlet.system(
      "You are a helpful assistant that extracts structured data.",
    )
    |> starlet.with_json_output(person_schema)
    |> starlet.user(
      "Extract the person info: John Smith is 30 years old and lives in Paris.",
    )

  let assert Ok(turn) = send_chat(chat, creds)
  let json_string = starlet.json(turn)

  let person_decoder = {
    use name <- decode.field("name", decode.string)
    use age <- decode.field("age", decode.int)
    use city <- decode.field("city", decode.string)
    decode.success(#(name, age, city))
  }

  let assert Ok(#(name, age, city)) = json.parse(json_string, person_decoder)
  assert name == "John Smith"
  assert age == 30
  assert city == "Paris"
}

pub fn streaming_test() -> Nil {
  use <- unitest.tag("integration")

  let assert Ok(creds) = ollama.credentials("http://localhost:11434")

  let chat =
    ollama.chat("qwen3:0.6b")
    |> starlet.system("Reply with exactly one word.")
    |> starlet.user("Say hello")

  let req = ollama.stream_request(chat, creds)

  let config = httpc.configure() |> httpc.timeout(30_000)
  let assert Ok(request_id) = httpc.dispatch_stream_request(config, req)

  let selector =
    process.new_selector()
    |> httpc.select_stream_messages(httpc.raw_stream_mapper())

  let state = ollama.stream_init()
  let assert Ok(httpc.StreamStart(id, _headers, pid)) =
    process.selector_receive(from: selector, within: 30_000)
  assert id == request_id
  httpc.receive_next_stream_message(pid)

  let #(state, got_text) =
    stream_loop_ollama(selector, pid, request_id, state, False)
  assert got_text

  let turn = ollama.stream_done(chat, state)
  let response = starlet.text(turn)
  assert string.length(response) > 0
}

fn stream_loop_ollama(
  selector: process.Selector(httpc.StreamMessage),
  pid: process.Pid,
  request_id: httpc.RequestIdentifier,
  state: ollama.StreamState,
  got_text: Bool,
) -> #(ollama.StreamState, Bool) {
  case process.selector_receive(from: selector, within: 30_000) {
    Ok(httpc.StreamChunk(id, data)) if id == request_id -> {
      let #(state, events) = ollama.stream_feed(state, data)
      let got_text =
        got_text
        || list.any(events, fn(event) {
          case event {
            starlet.TextDelta(_) -> True
            starlet.ToolCallStart(_, _)
            | starlet.ToolCallDelta(_, _)
            | starlet.ThinkingDelta(_)
            | starlet.StreamError(_)
            | starlet.Done -> False
          }
        })
      httpc.receive_next_stream_message(pid)
      stream_loop_ollama(selector, pid, request_id, state, got_text)
    }
    Ok(httpc.StreamEnd(id, _)) if id == request_id -> #(state, got_text)
    Ok(httpc.StreamStart(_, _, _)) ->
      stream_loop_ollama(selector, pid, request_id, state, got_text)
    _ -> #(state, got_text)
  }
}
