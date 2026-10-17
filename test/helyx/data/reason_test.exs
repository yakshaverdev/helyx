defmodule Helyx.ReasonTest do
  use ExUnit.Case, async: true

  # The label "Stacktrace:" is plain text, not a sign of a stack (#633).
  test "a message that holds the text \"Stacktrace:\" keeps its text" do
    message = "Parser could not read the field named Stacktrace:"

    assert Helyx.Reason.text(%RuntimeError{message: message}) == message
    assert Helyx.Reason.text({:error, message}) == inspect({:error, message})
  end

  # A provider process that stops with an exception (#760).
  test "an exception under an atom tag or in the exit of a call gives its message" do
    error = %RuntimeError{message: "codex: busy"}

    assert Helyx.Reason.text({:provider_stop, error}) == "codex: busy"
    assert Helyx.Reason.text({:provider_init, {:task_exit, error}}) == "codex: busy"
    assert Helyx.Reason.text({error, {GenServer, :call, [:x]}}) == "codex: busy"
    assert Helyx.Reason.text({:provider_error, :turn, error}) == "codex: busy"
    assert Helyx.Reason.text({:provider_error, :turn, {error, :stacktrace}}) == "codex: busy"

    assert Helyx.Reason.text({:provider_error, :turn, :refused}) ==
             inspect({:provider_error, :turn, :refused})

    assert Helyx.Reason.text({"tag", error}) == inspect({"tag", error})
  end
end
