import gleam/option.{Some}
import starlet
import starlet/ollama
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

pub fn append_turn_adds_assistant_message_test() {
  let creds = ollama.credentials("http://localhost:11434")
  let chat =
    ollama.chat(creds, "qwen3")
    |> starlet.user("Hello")

  let turn =
    starlet.Turn(
      text: "Hi there!",
      tool_calls: [],
      ext: ollama.Ext(thinking: option.None, thinking_content: option.None),
    )

  let chat = starlet.append_turn(chat, turn)

  assert chat.messages
    == [starlet.UserMessage("Hello"), starlet.AssistantMessage("Hi there!", [])]
}

pub fn system_prompt_sets_before_messages_test() {
  let creds = ollama.credentials("http://localhost:11434")
  let chat =
    ollama.chat(creds, "qwen3")
    |> starlet.system("Be helpful")
    |> starlet.user("Hello")

  assert chat.system_prompt == Some("Be helpful")
}

pub fn temperature_is_set_test() {
  let creds = ollama.credentials("http://localhost:11434")
  let chat =
    ollama.chat(creds, "qwen3")
    |> starlet.temperature(0.7)
    |> starlet.user("Hello")

  assert chat.temperature == Some(0.7)
}

pub fn max_tokens_is_set_test() {
  let creds = ollama.credentials("http://localhost:11434")
  let chat =
    ollama.chat(creds, "qwen3")
    |> starlet.max_tokens(500)
    |> starlet.user("Hello")

  assert chat.max_tokens == Some(500)
}

pub fn assistant_adds_few_shot_example_test() {
  let creds = ollama.credentials("http://localhost:11434")
  let chat =
    ollama.chat(creds, "qwen3")
    |> starlet.user("What is 2+2?")
    |> starlet.assistant("4")
    |> starlet.user("What is 3+3?")

  assert chat.messages
    == [
      starlet.UserMessage("What is 2+2?"),
      starlet.AssistantMessage("4", []),
      starlet.UserMessage("What is 3+3?"),
    ]
}
