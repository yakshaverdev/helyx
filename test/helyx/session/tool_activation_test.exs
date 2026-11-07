defmodule Helyx.Session.ToolActivationTest do
  # Deferred tools and their activation: `Helyx.Tool.deferred/2`,
  # `activate/1`, the caps of the activated list, the `tools_change` entry
  # and event, and the resume (docs/features/mcp-client.md, slice 3).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase, only: [start_core: 1]
  import Helyx.Test.SourceCase

  alias Helyx.Session
  alias Helyx.Test.Source
  alias Helyx.Test.Tool.InCall

  @plugins [Helyx.Test.Provider, InCall, Source]

  setup do
    core = start_core(@plugins)
    observe(core)
    %{core: core}
  end

  defp start(core, opts \\ []) do
    {:ok, session} = Session.start(core, [model: "test/call.in_call"] ++ opts)
    {session, up(session)}
  end

  defp up(session) do
    id = session.id
    assert_receive {:source_up, src, %{session_id: ^id}}
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    src
  end

  # Runs `fun` in a tool call of a turn; gives its result and the events
  # of the turn.
  defp in_call(session, fun) do
    InCall.put(session.id, fun)
    :ok = Session.prompt(session, "go")
    events = collect_until(:turn_end)
    assert_receive {:in_call, result}
    {result, events}
  end

  defp activate(session, names) do
    {activated, events} = in_call(session, fn -> Helyx.Tool.activate(names) end)
    {activated, Enum.filter(events, &(&1.type == :tools_change))}
  end

  # The names of the tools of a provider call.
  defp context_tools(session) do
    :ok = Session.set_model(session, "test/tools")
    names = turn_text(session)
    :ok = Session.set_model(session, "test/call.in_call")
    names
  end

  defp names(prefix, range), do: for(n <- range, do: "#{prefix}#{n}")

  test "a deferred tool reaches the context only when activated", %{core: core} do
    {session, src} = start(core)
    assert :ok = put(src, "g", [deferred("g__a"), deferred("g__b"), entry("g__direct")])
    assert context_tools(session) == "g__direct,in_call"

    InCall.put(session.id, fn -> Helyx.Tool.activate(["g__b", "nope", "g__direct", "in_call"]) end)

    :ok = Session.prompt(session, "go")
    events = collect_until(:turn_end)
    assert_receive {:in_call, ["g__b"]}
    [%{turn_id: turn_id}] = Enum.filter(events, &(&1.type == :turn_start))
    assert [event] = Enum.filter(events, &(&1.type == :tools_change))
    assert event.data == %{activated: ["g__b"]}
    assert event.turn_id == turn_id
    assert context_tools(session) == "g__b,g__direct,in_call"

    # No change, no entry and no event.
    assert {["g__b"], []} = activate(session, ["g__b", "nope"])
  end

  test "at 32 names the oldest leave first, and in one call the lowest ranked", %{core: core} do
    {session, src} = start(core)
    assert :ok = put(src, "g", for(name <- names("n", 1..40), do: deferred(name)))

    # One call over the cap keeps its best 32.
    {activated, _events} = activate(session, names("n", 1..40))
    assert activated == Enum.reverse(names("n", 1..32))

    # An older call leaves first, its lowest ranked first.
    {activated, _events} = activate(session, names("n", 33..40))
    assert activated == Enum.reverse(names("n", 1..24)) ++ Enum.reverse(names("n", 33..40))
  end

  test "one call over 65,536 bytes of specs keeps its best matches", %{core: core} do
    {session, src} = start(core)
    big = names("e", 1..5)
    assert :ok = put(src, "g", for(name <- big, do: deferred(name, 15_900)))

    assert {["e4", "e3", "e2", "e1"], [_event]} = activate(session, big)
  end

  test "past 65,536 bytes the older call leaves first", %{core: core} do
    {session, src} = start(core)

    assert :ok =
             put(
               src,
               "g",
               for(name <- names("a", 1..2) ++ names("b", 1..3), do: deferred(name, 15_900))
             )

    assert {["a2", "a1"], _} = activate(session, ["a1", "a2"])
    assert {["a1", "b3", "b2", "b1"], _} = activate(session, ["b1", "b2", "b3"])
  end

  test "a name activated again moves to its rank in the new call", %{core: core} do
    {session, src} = start(core)
    assert :ok = put(src, "g", for(name <- ~w(a b c d), do: deferred(name)))
    assert {["c", "b", "a"], _} = activate(session, ["a", "b", "c"])
    assert {["c", "a", "d", "b"], _} = activate(session, ["b", "d"])
  end

  test "a put with larger schemas drops the oldest with a tools_change of no turn",
       %{core: core} do
    {session, src} = start(core)
    small = names("y", 1..5)
    assert :ok = put(src, "g", for(name <- small, do: deferred(name)))
    assert {["y5", "y4", "y3", "y2", "y1"], _} = activate(session, small)

    assert in_source(src, fn ->
             Helyx.Tool.put_tools("g", {:ok, for(name <- small, do: deferred(name, 15_900))})
           end) == :ok

    assert_receive {:helyx_event, %Helyx.Event{type: :tools_change, turn_id: nil, data: data}}
    assert data == %{activated: ["y4", "y3", "y2", "y1"]}
  end

  @tag :tmp_dir
  test "a resume restores the list, in its order, and the cap after the put", %{
    core: core,
    tmp_dir: dir
  } do
    {session, src} = start(core, sessions_dir: dir)
    small = names("r", 1..5)
    assert :ok = put(src, "g", for(name <- small, do: deferred(name)))
    assert {["r3", "r1", "r5", "r4", "r2"], _} = activate(session, ["r2", "r4", "r5", "r1", "r3"])
    id = session.id
    :ok = Helyx.Sessions.stop(session)

    {:ok, resumed} = Session.resume(core, sessions_dir: dir, id: id)
    src = up(resumed)
    {:ok, snapshot, _ref} = Session.subscribe(resumed)
    assert snapshot.activated == ["r3", "r1", "r5", "r4", "r2"]

    # Not registered yet: the names stay, and no provider call has them.
    assert context_tools(resumed) == "in_call"

    # The group lists them again, larger: in the context, and over the cap
    # the oldest leaves, with a tools_change of no turn.
    assert :ok = put(src, "g", for(name <- small, do: deferred(name, 15_900)))
    assert_receive {:helyx_event, %Helyx.Event{type: :tools_change, turn_id: nil, data: data}}
    assert data == %{activated: ["r1", "r5", "r4", "r2"]}
    assert context_tools(resumed) == "in_call,r1,r2,r4,r5"
  end

  test "deferred/2 shows a pending source and answers at once with nil", %{core: core} do
    {session, _src} = start(core)
    {view, _events} = in_call(session, fn -> Helyx.Tool.deferred(nil, 30_000) end)

    assert view == %{
             version: 0,
             entries: [],
             activated: [],
             groups: [],
             pending: [inspect(Source)]
           }
  end

  test "deferred/2 answers at once when its version is behind", %{core: core} do
    {session, src} = start(core)
    assert :ok = put(src, "g", [deferred("g__a")])
    {view, _events} = in_call(session, fn -> Helyx.Tool.deferred(0, 30_000) end)

    assert %{version: 2, pending: [], groups: [%{group: "g", state: :ready}]} = view
    assert [%{name: "g__a", group: "g", description: "d"}] = view.entries
  end

  test "deferred/2 waits for the next change", %{core: core} do
    {session, src} = start(core)
    test = self()
    {:ok, ["g"]} = in_source(src, fn -> Helyx.Tool.announce(["g"]) end)

    InCall.put(session.id, fn ->
      %{version: version} = Helyx.Tool.deferred(nil, 0)
      send(test, {:waiting, version})
      Helyx.Tool.deferred(version, 30_000)
    end)

    :ok = Session.prompt(session, "go")
    assert_receive {:waiting, 1}
    refute_received {:in_call, _}

    :ok = in_source(src, fn -> Helyx.Tool.put_tools("g", {:ok, [deferred("g__a")]}) end)
    assert_receive {:in_call, %{version: 2, entries: [%{name: "g__a"}]}}
    collect_until(:turn_end)
  end

  test "deferred/2 ends at its bound with the state as it is", %{core: core} do
    {session, src} = start(core)
    {:ok, ["g"]} = in_source(src, fn -> Helyx.Tool.announce(["g"]) end)

    {view, _events} = in_call(session, fn -> Helyx.Tool.deferred(1, 100) end)
    assert %{version: 1, groups: [%{group: "g", state: :starting}]} = view
  end

  test "deferred/2 and activate/1 raise outside a tool call, and activate/1 on a bad list" do
    assert_raise ArgumentError, fn -> Helyx.Tool.deferred(nil, 0) end
    assert_raise ArgumentError, fn -> Helyx.Tool.activate(["a"]) end
  end

  test "activate/1 takes at most 1,024 names", %{core: core} do
    {session, src} = start(core)
    assert :ok = put(src, "g", [deferred("g__a")])

    {result, _events} =
      in_call(session, fn ->
        try do
          Helyx.Tool.activate(["g__a" | names("x", 1..1_024)])
        rescue
          ArgumentError -> :raised
        end
      end)

    assert result == :raised
    assert {["g__a"], _} = activate(session, ["g__a" | names("x", 1..1_023)])
  end

  defp spec_bytes(entry) do
    {:ok, bytes} = Helyx.Message.encoded_size(Map.take(entry, [:name, :description, :parameters]))
    bytes
  end

  test "65,536 bytes of specs pass, and one byte more drops the oldest", %{core: core} do
    {session, src} = start(core)
    # Four specs of 16,384 bytes each, within the bound of one entry's
    # parameters, make exactly 65,536.
    pad = 16_384 - spec_bytes(deferred("a1", 0))
    three = for name <- names("a", 1..3), do: deferred(name, pad)
    assert :ok = put(src, "g", three ++ [deferred("a4", pad)])
    assert Enum.sum(Enum.map(three ++ [deferred("a4", pad)], &spec_bytes/1)) == 65_536

    assert {["a4", "a3", "a2", "a1"], _} = activate(session, names("a", 1..4))

    # One byte more: the oldest name leaves, with a tools_change of no turn.
    assert in_source(src, fn ->
             Helyx.Tool.put_tools("g", {:ok, three ++ [deferred("a4", pad + 1)]})
           end) == :ok

    assert_receive {:helyx_event, %Helyx.Event{type: :tools_change, turn_id: nil, data: data}}
    assert data == %{activated: ["a3", "a2", "a1"]}
  end

  @tag :tmp_dir
  test "the list that a put drops at the cap is on disk", %{core: core, tmp_dir: dir} do
    {session, src} = start(core, sessions_dir: dir)
    small = names("y", 1..5)
    assert :ok = put(src, "g", for(name <- small, do: deferred(name)))
    assert {_, _} = activate(session, small)

    assert in_source(src, fn ->
             Helyx.Tool.put_tools("g", {:ok, for(name <- small, do: deferred(name, 15_900))})
           end) == :ok

    assert_receive {:helyx_event, %Helyx.Event{type: :tools_change, turn_id: nil}}
    id = session.id
    :ok = Helyx.Sessions.stop(session)
    {:ok, resumed} = Session.resume(core, sessions_dir: dir, id: id)
    _src = up(resumed)
    {:ok, snapshot, _ref} = Session.subscribe(resumed)
    assert snapshot.activated == ["y4", "y3", "y2", "y1"]
  end

  test "an activation of a background run has no turn", %{core: core} do
    {session, src} = start(core)
    assert :ok = put(src, "g", [deferred("g__a")])
    test = self()

    InCall.put(session.id, fn ->
      {:ok, _place} = Helyx.Tool.background()
      :ok = Helyx.Tool.started("running")
      send(test, {:run, self()})
      receive do: (:go -> Helyx.Tool.activate(["g__a"]))
    end)

    :ok = Session.prompt(session, "go")
    collect_until(:turn_end)
    assert_receive {:run, run}

    # The run activates while a later turn runs: the event has no turn.
    InCall.put(session.id, fn ->
      send(test, {:call, self()})
      receive(do: (:done -> :done))
    end)

    :ok = Session.prompt(session, "again")
    assert_receive {:helyx_event, %Helyx.Event{type: :turn_start, turn_id: later}}
    assert_receive {:call, call}
    send(run, :go)
    assert_receive {:helyx_event, %Helyx.Event{type: :tools_change, turn_id: turn_id, data: data}}
    assert data == %{activated: ["g__a"]}
    assert turn_id == nil
    refute later == nil
    # The end of the run joins this turn and calls the tool again.
    InCall.put(session.id, fn -> :again end)
    send(call, :done)
    collect_until(:turn_end)
  end

  test "the end of a source raises the version", %{core: core} do
    {session, src} = start(core)
    {:ok, ["g"]} = in_source(src, fn -> Helyx.Tool.announce(["g"]) end)
    {%{version: 1}, _} = in_call(session, fn -> Helyx.Tool.deferred(nil, 0) end)
    Process.exit(src, :kill)
    assert notice() =~ "tool group g ended"

    assert {%{version: 2, groups: [], pending: []}, _} =
             in_call(session, fn -> Helyx.Tool.deferred(nil, 0) end)
  end

  test "activate/1 raises on anything but a list of strings", %{core: core} do
    {session, _src} = start(core)

    for bad <- ["a", ["a" | "b"], [:a], [1], nil] do
      {result, _events} =
        in_call(session, fn ->
          try do
            Helyx.Tool.activate(bad)
          rescue
            ArgumentError -> :raised
          end
        end)

      assert result == :raised, inspect(bad)
    end
  end

  test "deferred/2 waits at most 30,000 ms, and a negative wait raises", %{core: core} do
    {session, src} = start(core)
    {:ok, ["g"]} = in_source(src, fn -> Helyx.Tool.announce(["g"]) end)
    test = self()

    InCall.put(session.id, fn ->
      send(test, :waiting)
      Helyx.Tool.deferred(1, 10_000_000)
    end)

    :ok = Session.prompt(session, "go")
    assert_receive :waiting
    {_from, timer} = wait_for_live_waiter(session)
    assert :erlang.read_timer(timer) <= 30_000
    :ok = in_source(src, fn -> Helyx.Tool.put_tools("g", :starting) end)
    assert_receive {:in_call, %{version: 2}}
    collect_until(:turn_end)

    {result, _events} =
      in_call(session, fn ->
        try do
          Helyx.Tool.deferred(nil, -1)
        rescue
          FunctionClauseError -> :raised
        end
      end)

    assert result == :raised
  end

  test "a waiter whose call ended does not fill the waiters", %{core: core} do
    {session, src} = start(core)
    {:ok, ["g"]} = in_source(src, fn -> Helyx.Tool.announce(["g"]) end)

    # 33 calls wait, and each turn is aborted: their waiters stay until
    # their timers, but are dead.
    for _n <- 1..33 do
      InCall.put(session.id, fn -> Helyx.Tool.deferred(1, 30_000) end)
      :ok = Session.prompt(session, "go")
      wait_for_live_waiter(session)
      :ok = Session.abort(session)
      collect_until(:turn_end)
    end

    # A new call still waits for the next change.
    test = self()

    InCall.put(session.id, fn ->
      send(test, :waiting)
      Helyx.Tool.deferred(1, 30_000)
    end)

    :ok = Session.prompt(session, "go")
    assert_receive :waiting
    wait_for_live_waiter(session)
    refute_received {:in_call, _}
    :ok = in_source(src, fn -> Helyx.Tool.put_tools("g", :starting) end)
    assert_receive {:in_call, %{version: 2}}
    collect_until(:turn_end)
  end

  # A waiter of the session whose caller runs.
  defp wait_for_live_waiter(session) do
    live =
      for {_ref, {{pid, _tag}, _timer} = waiter} <-
            :sys.get_state(Session.pid(session)).registry.waiters,
          Process.alive?(pid),
          do: waiter

    case live do
      [waiter | _] ->
        waiter

      [] ->
        Process.sleep(5)
        wait_for_live_waiter(session)
    end
  end
end
