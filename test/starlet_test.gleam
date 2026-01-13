import gleam/int
import gleam/list
import gleam/option.{Some}
import starlet.{Decode, Response, Transport}
import unitest

pub fn main() -> Nil {
  unitest.run(
    unitest.Options(..unitest.default_options(), ignored_tags: ["integration"]),
  )
}

pub fn turn_text_accessor_test() {
  let turn = starlet.make_turn_for_testing("Hello world")
  assert starlet.text(turn) == "Hello world"
}

pub fn send_returns_turn_with_response_text_test() {
  let client =
    starlet.mock_client(fn(_req) {
      Ok(Response(text: "I am a helpful assistant", tool_calls: []))
    })

  let chat =
    starlet.chat(client, "qwen3")
    |> starlet.user("Hello")

  let assert Ok(#(_new_chat, turn)) = starlet.send(chat)
  assert starlet.text(turn) == "I am a helpful assistant"
}

pub fn send_propagates_error_test() {
  let client =
    starlet.mock_client(fn(_req) { Error(Transport("connection failed")) })

  let chat =
    starlet.chat(client, "qwen3")
    |> starlet.user("Hello")

  let assert Error(Transport("connection failed")) = starlet.send(chat)
}

pub fn send_includes_system_prompt_in_request_test() {
  let client =
    starlet.mock_client(fn(req) {
      assert req.system_prompt == Some("Be concise")
      Ok(Response(text: "ok", tool_calls: []))
    })

  let chat =
    starlet.chat(client, "qwen3")
    |> starlet.system("Be concise")
    |> starlet.user("Hello")

  let assert Ok(_) = starlet.send(chat)
}

pub fn send_includes_temperature_in_request_test() {
  let client =
    starlet.mock_client(fn(req) {
      assert req.temperature == Some(0.5)
      Ok(Response(text: "ok", tool_calls: []))
    })

  let chat =
    starlet.chat(client, "qwen3")
    |> starlet.temperature(0.5)
    |> starlet.user("Hello")

  let assert Ok(_) = starlet.send(chat)
}

pub fn send_includes_max_tokens_in_request_test() {
  let client =
    starlet.mock_client(fn(req) {
      assert req.max_tokens == Some(500)
      Ok(Response(text: "ok", tool_calls: []))
    })

  let chat =
    starlet.chat(client, "qwen3")
    |> starlet.max_tokens(500)
    |> starlet.user("Hello")

  let assert Ok(_) = starlet.send(chat)
}

pub fn send_appends_assistant_response_to_history_test() {
  let client =
    starlet.mock_client(fn(req) {
      case list.length(req.messages) {
        1 -> Ok(Response(text: "First response", tool_calls: []))
        3 -> Ok(Response(text: "Second response", tool_calls: []))
        n -> Error(Decode("unexpected: " <> int.to_string(n)))
      }
    })

  let chat =
    starlet.chat(client, "qwen3")
    |> starlet.user("Hello")

  let assert Ok(#(chat, _turn)) = starlet.send(chat)

  let chat = starlet.user(chat, "Follow up")
  let assert Ok(#(_chat, turn)) = starlet.send(chat)
  assert starlet.text(turn) == "Second response"
}

pub fn assistant_adds_few_shot_example_test() {
  let client =
    starlet.mock_client(fn(req) {
      assert list.length(req.messages) == 3
      Ok(Response(text: "ok", tool_calls: []))
    })

  let chat =
    starlet.chat(client, "qwen3")
    |> starlet.user("What is 2+2?")
    |> starlet.assistant("4")
    |> starlet.user("What is 3+3?")

  let assert Ok(_) = starlet.send(chat)
}
