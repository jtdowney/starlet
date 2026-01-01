import envoy
import examples/utils
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import starlet/gemini

pub fn main() {
  let api_key = envoy.get("GEMINI_API_KEY") |> result.unwrap("")

  case api_key {
    "" -> io.println("Error: GEMINI_API_KEY environment variable not set")
    _ -> run_example(api_key)
  }
}

fn run_example(api_key: String) {
  let result = {
    use models <- result.try(gemini.list_models(api_key))

    io.println("Available Gemini models:")
    io.println("")
    list.each(models, fn(model) {
      io.println("  " <> model.id <> " (" <> model.display_name <> ")")
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
