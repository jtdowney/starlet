import example_utils as utils
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import starlet
import starlet/openai

pub fn main() {
  use api_key <- utils.require_env("OPENAI_API_KEY")
  run_example(api_key)
}

fn run_example(api_key: String) {
  let creds = openai.credentials(api_key)

  let result = {
    use resp <- result.try(
      openai.list_models_request(creds)
      |> httpc.send
      |> result.map_error(fn(_) { starlet.Transport("HTTP request failed") }),
    )
    use models <- result.try(openai.list_models_response(resp))

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
