import example_utils as utils
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import starlet
import starlet/gemini

pub fn main() {
  use api_key <- utils.require_env("GEMINI_API_KEY")
  run_example(api_key)
}

fn run_example(api_key: String) {
  let creds = gemini.credentials(api_key)

  let result = {
    use resp <- result.try(
      gemini.list_models_request(creds)
      |> httpc.send
      |> result.map_error(fn(_) { starlet.Transport("HTTP request failed") }),
    )
    use models <- result.try(gemini.list_models_response(resp))

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
    Error(err) -> io.println("Error: " <> starlet.error_to_string(err))
  }
}
