import examples/utils
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import starlet
import starlet/ollama

pub fn main() {
  let creds = ollama.credentials("http://localhost:11434")

  let result = {
    let req = ollama.list_models_request(creds)
    use resp <- result.try(
      httpc.send(req)
      |> result.map_error(fn(_) { starlet.Http(500, "HTTP request failed") }),
    )
    use models <- result.try(ollama.list_models_response(resp))

    io.println("Available models:")
    io.println("")
    list.each(models, fn(model) {
      io.println("  " <> model.name <> " (" <> model.size <> ")")
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
