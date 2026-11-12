defmodule Helyx.Session.Server.IdleStopTest do
  # The idle stop of a session (docs/features/idle-unload.md): a session
  # that no one watches and that has no work stops with `{:shutdown, :idle}`,
  # and its file resumes. Each fact that holds the session is a test; the
  # subscriber, the ask, the no-file case, and nil are in
  # `idle_stop_hold_test.exs`.
  #
  # The Core of each test starts with no idle option, so the open arms no
  # timer and no step races the wait; a test sets the value and arms the
  # timer when its session is ready (`Helyx.Test.Idle.quiet/2`).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.Idle
  import Helyx.Test.SessionCase

  alias Helyx.{Message, Session}
  alias Helyx.Session.Server.Flow

  @moduletag :tmp_dir

  test "a session with a file and no subscriber stops for idleness, and its file resumes with its messages",
       %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider], sessions_dir: dir)
    {:ok, session} = start(core, [])
    watcher = watch(session)

    :ok = Session.prompt(session, "hello")
    collect_until(:turn_end)

    set_idle(session)
    {pid, ref} = monitor(session)
    unwatch(watcher, session)

    assert down({pid, ref}) == {:shutdown, :idle}
    assert Session.end_reason({:shutdown, :idle}) == :stopped
    assert Helyx.Sessions.list_live(core) == []

    await(
      fn -> Registry.lookup(Helyx.Core.sessions_registry(core), session.id) == [] end,
      "the session entry to leave the registry"
    )

    assert {:ok, resumed, _origin} = Helyx.Sessions.resume(core, id: session.id)
    assert resumed.id == session.id
    {:ok, snapshot, _ref} = Session.subscribe(resumed)

    assert Enum.map(snapshot.messages, &Message.text/1) == ["hello", "ok"]
  end

  test "a subscribe cancels the timer, and the end of the subscription arms it", %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider], sessions_dir: dir)
    {:ok, session} = start(core, [])

    # A timer that cannot fire while the test subscribes, then the subscriber
    # cancels it, and the end of the subscription arms a short one.
    quiet(session, 60_000)
    watcher = watch(session)
    assert state(session).idle_stop == nil

    set_idle(session)
    {pid, ref} = monitor(session)
    unwatch(watcher, session)

    assert down({pid, ref}) == {:shutdown, :idle}
  end

  test "an attach of a resume arms the full wait again", %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider], sessions_dir: dir, idle_stop_ms: 60_000)
    {:ok, session} = start(core, [])
    before = state(session).idle_stop

    # A resume of the running session attaches, and the client gets the whole
    # wait for its subscribe: the timer is armed again.
    assert {:ok, ^session, :attached} =
             Helyx.Sessions.resume(core, id: session.id)

    after_attach = state(session).idle_stop
    assert is_reference(after_attach) and after_attach != before
  end

  test "a prompt just before the timer starts a turn that cancels it", %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider], sessions_dir: dir)
    gate = Helyx.Test.Gate.open()
    {:ok, session} = start(core, model: "test/gate." <> gate)

    quiet(session, 60_000)
    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, run}
    assert %{phase: %{turn: _turn}, idle_stop: nil} = state(session)

    set_idle(session)
    {pid, ref} = monitor(session)
    send(run, :go)

    assert down({pid, ref}) == {:shutdown, :idle}
  end

  test "a queued text holds the session until the turn takes it", %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider], sessions_dir: dir)
    {:ok, session} = start(core, model: "test/serial")
    watcher = watch(session)

    :ok = Session.prompt(session, "go")
    :ok = Session.follow_up(session, "next")

    assert %{phase: %{turn: _turn}, idle_stop: nil, queue: %{follow_ups: [_]}} = state(session)

    # The abort drops the queued text, and the turn ends.
    :ok = Session.abort(session)

    [%{messages: [dropped]}] = of_type(collect_until(:queue_dropped), :queue_dropped)
    assert Message.text(dropped) == "next"

    set_idle(session)
    {pid, ref} = monitor(session)
    unwatch(watcher, session)

    assert down({pid, ref}) == {:shutdown, :idle}
  end

  test "a live background run holds the session, and its end arms the timer", %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider, Helyx.Test.Tool.Background], sessions_dir: dir)
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
    set_idle(session)
    {pid, ref} = monitor(session)
    send(run, :go)

    assert down({pid, ref}) == {:shutdown, :idle}
  end
end
