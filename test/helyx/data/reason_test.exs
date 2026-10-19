defmodule Helyx.ReasonTest do
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [wait_ms: 0]

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

  # The body of a Task of plugin code (#788).
  test "a crash in a Task logs its kind, and the Task ends with the reason of a Task crash" do
    sup = start_supervised!(Task.Supervisor)

    # The result of the Task, and the log lines of its pid: the tests that
    # run at the same time also log. A report of `Task` is a line too.
    run = fn fun ->
      {{pid, result}, log} =
        ExUnit.CaptureLog.with_log([metadata: [:pid]], fn ->
          task = Task.Supervisor.async_nolink(sup, fn -> Helyx.Reason.task("x crashed", fun) end)
          {task.pid, Task.yield(task, wait_ms())}
        end)

      pid = "pid=#{:erlang.pid_to_list(pid)}"
      {result, log |> String.split("\n") |> Enum.filter(&(&1 =~ pid)), log}
    end

    for {fun, kind, expected?} <- [
          {&only/1, ":function_clause",
           &match?({:function_clause, [{__MODULE__, :only, 1, _} | _]}, &1)},
          {fn value -> throw(value) end, ":nocatch", &match?({{:nocatch, @secret}, [_ | _]}, &1)},
          {fn value -> exit(value) end, "term", &(&1 == @secret)},
          # A trap of exits that plugin code set does not keep the Task.
          {fn value ->
             Process.flag(:trap_exit, true)
             raise value
           end, "RuntimeError", &match?({%RuntimeError{}, [_ | _]}, &1)}
        ] do
      {result, lines, log} = run.(fn -> fun.(@secret) end)

      assert {:exit, reason} = result
      assert expected?.(reason)
      # One line and no report of `Task`.
      assert [line] = lines
      assert line =~ "x crashed: #{kind}"
      refute log =~ @secret
    end

    # An atom gets the report of `Task`, and `:kill` stays `:kill`: a signal
    # would make it `:killed`. A shutdown gets no report.
    {result, [line], _log} = run.(fn -> exit(:kill) end)
    assert result == {:exit, :kill}
    assert line =~ "terminating"

    {result, lines, _log} = run.(fn -> exit({:shutdown, @secret}) end)
    assert result == {:exit, {:shutdown, @secret}}
    assert lines == []

    assert Helyx.Reason.task("x crashed", fn -> :value end) == :value
  end
end
