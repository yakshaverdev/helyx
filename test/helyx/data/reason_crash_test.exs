defmodule Helyx.ReasonCrashTest do
  # The crash handling of `Helyx.Reason.task/2` against linked processes and
  # the translator of Logger (#788). Not async, and with no capture of the
  # log but where a test asks for it: the tests add a log handler and a
  # filter of the default handler, and the capture handler waits for a
  # reply in the crashed process, which handles the exit signal of a linked
  # process there.
  use ExUnit.Case, async: false

  import Helyx.Test.Events, only: [wait_ms: 0]
  import Helyx.Test.SessionCase, only: [await: 2]

  @moduletag capture_log: false

  @secret "the text of a plugin crash"

  # In a process that holds `:hold_log`, the kind line of its crash tells
  # the test, and, with `:wait`, waits for `:go`. The default handler drops
  # the line.
  defmodule HoldLog do
    @moduledoc false
    def log(_event, _config) do
      case Process.get(:hold_log) do
        nil ->
          :ok

        {test, wait?} ->
          send(test, {:logging, self()})
          if wait?, do: receive(do: (:go -> :ok))
      end
    end

    def drop(event, _extra), do: if(Process.get(:hold_log), do: :stop, else: event)
  end

  setup do
    id = :"hold_log_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, HoldLog, %{})
    _ = :logger.add_handler_filter(:default, id, {&HoldLog.drop/2, nil})

    on_exit(fn ->
      :logger.remove_handler(id)
      :logger.remove_handler_filter(:default, id)
    end)

    %{sup: start_supervised!(Task.Supervisor)}
  end

  # A Task whose body links a child, maybe traps exits, and raises; the
  # kind line of its crash holds it with `wait?`.
  defp crash(sup, trap?, wait?) do
    test = self()

    Task.Supervisor.async_nolink(sup, fn ->
      Helyx.Reason.task("x crashed", fn ->
        Process.flag(:trap_exit, trap?)
        send(test, {:child, spawn_link(fn -> Process.sleep(:infinity) end)})
        Process.put(:hold_log, {test, wait?})
        raise @secret
      end)
    end)
  end

  # The kind line waits in a receive, which handles the exit signal of the
  # child: the test goes on when the process is dead or holds the message.
  test "a linked child that ends while a crash is handled does not change the reason",
       %{sup: sup} do
    for _run <- 1..20 do
      task = crash(sup, false, true)
      assert_receive {:child, child}
      assert_receive {:logging, pid}
      Process.exit(child, :kill)

      await(
        fn ->
          case Process.info(pid, :messages) do
            nil -> true
            {:messages, messages} -> {:EXIT, child, :killed} in messages
          end
        end,
        "the exit signal of the child"
      )

      send(pid, :go)
      assert {:exit, {%RuntimeError{}, [_ | _]}} = Task.yield(task, wait_ms())
    end
  end

  # The merge gate of #788: a body that traps exits, and a child that ends
  # just after the kind line. A mechanism that turned the trap off for an
  # exit signal to itself failed in about one run in ten, and in some runs
  # of 200 in none.
  test "a linked child that ends after the kind line of a body that traps exits does not change the reason",
       %{sup: sup} do
    for _run <- 1..1_000 do
      task = crash(sup, true, false)
      assert_receive {:child, child}
      assert_receive {:logging, _pid}
      Process.exit(child, :kill)
      assert {:exit, {%RuntimeError{}, [_ | _]}} = Task.yield(task, wait_ms())
    end
  end

  # The translator of Logger calls the `message/1` of an exception, before
  # the level filter, and rescues its raise. A `message/1` that throws or
  # exits is the stated hole (docs/features/session-lifecycle.md, "Log and
  # crash reports").
  test "an exception whose message/1 raises logs the kind line only, and the translator stays",
       %{sup: sup} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        task =
          Task.Supervisor.async_nolink(sup, fn ->
            Helyx.Reason.task("x crashed", fn -> raise Helyx.Test.RaiseMessage, code: @secret end)
          end)

        assert {:exit, {%Helyx.Test.RaiseMessage{}, [_ | _]}} = Task.yield(task, wait_ms())
      end)

    assert log =~ "x crashed: Helyx.Test.RaiseMessage"
    refute log =~ @secret
    assert List.keymember?(:logger.get_primary_config().filters, :logger_translator, 0)
  end
end
