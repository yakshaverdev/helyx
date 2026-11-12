defmodule Helyx.Session.Server.FeedTest do
  # The session feed of a Core (docs/features/session-feed.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Event, Session, Sessions}
  alias Helyx.Sessions.Live
  alias Helyx.Test.Events

  @moduletag :tmp_dir

  setup :start_core

  defp start_session(core), do: Sessions.start(core, cwd: "/repo", model: "test/ok")

  defp turn(session, text) do
    {:ok, _, ref} = Session.subscribe(session)
    :ok = Session.prompt(session, text)
    collect_until(:turn_end)
    Process.demonitor(ref, [:flush])
  end

  # The next notice of the feed, which may be a Live or an event.
  defp next_feed do
    receive do
      {:helyx_feed, _pid, notice} -> notice
    after
      Events.wait_ms() -> flunk("no feed message")
    end
  end

  # The notices of one turn, from the first to the Live that ends it. The
  # caller consumed the Live of the start.
  defp turn_feed do
    receive do
      {:helyx_feed, _pid, %Live{status: :idle} = live} -> [live]
      {:helyx_feed, _pid, notice} -> [notice | turn_feed()]
    after
      Events.wait_ms() -> flunk("no feed message")
    end
  end

  # A watcher process of its own, which sends every notice to the test as
  # `{:watched, notice}`, so that one test can watch twice.
  defp forwarder(core, types) do
    parent = self()

    spawn(fn ->
      {:ok, dropped} = Sessions.watch(core, types)
      send(parent, {:watching, dropped})
      forward(parent, Process.monitor(parent))
    end)
  end

  defp forward(parent, monitor) do
    receive do
      {:helyx_feed, _pid, notice} ->
        send(parent, {:watched, notice})
        forward(parent, monitor)

      {:DOWN, ^monitor, :process, ^parent, _reason} ->
        :ok
    end
  end

  test "a watcher gets the Live of a start, then running and idle around a turn", %{core: core} do
    assert {:ok, _dropped} = Sessions.watch(core, [])
    {:ok, session} = start_session(core)
    pid = Session.pid(session)

    assert_receive {:helyx_feed, ^pid, %Live{instance_id: instance} = started}
    assert %Live{id: id, cwd: "/repo", model: "test/ok", status: :idle} = started
    assert id == session.id

    turn(session, "hi")

    assert [%Live{status: :running} = running, %Live{status: :idle} = idle] = turn_feed()
    assert running.instance_id == instance
    assert idle.instance_id == instance
  end

  test "the Live of a status comes before the events of that status", %{core: core} do
    assert {:ok, _dropped} = Sessions.watch(core, [:turn_start, :turn_end])
    {:ok, session} = start_session(core)
    assert %Live{status: :idle} = next_feed()

    turn(session, "hi")

    assert [%Live{status: :running}, %Event{type: :turn_start}, %Event{type: :turn_end}] =
             turn_feed() |> Enum.drop(-1)
  end

  test "a watcher gets only the event types it named", %{core: core} do
    assert {:ok, _dropped} = Sessions.watch(core, [:message_end])
    forwarder(core, [])
    assert_receive {:watching, _dropped}

    {:ok, session} = start_session(core)
    turn(session, "hi")

    assert %Live{status: :idle} = next_feed()
    notices = turn_feed()
    assert %Live{status: :running} = hd(notices)
    assert %Live{status: :idle} = List.last(notices)

    # The turn emits message updates; only its ends reach this watcher.
    types = for %Event{type: type} <- notices, do: type
    assert types != []
    refute :message_update in types
    assert Enum.all?(types, &(&1 == :message_end))

    # A watcher that named no type gets no event at all: the Live that ends
    # the turn comes after every event of it, so none is on its way.
    assert_receive {:watched, %Live{status: :idle}}
    assert_receive {:watched, %Live{status: :running}}
    assert_receive {:watched, %Live{status: :idle}}
    refute_received {:watched, %Event{}}
  end

  test "a resume sends a Live with a new instance id", %{core: core} do
    assert {:ok, _dropped} = Sessions.watch(core, [])
    {:ok, session} = start_session(core)
    turn(session, "hi")
    assert %Live{instance_id: instance} = next_feed()
    assert %Live{instance_id: ^instance} = turn_feed() |> List.last()
    :ok = Sessions.stop(session)

    # A stop sends no notice; the resume opens a new instance.
    assert {:ok, resumed, _} = Sessions.resume(core, id: session.id)
    assert_receive {:helyx_feed, pid, %Live{instance_id: other}}

    assert pid == Session.pid(resumed)
    assert other != instance
  end

  test "a model change sends a Live with the new model, before the :model_change event",
       %{core: core} do
    assert {:ok, _dropped} = Sessions.watch(core, [:model_change])
    {:ok, session} = start_session(core)
    assert %Live{model: "test/ok"} = next_feed()

    assert :ok = Session.set_model(session, "test/other")

    assert %Live{model: "test/other"} = next_feed()
    assert %Event{type: :model_change, data: %{model: "test/other"}} = next_feed()
  end

  test "the Live of a child names its parent; a resume of the child keeps it", %{core: core} do
    assert {:ok, _dropped} = Sessions.watch(core, [])
    {:ok, parent_session} = start_session(core)
    link = %{session_id: parent_session.id, call_id: "call-1"}

    {:ok, child} =
      Sessions.start(core, cwd: "/repo", model: "test/ok", parent: link)

    assert_receive {:helyx_feed, pid, %Live{id: id, parent: ^link}}
    assert id == child.id
    assert pid == Session.pid(child)

    :ok = Sessions.stop(child)
    assert {:ok, resumed, :started} = Sessions.resume(core, id: child.id)
    assert_receive {:helyx_feed, pid, %Live{id: ^id, parent: ^link}}
    assert pid == Session.pid(resumed)
  end

  test "the Live of the feed equals the entry of list_live/1", %{core: core} do
    assert {:ok, _dropped} = Sessions.watch(core, [])
    {:ok, session} = start_session(core)
    turn(session, "hi")
    assert %Live{} = next_feed()
    live = turn_feed() |> List.last()

    assert [^live] = Sessions.list_live(core)
    assert live.id == session.id
  end

  test "a second watch replaces the first; unwatch ends the notices", %{core: core} do
    assert {:ok, _first} = Sessions.watch(core, [])
    assert {:ok, _second} = Sessions.watch(core, [])
    {:ok, session} = start_session(core)
    turn(session, "hi")
    assert %Live{status: :idle} = next_feed()

    # One copy of each notice, not one for each watch.
    assert [%Live{status: :running}, %Live{status: :idle}] = turn_feed()

    :ok = Sessions.unwatch(core)
    forwarder(core, [])
    assert_receive {:watching, _dropped}
    {:ok, other} = start_session(core)
    assert_receive {:watched, %Live{id: id}}
    assert id == other.id

    # The call to the session runs after its open, so its Live went out.
    assert [_, _] = Sessions.list_live(core)
    refute_received {:helyx_feed, _pid, _notice}
  end

  test "watch refuses an unknown type and a non-list", %{core: core} do
    assert Sessions.watch(core, [:no_such_type]) == {:error, :invalid_types}
    assert Sessions.watch(core, :turn_end) == {:error, :invalid_types}
    assert Sessions.watch(core, [:turn_end, "message_end"]) == {:error, :invalid_types}
  end

  test "past max_feed_queue/0 the session drops and counts, and goes on", %{core: core} do
    parent = self()

    watcher =
      spawn(fn ->
        {:ok, dropped} = Sessions.watch(core, [])
        send(parent, {:watching, dropped})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:watching, dropped}
    max = Sessions.max_feed_queue()
    for _ <- 1..max, do: send(watcher, :filler)
    wait_until(fn -> Process.info(watcher, :message_queue_len) == {:message_queue_len, max} end)

    {:ok, session} = start_session(core)
    turn(session, "hi")

    assert Sessions.dropped(dropped) > 0
    # One session sends, and each of its notices is dropped at the bound.
    assert Process.info(watcher, :message_queue_len) == {:message_queue_len, max}
    send(watcher, :stop)
  end

  test "a stop sends no notice; the monitor of the envelope pid gets the :DOWN", %{core: core} do
    assert {:ok, _dropped} = Sessions.watch(core, [])
    {:ok, session} = start_session(core)
    assert_receive {:helyx_feed, pid, %Live{}}
    assert pid == Session.pid(session)

    ref = Process.monitor(pid)
    :ok = Sessions.stop(session)

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}
    assert Session.end_reason(reason) == :stopped
    refute_received {:helyx_feed, _pid, _notice}
  end
end
