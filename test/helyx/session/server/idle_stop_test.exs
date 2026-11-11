defmodule Helyx.Session.Server.IdleStopTest do
  # The idle stop of a session (docs/features/idle-unload.md): a session
  # that no one watches and that has no work stops with `{:shutdown, :idle}`,
  # and its file resumes. Each fact that holds the session is a test; the
  # subscriber, the ask, the no-file case, and nil are in
  # `idle_stop_hold_test.exs`.
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.Idle
  import Helyx.Test.SessionCase

  alias Helyx.{Message, Session}
  alias Helyx.Session.Server.Flow

  @moduletag :tmp_dir

  test "a session with a file and no subscriber stops for idleness, and its file resumes with its messages",
       %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider], sessions_dir: dir, idle_stop_ms: idle_ms())
    {:ok, session} = start(core, [])

    :ok = Session.prompt(session, "hello")

    assert down(session) == {:shutdown, :idle}
    assert Session.end_reason({:shutdown, :idle}) == :stopped
    assert Helyx.Sessions.list_live(core) == []

    await(
      fn -> Registry.lookup(Helyx.Core.sessions_registry(core), session.id) == [] end,
      "the session entry to leave the registry"
    )

    assert {:ok, resumed} = Helyx.Sessions.resume(core, id: session.id)
    assert resumed.id == session.id
    {:ok, snapshot, _ref} = Session.subscribe(resumed)

    assert Enum.map(snapshot.messages, &Message.text/1) == ["hello", "ok"]
  end

  test "a subscribe cancels the timer, and the end of the subscription arms it", %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider], sessions_dir: dir, idle_stop_ms: idle_ms())
    {:ok, session} = start(core, [])

    # The open armed the timer; the subscriber cancels it.
    watcher = watch(session)
    assert state(session).idle_stop == nil

    unwatch(watcher, session)

    assert down(session) == {:shutdown, :idle}
  end

  test "a prompt just before the timer starts a turn that cancels it", %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider], sessions_dir: dir, idle_stop_ms: idle_ms())
    gate = Helyx.Test.Gate.open()
    {:ok, session} = start(core, model: "test/gate." <> gate)

    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, run}
    assert %{phase: %{turn: _turn}, idle_stop: nil} = state(session)

    send(run, :go)
    assert down(session) == {:shutdown, :idle}
  end

  test "a queued text holds the session until the turn takes it", %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider], sessions_dir: dir, idle_stop_ms: idle_ms())
    {:ok, session} = start(core, model: "test/serial")
    watcher = watch(session)

    :ok = Session.prompt(session, "go")
    :ok = Session.follow_up(session, "next")

    assert %{phase: %{turn: _turn}, idle_stop: nil, queue: %{follow_ups: [_]}} = state(session)

    # The abort drops the queued text, and the turn ends.
    :ok = Session.abort(session)

    [%{messages: [dropped]}] = of_type(collect_until(:queue_dropped), :queue_dropped)
    assert Message.text(dropped) == "next"

    unwatch(watcher, session)
    assert down(session) == {:shutdown, :idle}
  end

  test "a live background run holds the session, and its end arms the timer", %{tmp_dir: dir} do
    core =
      start_core(
        [Helyx.Test.Provider, Helyx.Test.Tool.Background],
        sessions_dir: dir,
        idle_stop_ms: idle_ms()
      )

    gate = Helyx.Test.Gate.open()
    {:ok, session} = start(core, model: "test/bg." <> gate)
    watcher = watch(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, run}
    collect_until(:turn_end)

    # The turn ended and the run lives: the hands hold it, so no timer.
    unwatch(watcher, session)
    assert %{phase: %Flow.Idle{}, idle_stop: nil, queue: %{ends: %{running: 1}}} = state(session)

    # Its end starts a turn of its own, whose end arms the timer.
    send(run, :go)
    assert down(session) == {:shutdown, :idle}
  end
end
