defmodule Helyx.Watchdog.HarnessStopTest do
  # The stop path of a harness process end to end (#199,
  # `docs/features/long-lived-harness.md`, "Stop"): a program under the
  # watchdog, a session, and the hands. The stop sends no end of input: the
  # closed port makes the watchdog stop the program group.
  use ExUnit.Case, async: true

  import Helyx.Test.OSHelpers

  alias Helyx.{Event, Session}
  alias Helyx.Test.WatchdogHarness

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [WatchdogHarness]})
    %{core: core}
  end

  defp start(core, model) do
    {:ok, session} = Session.start(core, model: "wdh/#{model}")
    on_exit(fn -> File.rm(WatchdogHarness.pid_path(session.id)) end)
    pid = Session.pid(session)
    :sys.replace_state(pid, &%{&1 | harness_ms: %{&1.harness_ms | turn: 300}})
    {:ok, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    {session, wait_for_pid(WatchdogHarness.pid_path(session.id))}
  end

  defp agent_end do
    receive do
      {:helyx_event, %Event{type: :agent_end} = event} -> event
      {:helyx_event, _event} -> agent_end()
    after
      5_000 -> flunk("no agent_end")
    end
  end

  test "a blocked callback: the armed kill stops the program group", %{core: core} do
    {_session, group} = start(core, "block")
    assert agent_end().data.error == :harness_timeout
    assert group_gone_within?(group, 300)
  end

  # The hands can take the close reply after the Core stopped its task
  # supervisor, so their release crashes and logs. The port closes with its
  # owner, the harness process, so the watchdog still ends the group.
  @tag :capture_log
  test "a Core stop with an idle harness process ends the program group", %{core: core} do
    {_session, group} = start(core, "idle")
    assert agent_end().data.stop_reason == :end_turn
    Process.flag(:trap_exit, true)
    :ok = stop_supervised(core)
    assert group_gone_within?(group, 300)
  end

  @tag :capture_log
  test "a Core stop during a connected turn ends the program group", %{core: core} do
    {_session, group} = start(core, "hang")
    Process.flag(:trap_exit, true)
    :ok = stop_supervised(core)
    assert group_gone_within?(group, 300)
  end

  test "input over the watchdog stdin cap stops the program group and fails the turn",
       %{core: core} do
    {_session, group} = start(core, "flood")
    assert {:harness_stop, _reason} = agent_end().data.error
    assert group_gone_within?(group, 300)
  end
end
