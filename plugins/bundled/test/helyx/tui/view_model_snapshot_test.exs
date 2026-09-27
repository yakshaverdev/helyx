defmodule Helyx.TUI.ViewModelSnapshotTest do
  # `ViewModel.from_snapshot/1` against a real session: a client that
  # subscribes late shows the transcript cells that a client that watched
  # from the start shows. Notices and the partial reply of an aborted or
  # failed turn are not in the transcript, so each comparison leaves them
  # out (`transcript/1`).
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message, Session}
  alias Helyx.Provider.Fake
  alias Helyx.TUI.ViewModel

  import Helyx.Test.ViewModelRule, only: [transcript: 1]

  defmodule Gate do
    @moduledoc false
    # A tool that tells the process registered as "gate" it runs, then
    # waits for :go.
    @behaviour Helyx.Tool

    @impl true
    def name, do: "gate"
    @impl true
    def description, do: "Waits for the test."
    @impl true
    def parameters, do: %{"type" => "object"}
    @impl true
    def run(%{"gate" => gate}, _cwd), do: Helyx.TUI.ViewModelSnapshotTest.wait(gate)
  end

  defmodule Harness do
    @moduledoc false
    # A provider with an external turn. The model is "<shape>.<gate>": the
    # stream stops at the gate until the test sends :go.
    #
    #   calls    three tool calls and a message end, the gate, the three
    #            results, then a text
    #   partial  a text delta, the gate, then more text
    #   fail     a text delta, the gate, then a stream error
    #   dangling a tool call, then the end of the turn (no gate)
    #   dup_id   two tool calls with one id and a message end, the first
    #            result, the gate, the second result, then a text
    @behaviour Helyx.Provider

    @impl true
    def id, do: "gated"
    @impl true
    def turn, do: :external

    @impl true
    def stream(model, _context, _opts) do
      [shape, gate] = String.split(model, ".")

      steps(shape)
      |> Stream.flat_map(fn
        :gate ->
          Helyx.TUI.ViewModelSnapshotTest.wait(gate)
          []

        event ->
          [event]
      end)
      |> Stream.concat([{:done, %{stop_reason: :end_turn, usage: %{}}}])
      |> then(&{:ok, &1})
    end

    defp steps("calls") do
      calls = for id <- ~w(c1 c2 c3), do: %Message.ToolCall{id: id, name: "x", arguments: %{}}

      Enum.map(calls, &{:tool_call, &1}) ++
        [{:message_end, :tool_use, %{}}, :gate] ++
        Enum.map(calls, &{:tool_result, &1.id, {:ok, "r"}}) ++ [{:text_delta, "end"}]
    end

    defp steps("partial"), do: [{:text_delta, "hel"}, :gate, {:text_delta, "lo"}]
    defp steps("fail"), do: [{:text_delta, "hel"}, :gate, {:error, :boom}]

    defp steps("dangling"),
      do: [{:tool_call, %Message.ToolCall{id: "d", name: "x", arguments: %{}}}]

    defp steps("dup_id") do
      [
        {:tool_call, %Message.ToolCall{id: "t", name: "read", arguments: %{}}},
        {:tool_call, %Message.ToolCall{id: "t", name: "bash", arguments: %{}}},
        {:message_end, :tool_use, %{}},
        {:tool_result, "t", {:ok, "one"}},
        :gate,
        {:tool_result, "t", {:ok, "two"}},
        {:text_delta, "end"}
      ]
    end
  end

  @doc false
  def wait(gate) do
    send(String.to_existing_atom(gate), {:waiting, self()})

    receive do
      :go -> {:ok, "done"}
    end
  end

  setup context do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake, Gate, Harness]})
    gate = :"gate_#{System.unique_integer([:positive])}"
    Process.register(self(), gate)
    Map.merge(context, %{core: core, gate: Atom.to_string(gate)})
  end

  test "a subscribe while the first of three local calls runs", %{core: core, gate: gate} do
    calls =
      for id <- ~w(c1 c2 c3),
          do: %Message.ToolCall{id: id, name: "gate", arguments: %{"gate" => gate}}

    :ok = Fake.script(core, "three", [["Running." | calls], ["Done."]])
    {:ok, session} = Session.start(core, model: "fake/three")
    {:ok, first} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, tool}
    {late, snapshot} = late_client(session)
    assert snapshot.turn.running == ["c1"]

    live = fold(first, events_to(snapshot.seq))
    assert transcript(ViewModel.from_snapshot(snapshot)) == transcript(live)

    send(tool, :go)
    assert_receive {:waiting, tool}
    send(tool, :go)
    assert_receive {:waiting, tool}
    send(tool, :go)

    watched = fold(live, events_to_end())
    joined = fold(snapshot, late_events(late))

    assert transcript(joined) == transcript(watched)
    assert length(for {:tool, _call, _line, %Message{}} <- joined.cells, do: 1) == 3
  end

  test "a subscribe in an external turn with three open calls", %{core: core, gate: gate} do
    {:ok, session} = Session.start(core, model: "gated/calls." <> gate)
    {:ok, first} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, stream}
    {late, snapshot} = late_client(session)
    assert snapshot.turn.running == ~w(c1 c2 c3)

    live = fold(first, events_to(snapshot.seq))
    assert transcript(ViewModel.from_snapshot(snapshot)) == transcript(live)

    send(stream, :go)

    assert transcript(fold(snapshot, late_events(late))) ==
             transcript(fold(live, events_to_end()))
  end

  test "two calls with one id in an external turn: each result on the same cell", %{
    core: core,
    gate: gate
  } do
    {:ok, session} = Session.start(core, model: "gated/dup_id." <> gate)
    {:ok, first} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, stream}
    {late, snapshot} = late_client(session)
    live = fold(first, events_to(snapshot.seq))
    assert transcript(ViewModel.from_snapshot(snapshot)) == transcript(live)

    assert [
             _user,
             _assistant,
             {:tool, %{name: "read"}, _, %Message{}},
             {:tool, %{name: "bash"}, _, nil}
           ] =
             live.cells

    send(stream, :go)

    assert transcript(fold(snapshot, late_events(late))) ==
             transcript(fold(live, events_to_end()))
  end

  test "a later local call with the running call's id gets its cell only when it starts", %{
    core: core,
    gate: gate
  } do
    [a, b, z] =
      for name <- ~w(a b z),
          do: %Message.ToolCall{id: "t", name: "gate", arguments: %{"gate" => gate, "n" => name}}

    :ok = Fake.script(core, "same_id", [[a, b], ["mid"], [z], ["end"]])
    {:ok, session} = Session.start(core, model: "fake/same_id")
    {:ok, first} = Session.subscribe(session)
    :ok = Session.prompt(session, "one")

    assert_receive {:waiting, tool}
    {late, snapshot} = late_client(session)
    live = fold(first, events_to(snapshot.seq))
    assert transcript(ViewModel.from_snapshot(snapshot)) == transcript(live)

    send(tool, :go)
    assert_receive {:waiting, tool}
    send(tool, :go)
    live = fold(live, events_to_end())
    joined = fold(snapshot, late_events(late))
    assert transcript(joined) == transcript(live)

    # A call of a later turn with the same id gets its own result.
    :ok = Session.prompt(session, "two")
    assert_receive {:waiting, tool}
    send(tool, :go)
    live = fold(live, events_to_end())
    joined = fold(joined, late_events(late))
    assert transcript(joined) == transcript(live)
    assert [] = for({:tool, _call, _line, nil} <- joined.cells, do: :open)
  end

  test "a subscribe during a reply shows the reply so far, then each event once", %{
    core: core,
    gate: gate
  } do
    {:ok, session} = Session.start(core, model: "gated/partial." <> gate)
    {:ok, first} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, stream}
    {late, snapshot} = late_client(session)
    assert %{partial: %Message{content: [%Message.Text{text: "hel"}]}} = snapshot.turn
    assert ViewModel.from_snapshot(snapshot).streaming == [%Message.Text{text: "hel"}]

    send(stream, :go)
    events = late_events(late)
    watched = events_to_end()

    # The late client got every event after the snapshot, and each once.
    # An event sent between its registration and the snapshot can reach it
    # too; `apply/2` drops it, because the snapshot holds it.
    assert for(%Event{seq: seq} <- events, seq > snapshot.seq, do: seq) ==
             for(%Event{seq: seq} <- watched, seq > snapshot.seq, do: seq)

    assert transcript(fold(snapshot, events)) == transcript(fold(first, watched))
  end

  test "a join after a failed turn with a partial reply", %{core: core, gate: gate} do
    {:ok, session} = Session.start(core, model: "gated/fail." <> gate)
    {:ok, first} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, stream}
    send(stream, :go)
    events = events_to_end()
    live = fold(first, events)
    assert [_user, %Message{stop_reason: :error}, {:notice, "error: " <> _}] = live.cells

    assert_joins_after_end(session, live, events)
  end

  test "a join after an abort during a partial reply", %{core: core, gate: gate} do
    {:ok, session} = Session.start(core, model: "gated/partial." <> gate)
    {:ok, first} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, _stream}
    :ok = Session.abort(session)
    events = events_to_end()
    live = fold(first, events)
    assert [_user, %Message{stop_reason: :aborted}, {:notice, "aborted"}] = live.cells

    assert_joins_after_end(session, live, events)
  end

  # The accepted limit: a call that never started gets an `aborted` result in
  # the transcript at the normal end of an external turn, so the snapshot
  # shows a closed cell that the live client never had.
  test "a join after an external turn that ends with an open call", %{core: core, gate: gate} do
    {:ok, session} = Session.start(core, model: "gated/dangling." <> gate)
    {:ok, first} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    live = fold(first, events_to_end())

    {:ok, snapshot} = Session.subscribe(session)
    joined = ViewModel.from_snapshot(snapshot)
    assert snapshot.seq == live.seq

    assert [_user, %Message{role: :assistant}, {:tool, %{id: "d"}, _, aborted}] = joined.cells
    assert %Message{is_error: true, content: [%Message.Text{text: "aborted"}]} = aborted
    assert %{joined | cells: Enum.drop(joined.cells, -1)} == live
  end

  test "a session with no events has seq 0 and no notice", %{core: core} do
    {:ok, session} = Session.start(core, model: "fake/echo")
    {:ok, snapshot} = Session.subscribe(session)

    assert %{seq: 0, messages: [], turn: nil, model: "fake/echo"} = snapshot

    assert ViewModel.from_snapshot(snapshot) == %{
             ViewModel.new("fake/echo")
             | instance_id: snapshot.instance_id
           }
  end

  # A client that joins after the turn ended shows the transcript cells of
  # the client that watched, and no event up to the snapshot changes it.
  defp assert_joins_after_end(session, live, events) do
    {:ok, snapshot} = Session.subscribe(session)
    assert snapshot.seq == live.seq
    joined = ViewModel.from_snapshot(snapshot)
    assert transcript(joined) == transcript(live)
    assert [_user] = joined.cells
    assert fold(joined, events) == joined
  end

  # A second client: it subscribes, sends its snapshot, then forwards each
  # event, and marks each agent_end, until no event comes for a second.
  defp late_client(session) do
    test = self()

    {pid, _ref} =
      spawn_monitor(fn ->
        {:ok, snapshot} = Session.subscribe(session)
        send(test, {:snapshot, self(), snapshot})
        forward(test)
      end)

    assert_receive {:snapshot, ^pid, snapshot}
    {pid, snapshot}
  end

  defp forward(test) do
    receive do
      {:helyx_event, %Event{type: :agent_end} = event} ->
        send(test, {:late, self(), event, :end})
        forward(test)

      {:helyx_event, event} ->
        send(test, {:late, self(), event})
        forward(test)
    after
      1_000 -> :ok
    end
  end

  defp late_events(pid, acc \\ []) do
    receive do
      {:late, ^pid, event, :end} -> Enum.reverse([event | acc])
      {:late, ^pid, event} -> late_events(pid, [event | acc])
    after
      1_000 -> flunk("the late client got no agent_end")
    end
  end

  # The events of the first client up to `seq`, which are in the mailbox.
  defp events_to(seq, acc \\ []) do
    receive do
      {:helyx_event, %Event{seq: ^seq} = event} -> Enum.reverse([event | acc])
      {:helyx_event, event} -> events_to(seq, [event | acc])
    after
      1_000 -> flunk("no event with seq #{seq}")
    end
  end

  defp events_to_end(acc \\ []) do
    receive do
      {:helyx_event, %Event{type: :agent_end} = event} -> Enum.reverse([event | acc])
      {:helyx_event, event} -> events_to_end([event | acc])
    after
      1_000 -> flunk("no agent_end")
    end
  end

  defp fold(%ViewModel{} = vm, events), do: Helyx.Test.ViewModelRule.fold(vm, events)
  defp fold(snapshot, events), do: fold(ViewModel.from_snapshot(snapshot), events)
end
