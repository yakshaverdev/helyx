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

  @secret "the text of a message"

  # A log line holds the kind of a term and no text of it (#756).
  test "the log line of a term holds its kind only" do
    stack = [{__MODULE__, :f, [@secret], [file: ~c"m.ex", line: 1]}]

    for {reason, kind} <- [
          {%RuntimeError{message: @secret}, "RuntimeError"},
          {{:task_exit, {%RuntimeError{message: @secret}, stack}}, ":task_exit"},
          {{{:badmatch, @secret}, stack}, ":badmatch"},
          {:provider_timeout, ":provider_timeout"},
          {@secret, "term"},
          {[@secret], "term"},
          {%{@secret => @secret}, "term"},
          {{@secret, :tag}, "term"},
          {{}, "term"}
        ] do
      log = ExUnit.CaptureLog.capture_log(fn -> Helyx.Reason.log("turn failed", reason) end)
      assert log =~ "turn failed: #{kind}\n"
      refute log =~ @secret
    end
  end

  # A term with no message text keeps its term, with a bound.
  test "the log line of a whole term keeps its strings to 160 characters" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Helyx.Reason.log_term("a resource could not be released", [String.duplicate("a", 1000)])
      end)

    assert log =~
             ~s(a resource could not be released: [") <>
               String.duplicate("a", 160) <> ~s(" <> ...])
  end

  test "a crash status holds no state, no message, no debug log, and the kind of the reason" do
    status = %{
      state: %{transcript: @secret},
      message: {:stream_event, "t1", {:text_delta, @secret}},
      log: [{:in, @secret}],
      reason: {:badmatch, @secret}
    }

    assert Helyx.Reason.crash_status(status) ==
             %{state: :redacted, message: :redacted, log: [], reason: ":badmatch"}

    # The status of `:sys.get_status/1` has no message and no reason.
    assert Helyx.Reason.crash_status(%{state: @secret, log: []}) == %{state: :redacted, log: []}
  end

  defp only(:atom), do: :ok

  # A function clause error and a failed BIF keep the arguments in a frame.
  test "a raise, a throw, or an exit goes on with no argument in its frames" do
    for {class, fun} <- [
          {:error, &only/1},
          {:error, &String.to_integer/1},
          {:throw, fn value -> throw(value) end},
          {:exit, fn value -> exit(value) end}
        ] do
      {caught, reason, stack} =
        try do
          Helyx.Reason.no_args(fn -> fun.(@secret) end)
        catch
          class, reason -> {class, reason, __STACKTRACE__}
        end

      assert caught == class
      assert reason in [@secret, :function_clause, :badarg]
      assert stack != []
      refute inspect(stack) =~ @secret
    end

    assert Helyx.Reason.no_args(fn -> :value end) == :value
  end
end
