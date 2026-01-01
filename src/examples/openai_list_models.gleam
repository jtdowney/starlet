import envoy
import examples/utils
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import starlet/openai

pub fn main() {
  let api_key = envoy.get("OPENAI_API_KEY") |> result.unwrap("")

  case api_key {
    "" -> io.println("Error: OPENAI_API_KEY environment variable not set")
    _ -> run_example(api_key)
  }
}

fn run_example(api_key: String) {
  let result = {
    use models <- result.try(openai.list_models(api_key))

    io.println("Available models:")
    io.println("")
    list.each(models, fn(model) {
      io.println("  " <> model.id <> " (owned by: " <> model.owned_by <> ")")
    })
    io.println("")
    io.println("Total: " <> int.to_string(list.length(models)) <> " models")

    Ok(Nil)
  }

  case result {
    Ok(_) -> Nil
    Error(err) -> io.println("Error: " <> utils.error_to_string(err))
  }
}
