defmodule Helyx.Session.ReplayTest do
  # The replay ring, the resubscribe with `after`, and the credits of a
  # subscriber (docs/features/replay-ring.md, #659).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Event, Session}
  alias Helyx.Session.{Ring, Snapshot}
  alias Helyx.Session.Server.Events

  setup :start_core

  # A session that ran one turn of the model, and the events of the turn,
  # read and acked.
  defp after_turn(core, model) do
    {:ok, session} = Session.start(core, model: model)
    {:ok, snapshot, ref} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    events = collect_until(:turn_end)
    :ok = Session.ack(session, List.last(events).seq)
    Process.demonitor(ref, [:flush])
    {session, snapshot.instance_id, events}
  end

  # The events of the caller up to the first of `type`, each acked as a
  # client in the node does.
  defp acked_until(session, type, count \\ 0) do
    receive do
      {:helyx_event, %Event{type: ^type}} ->
        count + 1

      {:helyx_event, %Event{} = event} ->
        :ok = Session.ack(session, event)
        acked_until(session, type, count + 1)

      {:helyx_end, _ref, :slow} ->
        flunk("the subscription ended as slow after #{count} events")
    after
      wait_ms() -> flunk("no #{type} after #{count} events")
    end
  end

  test "a resubscribe with after gets the events after it, then the live ones once",
       %{core: core} do
    {:ok, session} = Session.start(core, model: "test/hang")
    {:ok, %Snapshot{instance_id: id, seq: 0}, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")
    seen = collect_until(:message_update)

    assert {:ok, {:replay, replay}, _} = Session.subscribe(session, after: {id, 1})
    assert replay == tl(seen)

    :ok = Session.abort(session)
    [first | _] = collect_until(:turn_end)
    assert first.seq == List.last(seen).seq + 1
  end

  test "a subscribe of another process with after gets the events it missed", %{core: core} do
    {session, id, events} = after_turn(core, "test/ok")
    last = List.last(events).seq
    test = self()

    spawn_link(fn -> send(test, {:reply, Session.subscribe(session, after: {id, 2})}) end)

    assert_receive {:reply, {:ok, {:replay, replay}, _}}
    assert replay == Enum.drop(events, 2)
    assert {:ok, {:replay, []}, _} = Session.subscribe(session, after: {id, last})
  end

  test "another instance, a future seq, or an interval out of the ring gives the snapshot",
       %{core: core} do
    {session, id, events} = after_turn(core, "test/burst.1100")
    last = List.last(events).seq
    assert last > Ring.max_count() + 1

    assert {:ok, %Snapshot{seq: ^last, more: false}, _} =
             Session.subscribe(session, after: {"another", 0})

    assert {:ok, %Snapshot{seq: ^last}, _} = Session.subscribe(session, after: {id, last + 1})
    # The fallback snapshot is the one of `tail`.
    assert {:ok, %Snapshot{seq: ^last, messages: [_], more: true}, _} =
             Session.subscribe(session, after: {id, 0}, tail: 1)

    # The ring holds the newest 1,024 events.
    from = last - Ring.max_count()
    assert {:ok, {:replay, replay}, _} = Session.subscribe(session, after: {id, from})
    assert replay == Enum.drop(events, from)
    assert {:ok, %Snapshot{}, _} = Session.subscribe(session, after: {id, from - 1})
  end

  test "a bad after is an error, checked before the call", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")

    for bad <- [{"i", -1}, {"i", 1.5}, {:i, 1}, "i"] do
      assert Session.subscribe(session, after: bad) == {:error, :invalid_after}
    end

    assert :sys.get_state(Session.pid(session)).subscribers == %{}
  end

  test "a subscriber that never acks ends with :slow after 16,384 events, and gets none after",
       %{core: core} do
    {:ok, session} = Session.start(core, model: "test/burst.16400")
    test = self()

    slow =
      spawn_link(fn ->
        {:ok, _, ref} = Session.subscribe(session)
        send(test, :subscribed)
        send(test, {:slow, count_until_slow(ref, 0, 0)})
        receive do: (:report -> send(test, {:left, Process.info(self(), :messages)}))
      end)

    assert_receive :subscribed
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    assert acked_until(session, :turn_end) > Events.credits()

    assert_receive {:slow, {count, last}}
    assert {count, last} == {Events.credits(), Events.credits()}

    send(slow, :report)
    assert_receive {:left, {:messages, []}}

    pid = Session.pid(session)
    refute Map.has_key?(:sys.get_state(pid).subscribers, slow)
    {:monitors, monitors} = Process.info(pid, :monitors)
    refute {:process, slow} in monitors
  end

  test "a resubscribe keeps the lower base, so it acks no event in the mailbox",
       %{core: core} do
    {session, id, events} = after_turn(core, "test/ok")
    last = List.last(events).seq
    acked = fn -> :sys.get_state(Session.pid(session)).subscribers[self()] |> elem(2) end

    {:ok, {:replay, _}, _} = Session.subscribe(session, after: {id, 1})
    {:ok, %Snapshot{seq: ^last}, _} = Session.subscribe(session)
    assert acked.() == 1
    {:ok, {:replay, []}, _} = Session.subscribe(session, after: {id, last})
    assert acked.() == 1
  end

  defp count_until_slow(ref, count, last) do
    receive do
      {:helyx_event, %Event{seq: seq}} -> count_until_slow(ref, count + 1, seq)
      {:helyx_end, ^ref, :slow} -> {count, last}
    end
  end

  # The credit window is a heuristic above the 10,000 provider messages that
  # can wait for the session (ADR 0008 §5): a client that acks by the
  # cadence keeps up with a burst of more than that.
  test "a subscriber that acks by the cadence gets a burst of 20,000 deltas", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/burst.20000")
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    assert acked_until(session, :turn_end) > 20_000
  end

  test "an ack is cumulative; a lower one or one above the seq acks nothing", %{core: core} do
    {session, id, events} = after_turn(core, "test/ok")
    # A replay counts: the base is the seq of `after`.
    {:ok, {:replay, _}, _} = Session.subscribe(session, after: {id, 1})
    last = List.last(events).seq
    acked = fn -> :sys.get_state(Session.pid(session)).subscribers[self()] |> elem(2) end

    assert acked.() == 1
    :ok = Session.ack(session, 3)
    assert acked.() == 3
    :ok = Session.ack(session, 2)
    assert acked.() == 3
    :ok = Session.ack(session, last + 1)
    assert acked.() == 3
    :ok = Session.ack(session, last)
    assert acked.() == last
  end

  test "an event acks only each 1,024th seq", %{core: core} do
    {session, id, events} = after_turn(core, "test/burst.1100")
    {:ok, {:replay, _}, _} = Session.subscribe(session, after: {id, 1_000})
    acked = fn -> :sys.get_state(Session.pid(session)).subscribers[self()] |> elem(2) end
    event = &Enum.find(events, fn e -> e.seq == &1 end)

    :ok = Session.ack(session, event.(1_023))
    assert acked.() == 1_000
    :ok = Session.ack(session, event.(1_024))
    assert acked.() == 1_024
    :ok = Session.ack(session, event.(1_025))
    assert acked.() == 1_024
  end

  test "an ack from a pid with no subscription changes nothing; a negative one raises",
       %{core: core} do
    {session, _id, _events} = after_turn(core, "test/ok")
    before = :sys.get_state(Session.pid(session)).subscribers
    test = self()

    # The state read follows the ack from the same process.
    spawn_link(fn ->
      :ok = Session.ack(session, 1)
      send(test, {:subscribers, :sys.get_state(Session.pid(session)).subscribers})
    end)

    assert_receive {:subscribers, ^before}
    assert_raise FunctionClauseError, fn -> Session.ack(session, -1) end
  end

  test "an ack of a session that is not running is :ok", %{core: core} do
    assert Session.ack(%Session{id: "none", core: core}, 1) == :ok
  end
end
