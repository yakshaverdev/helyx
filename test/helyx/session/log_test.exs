defmodule Helyx.Session.LogTest do
  # The log of a session holds no message text (#756,
  # docs/features/session-lifecycle.md, "Log and crash reports").
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.Session

  setup :start_core

  @prompt "the prompt text of the user"
  @secret "the text of a stray message"

  # The lines of one process: the tests that run at the same time also log.
  defp lines(log, pid) do
    pid = "pid=#{:erlang.pid_to_list(pid)}"
    log |> String.split("\n") |> Enum.filter(&(&1 =~ pid))
  end

  # A crash of `pid` by `fun`, with the log of the whole node.
  defp crash_log(pid, fun) do
    ref = Process.monitor(pid)

    capture_log([metadata: [:pid]], fn ->
      fun.()
      assert_receive {:DOWN, ^ref, :process, _, _}, wait_ms()
    end)
  end

  test "a failed turn logs the kind of its reason, and the client gets its text", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/exception_error")
    {:ok, _, _} = Session.subscribe(session)

    {events, log} =
      with_log([metadata: [:pid]], fn ->
        :ok = Session.prompt(session, @prompt)
        collect_until(:turn_end)
      end)

    assert List.last(events).data.error == "rate limited"
    assert [line] = lines(log, Session.pid(session))
    assert line =~ "turn failed: RuntimeError"
    refute log =~ "rate limited"
    refute log =~ @prompt
  end

  test "the crash report of the session process holds no message text", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, @prompt)
    collect_until(:turn_end)
    pid = Session.pid(session)

    # No clause takes this message: the session crashes, with the message
    # and the state, which holds the prompt, in the arguments of the call.
    log = crash_log(pid, fn -> send(pid, {:stray, @secret}) end)

    assert [line] = lines(log, pid)
    assert line =~ "terminating"
    assert log =~ "Helyx.Session.Server.TurnLoop.handle/2"
    assert log =~ ~s{** (stop) ":function_clause"}
    refute log =~ @prompt
    refute log =~ @secret
  end

  test "the crash report of the hands holds no message text", %{core: core} do
    state = %Session.Hands.State{
      core: core,
      cwd: File.cwd!(),
      background_dir: Path.join(System.tmp_dir!(), "helyx-log-#{System.unique_integer()}"),
      session: self(),
      tools: %{}
    }

    {:ok, hands} = GenServer.start(Session.Hands, state)
    log = crash_log(hands, fn -> catch_exit(GenServer.call(hands, {:stray, @secret})) end)

    assert [line] = lines(log, hands)
    assert line =~ "terminating"
    assert log =~ ~s{** (stop) ":function_clause"}
    refute log =~ @secret
  end

  test "the crash report of the sync worker holds no message text" do
    {:ok, sync} = GenServer.start(Session.Sync, {Helyx.Test.Memory, [], self()})
    log = crash_log(sync, fn -> send(sync, {:stray, @secret}) end)

    assert [line] = lines(log, sync)
    assert line =~ "terminating"
    assert log =~ ~s{** (stop) ":function_clause"}
    refute log =~ @secret
  end
end
