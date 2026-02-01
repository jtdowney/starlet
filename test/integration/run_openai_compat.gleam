import gleam/io
import integration/fireworks_test
import integration/synthetic_test
import integration/together_test

pub fn main() {
  io.println("fireworks: simple_chat_test")
  fireworks_test.simple_chat_test()
  io.println("fireworks: tool_calling_test")
  fireworks_test.tool_calling_test()
  io.println("fireworks: json_output_test")
  fireworks_test.json_output_test()
  io.println("fireworks: reasoning_test")
  fireworks_test.reasoning_test()

  io.println("synthetic: simple_chat_test")
  synthetic_test.simple_chat_test()
  io.println("synthetic: json_output_test")
  synthetic_test.json_output_test()
  io.println("synthetic: reasoning_test")
  synthetic_test.reasoning_test()

  io.println("together: simple_chat_test")
  together_test.simple_chat_test()
  io.println("together: tool_calling_test")
  together_test.tool_calling_test()
  io.println("together: json_output_test")
  together_test.json_output_test()
  io.println("together: reasoning_test")
  together_test.reasoning_test()

  io.println("✓ All tests passed!")
}
