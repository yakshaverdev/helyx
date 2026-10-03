defmodule Helyx.Watchdog.HarnessStopTest do
  # The stop path of a provider process end to end (#199,
  # `docs/features/long-lived-harness.md`, "Stop"): a program under the
  # watchdog, a session, and the hands. The stop sends no end of input: the
  # closed port makes the watchdog stop the program group.
  use ExUnit.Case, async: true

  import Helyx.Test.OSHelpers

  alias Helyx.Session
  alias Helyx.Test.WatchdogHarness

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [WatchdogHarness]})
    %{core: core}
  end

  # The default turn deadline, 60 s, is longer than the wait of
  # `agent_end/0`, the cap of a wait. Thus the deadline does not end the turn
  # in a test that does not set one (#228).
  defp start(core, model, turn_ms \\ 60_000) do
    {:ok, session} = Session.start(core, model: "wdh/#{model}")
    on_exit(fn -> File.rm(WatchdogHarness.pid_path(session.id)) end)
    pid = Session.pid(session)
    :sys.replace_state(pid, &%{&1 | provider_ms: %{&1.provider_ms | turn: turn_ms}})
    {:ok, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    {session, wait_for_pid(WatchdogHarness.pid_path(session.id))}
  end

  defp agent_end, do: List.last(Helyx.Test.Events.collect_until(:agent_end))

  test "a blocked callback: the armed kill stops the program group", %{core: core} do
    {_session, group} = start(core, "block", 300)
    assert agent_end().data.error == :provider_timeout
    assert group_gone_within?(group)
  end

  # The session stops its hands before it ends, so the hands never run a
  # release after the Core stopped its task supervisor (#219): they end with
  # `:shutdown`, not a crash, before the Core stop returns.
  test "a Core stop with an idle provider process ends the program group", %{core: core} do
    {session, group} = start(core, "idle")
    assert agent_end().data.stop_reason == :end_turn
    hands = monitor_hands(session)
    Process.flag(:trap_exit, true)
    :ok = stop_supervised(core)
    assert_received {:DOWN, ^hands, :process, _, :shutdown}
    assert group_gone_within?(group)
  end

  test "a Core stop during a connected turn ends the program group", %{core: core} do
    {session, group} = start(core, "hang")
    hands = monitor_hands(session)
    Process.flag(:trap_exit, true)
    :ok = stop_supervised(core)
    assert_received {:DOWN, ^hands, :process, _, :shutdown}
    assert group_gone_within?(group)
  end

  defp monitor_hands(session),
    do: Process.monitor(:sys.get_state(Session.pid(session)).hands)

  # The watchdog exits with the command's status, or the port closes with
  # `:epipe` when a part of the write still waits in it, and that exit
  # signal ends the provider process (#390).
  test "input over the watchdog stdin cap stops the program group and fails the turn",
       %{core: core} do
    {_session, group} = start(core, "flood")
    error = agent_end().data.error
    assert match?({:provider_stop, {:exit_status, _}}, error) or error == {:task_exit, :epipe}
    assert group_gone_within?(group)
  end
end
