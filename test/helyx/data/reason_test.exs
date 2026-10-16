defmodule Helyx.ReasonTest do
  use ExUnit.Case, async: true

  # The label "Stacktrace:" is plain text, not a sign of a stack (#633).
  test "a message that holds the text \"Stacktrace:\" keeps its text" do
    message = "Parser could not read the field named Stacktrace:"

    assert Helyx.Reason.text(%RuntimeError{message: message}) == message
    assert Helyx.Reason.text({:error, message}) == inspect({:error, message})
  end
end
