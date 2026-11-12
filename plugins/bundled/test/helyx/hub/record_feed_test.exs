defmodule Helyx.Hub.RecordFeedTest do
  # The bounds of the records feed (`docs/features/live-records.md`, "Bounds"):
  # the waiting changes of one slow subscriber, the burst that becomes one
  # change, and the full list after the bound. A subscriber that does not read
  # is a process of the test, so a case is one step.
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Hub.RecordFeed
  alias Helyx.Provider.Fake
  alias Helyx.Test.Events
  alias Helyx.Transport.WebSocket.Bounds

  @moduletag :tmp_dir

  defp serve(%{tmp_dir: dir} = context) do
    core = :"core_#{System.unique_integer([:positive])}"
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)
    start_supervised!({Helyx.Core, name: core, plugins: [Fake], sessions_dir: data}, id: :core)

    hub =
      start_supervised!(
        Supervisor.child_spec(
          {Hub,
           [
             core: core,
             default_owner: "owner",
             path: Path.join(dir, "hub.db"),
             server_token: fn -> "token" end
           ]},
          id: :hub
        )
      )

    Map.merge(context, %{core: core, hub: hub})
  end

  defp subscriber do
    parent = self()
    spawn_link(fn -> loop(parent) end)
  end

  # `:hold` stops the reading without draining the mailbox, so a message waits.
  defp loop(parent) do
    receive do
      :hold ->
        send(parent, :held)
        hold(parent)

      {:record_change, change} ->
        send(parent, {:change, change})
        loop(parent)

      {:records_full, records, more} ->
        send(parent, {:full, records, more})
        loop(parent)

      :stop ->
        :ok
    end
  end

  defp hold(parent) do
    receive do
      :go ->
        send(parent, :resumed)
        loop(parent)
    end
  end

  test "the numbers are those of bounds.json", %{tmp_dir: _dir} do
    assert RecordFeed.page() == Bounds.get("record_page")
    assert RecordFeed.max_live() == Bounds.get("record_live")
    assert RecordFeed.max_pending() == Bounds.get("record_pending")
    assert RecordFeed.max_subscribers() == Bounds.get("record_subscribers")
    assert RecordFeed.max_reply() == RecordFeed.page() + RecordFeed.max_live()
  end

  test "a burst while a send waits becomes one change, the newest", context do
    context = serve(context)
    state = :sys.get_state(context.hub)
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    wait_row(state, session.id)
    user = state.default_owner_id
    slow = subscriber()

    {:ok, state} = RecordFeed.subscribe(state, user, slow)
    send(slow, :hold)
    assert_receive :held

    state =
      Enum.reduce(1..50, state, fn _n, state ->
        RecordFeed.changed(state, session.id, "changed")
      end)

    assert %{pending: pending} = state.records |> Map.values() |> hd()
    assert map_size(pending) == 1

    # The newest value is built when the change goes, not when it arrives.
    :ok = state.store.touch_record(state.db, session.id, 10_000, "newest prompt", :infinity)
    send(slow, :go)
    assert_receive :resumed
    assert_receive {:change, %{"record" => %{"prompt" => ""}}}

    state = RecordFeed.repaired(state)

    assert_receive {:change, %{"record" => %{"prompt" => "newest prompt"}}}
    assert %{pending: pending, dropped: false} = state.records |> Map.values() |> hd()
    assert map_size(pending) == 0
    send(slow, :stop)
  end

  test "a subscriber past the bound gets the full list at the next poll", context do
    context = serve(context)
    state = :sys.get_state(context.hub)
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    wait_row(state, session.id)
    user = state.default_owner_id
    slow = subscriber()

    # 300 records of the user, so the page is full and `more` is true.
    for n <- 1..300 do
      record = %{
        session_id: "r#{n}",
        owner: user,
        cwd: "/tmp",
        model: "fake/echo",
        prompt: "",
        active_at: n,
        created_at: n,
        project_id: nil,
        title: "",
        visibility: "private",
        archived: false,
        parent_id: nil,
        parent_kind: nil
      }

      :ok = state.store.put_record(state.db, record, :none, :infinity)
    end

    {:ok, state} = RecordFeed.subscribe(state, user, slow)
    send(slow, :hold)
    assert_receive :held

    state =
      Enum.reduce(1..300, state, fn n, state ->
        RecordFeed.changed(state, "r#{n}", "changed")
      end)

    assert %{dropped: true, pending: pending} = state.records |> Map.values() |> hd()
    assert map_size(pending) == 0

    send(slow, :go)
    assert_receive :resumed
    assert_receive {:change, _change}
    state = RecordFeed.repaired(state)
    assert %{dropped: false} = state.records |> Map.values() |> hd()

    assert_receive {:full, records, true}
    assert length(records) == RecordFeed.page()
    assert Enum.any?(records, &(&1["session"] == session.id))
    send(slow, :stop)
  end

  test "a seed drops the sets of sessions that no longer run", context do
    context = serve(context)
    state = :sys.get_state(context.hub)
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    wait_row(state, session.id)
    Events.wait_until(fn -> Helyx.Hub.Live.running?(:sys.get_state(context.hub), session.id) end)

    state = :sys.get_state(context.hub)
    state = RecordFeed.ask(state, session.id, "a1")
    state = RecordFeed.ask(state, "gone", "a2")
    state = RecordFeed.prune(state)

    assert Map.has_key?(state.asks, session.id)
    refute Map.has_key?(state.asks, "gone")
  end

  test "a seed whose snapshot read failed keeps the set of the session", context do
    context = serve(context)
    state = :sys.get_state(context.hub)
    state = RecordFeed.ask(state, "s1", "a1")
    state = RecordFeed.seed(state, [{"s1", :error}, {"s2", {:ok, ["b1"]}}])

    assert Map.get(state.asks, "s1") == MapSet.new(["a1"])
    assert Map.get(state.asks, "s2") == MapSet.new(["b1"])
  end

  test "a failed store read marks every subscriber for the full list", context do
    context = serve(context)
    state = :sys.get_state(context.hub)
    {:ok, state} = RecordFeed.subscribe(state, state.default_owner_id, subscriber())
    state = %{state | store: Helyx.Hub.RecordFeedTest.FailingStore, db: :db}

    state = RecordFeed.changed(state, "s1", "changed")
    assert %{dropped: true} = state.records |> Map.values() |> hd()
  end

  defmodule FailingStore do
    @moduledoc false
    def record(_db, _session_id), do: {:error, :failed}
  end

  test "a silent row is in no list, and every full list skips it", context do
    context = serve(context)
    state = :sys.get_state(context.hub)
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    wait_row(state, session.id)
    Events.wait_until(fn -> Helyx.Hub.Live.running?(:sys.get_state(context.hub), session.id) end)

    state = :sys.get_state(context.hub)

    slow = subscriber()
    {:ok, state} = RecordFeed.subscribe(state, state.default_owner_id, slow)

    state = RecordFeed.silent(state, session.id)

    assert {:ok, rows, _more} = RecordFeed.list(state, state.default_owner_id)
    refute Enum.any?(rows, &(&1["session"] == session.id))

    state = RecordFeed.refresh(state, state.default_owner_id)
    assert_receive {:full, refreshed, _more}
    refute Enum.any?(refreshed, &(&1["session"] == session.id))

    state = RecordFeed.failed(state)
    _state = RecordFeed.repaired(state)
    assert_receive {:full, resent, _more}
    refute Enum.any?(resent, &(&1["session"] == session.id))
    send(slow, :stop)
  end

  defp wait_row(state, id) do
    Events.wait_until(fn -> match?({:ok, _row}, state.store.record(state.db, id)) end)
  end
end
