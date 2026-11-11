defmodule Helyx.Session.Server.IdleStopHoldTest do
  # The facts that hold a session from the idle stop
  # (docs/features/idle-unload.md): a subscriber, an open ask, a session with
  # no file, and nil. The stop and the load are in `idle_stop_test.exs`.
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.Idle
  import Helyx.Test.SessionCase

  alias Helyx.{Event, Session}

  @moduletag :tmp_dir

  test "a subscriber holds the session", %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider], sessions_dir: dir, idle_stop_ms: idle_ms())
    {:ok, session} = start(core, [])
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")

    # A wait that must not happen: the idle time, the stop of the session, and
    # load on the machine.
    Process.sleep(idle_ms() + load_ms())

    assert is_pid(Session.pid(session))
    assert state(session).idle_stop == nil
  end

  test "an open ask holds the session, and its answer ends the turn", %{tmp_dir: dir} do
    core =
      start_core(
        [Helyx.Test.Provider, Helyx.Test.Tool.Ask],
        sessions_dir: dir,
        idle_stop_ms: idle_ms()
      )

    {:ok, session} = start(core, model: "test/ask")
    watcher = watch(session, answers: true)

    :ok = Session.prompt(session, "go")
    assert %Event{data: %{ask_id: ask_id}} = List.last(collect_until(:ask))

    # The ask waits inside the turn; the turn holds the session, and so does
    # the subscriber. The check reads the ask too, so a session with an open
    # ask never unloads.
    Process.sleep(idle_ms() + load_ms())
    assert is_pid(Session.pid(session))
    assert state(session).idle_stop == nil

    :ok = Session.answer(session, ask_id, %{"q" => "one"})
    assert [%{outcome: :done}] = of_type(collect_until(:turn_end), :turn_end)

    unwatch(watcher, session)
    assert down(session) == {:shutdown, :idle}
  end

  test "a session with no file never unloads" do
    core = start_core([Helyx.Test.Provider], idle_stop_ms: idle_ms())
    {:ok, session} = start(core, [])

    Process.sleep(idle_ms() + load_ms())

    assert %{save: :never, idle_stop: nil} = state(session)
    assert is_pid(Session.pid(session))
  end

  test "nil turns the rule off", %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider], sessions_dir: dir)
    {:ok, session} = start(core, [])

    :ok = Session.prompt(session, "hello")
    Process.sleep(idle_ms() + load_ms())

    assert %{idle_stop_ms: nil, idle_stop: nil} = state(session)
    assert is_pid(Session.pid(session))
  end

  test "the smallest idle stop of 1 ms starts" do
    core = start_core([Helyx.Test.Provider], idle_stop_ms: 1)
    assert Helyx.Core.config(core, :idle_stop_ms) == 1
  end

  test "a Core start with a bad idle stop gives its error" do
    for bad <- [0, -1, 1.5, "100", :never] do
      assert {:error, {:invalid_option, :idle_stop_ms}} =
               Helyx.Core.start_link(
                 name: :"core_#{System.unique_integer([:positive])}",
                 plugins: [Helyx.Test.Provider],
                 idle_stop_ms: bad
               )
    end
  end
end
