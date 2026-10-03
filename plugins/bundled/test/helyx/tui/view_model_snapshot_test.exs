defmodule Helyx.TUI.ViewModelSnapshotTest do
  # `ViewModel.from_snapshot/1` against a real session: a client that
  # subscribes late shows the transcript cells that a client that watched
  # from the start shows. Notices and the partial reply of an aborted or
  # failed turn are not in the transcript, so each comparison leaves them
  # out (`transcript/1`).
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message, Session}
  alias Helyx.Provider.Fake
  alias Helyx.Test.{Gate, Gated, LateClient}
  alias Helyx.TUI.ViewModel

  import Helyx.Test.Events
  import Helyx.Test.TUIRender, only: [texts: 1]
  import Helyx.Test.ViewModelRule, only: [transcript: 1]

  setup context do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake, Gate, Gated.Connected]})
    Map.merge(context, %{core: core, gate: Gate.open()})
  end

  # Each call of the message has an open cell from its `message_end`, in
  # both clients, while the first runs.
  test "a subscribe while the first of three calls runs", %{core: core, gate: gate} do
    calls =
      for id <- ~w(c1 c2 c3),
          do: %Message.ToolCall{id: id, name: "gate", arguments: %{"gate" => gate}}

    :ok = Fake.script(core, "three", [["Running." | calls], ["Done."]])
    {:ok, session} = Session.start(core, model: "fake/three")
    {:ok, first, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, tool}
    {late, snapshot} = LateClient.connect(session)
    live = fold(first, events_to(snapshot.seq))
    assert transcript(ViewModel.from_snapshot(snapshot)) == transcript(live)

    assert [_user, _assistant, {:tool, _, _, nil}, {:tool, _, _, nil}, {:tool, _, _, nil}] =
             ViewModel.cells(live)

    send(tool, :go)
    assert_receive {:waiting, tool}
    send(tool, :go)
    assert_receive {:waiting, tool}
    send(tool, :go)

    watched = fold(live, collect_until(:turn_end))
    joined = fold(snapshot, LateClient.events_to_end(late))

    assert transcript(joined) == transcript(watched)
    assert length(for {:tool, _call, _line, %Message{}} <- ViewModel.cells(joined), do: 1) == 3
    LateClient.disconnect(late)
  end

  test "a subscribe in a connected turn with three open calls", %{core: core, gate: gate} do
    {:ok, session} = Session.start(core, model: "gated/calls." <> gate)
    {:ok, first, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, stream}
    {late, snapshot} = LateClient.connect(session)
    live = fold(first, events_to(snapshot.seq))
    assert transcript(ViewModel.from_snapshot(snapshot)) == transcript(live)

    send(stream, :go)

    assert transcript(fold(snapshot, LateClient.events_to_end(late))) ==
             transcript(fold(live, collect_until(:turn_end)))

    LateClient.disconnect(late)
  end

  test "two calls with one id in a connected turn: each result on the same cell", %{
    core: core,
    gate: gate
  } do
    {:ok, session} = Session.start(core, model: "gated/dup_id." <> gate)
    {:ok, first, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, stream}
    {late, snapshot} = LateClient.connect(session)
    live = fold(first, events_to(snapshot.seq))
    assert transcript(ViewModel.from_snapshot(snapshot)) == transcript(live)

    assert [
             _user,
             _assistant,
             {:tool, %{name: "read"}, _, %Message{}},
             {:tool, %{name: "bash"}, _, nil}
           ] =
             ViewModel.cells(live)

    send(stream, :go)

    assert transcript(fold(snapshot, LateClient.events_to_end(late))) ==
             transcript(fold(live, collect_until(:turn_end)))

    LateClient.disconnect(late)
  end

  # A call id that repeats in one message ends the provider process (#380);
  # a later turn may use the id again.
  test "a call of a later turn with an earlier call's id gets its own cell", %{
    core: core,
    gate: gate
  } do
    [a, z] =
      for name <- ~w(a z),
          do: %Message.ToolCall{id: "t", name: "gate", arguments: %{"gate" => gate, "n" => name}}

    :ok = Fake.script(core, "same_id", [[a], ["mid"], [z], ["end"]])
    {:ok, session} = Session.start(core, model: "fake/same_id")
    {:ok, first, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "one")

    assert_receive {:waiting, tool}
    {late, snapshot} = LateClient.connect(session)
    live = fold(first, events_to(snapshot.seq))
    assert transcript(ViewModel.from_snapshot(snapshot)) == transcript(live)

    send(tool, :go)
    live = fold(live, collect_until(:turn_end))
    joined = fold(snapshot, LateClient.events_to_end(late))
    assert transcript(joined) == transcript(live)

    # A call of a later turn with the same id gets its own result.
    :ok = Session.prompt(session, "two")
    assert_receive {:waiting, tool}
    send(tool, :go)
    live = fold(live, collect_until(:turn_end))
    joined = fold(joined, LateClient.events_to_end(late))
    assert transcript(joined) == transcript(live)
    assert [] = for({:tool, _call, _line, nil} <- ViewModel.cells(joined), do: :open)
    LateClient.disconnect(late)
  end

  # A harness program runs a call of the open message, and the message
  # closes at its first result (#385). Its cell shows "awaiting result"
  # from the message, before the result, in a live and a late client.
  test "a call in the open message awaits its result", %{core: core, gate: gate} do
    {:ok, session} = Session.start(core, model: "gated/harness." <> gate)
    {:ok, first, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, stream}
    {late, snapshot} = LateClient.connect(session)
    live = fold(first, events_to(snapshot.seq))
    assert transcript(ViewModel.from_snapshot(snapshot)) == transcript(live)
    assert [{:tool, %{id: "h"}, _, nil}] = live.streaming
    assert ["⚙ x", "… awaiting result"] == Enum.take(texts(live), -2)

    send(stream, :go)
    watched = fold(live, collect_until(:turn_end))
    assert transcript(fold(snapshot, LateClient.events_to_end(late))) == transcript(watched)

    assert [_user, _assistant, {:tool, %{id: "h"}, _, %Message{}}, _end] =
             ViewModel.cells(watched)

    refute "… awaiting result" in texts(watched)
    LateClient.disconnect(late)
  end

  test "a subscribe during a reply shows the reply so far, then each event once", %{
    core: core,
    gate: gate
  } do
    {:ok, session} = Session.start(core, model: "gated/partial." <> gate)
    {:ok, first, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, stream}
    {late, snapshot} = LateClient.connect(session)
    assert %{partial: %Message{content: [%Message.Text{text: "hel"}]}} = snapshot.turn
    assert ViewModel.from_snapshot(snapshot).streaming == [%Message.Text{text: "hel"}]

    send(stream, :go)
    events = LateClient.events_to_end(late)
    watched = collect_until(:turn_end)

    # The late client got every event after the snapshot, and each once.
    # The registration and the snapshot happen in one server handler, so no
    # event at or below the snapshot reaches it.
    assert Enum.map(events, & &1.seq) ==
             for(%Event{seq: seq} <- watched, seq > snapshot.seq, do: seq)

    assert transcript(fold(snapshot, events)) == transcript(fold(first, watched))
    LateClient.disconnect(late)
  end

  test "a join after a failed turn with a partial reply", %{core: core, gate: gate} do
    {:ok, session} = Session.start(core, model: "gated/fail." <> gate)
    {:ok, first, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, stream}
    send(stream, :go)
    events = collect_until(:turn_end)
    live = fold(first, events)

    assert [_user, %Message{stop_reason: :error}, {:notice, "error: " <> _}] =
             ViewModel.cells(live)

    assert_joins_after_end(session, live, events)
  end

  test "a join after an abort during a partial reply", %{core: core, gate: gate} do
    {:ok, session} = Session.start(core, model: "gated/partial." <> gate)
    {:ok, first, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, _stream}
    :ok = Session.abort(session)
    events = collect_until(:turn_end)
    live = fold(first, events)
    assert [_user, %Message{stop_reason: :aborted}, {:notice, "aborted"}] = ViewModel.cells(live)

    assert_joins_after_end(session, live, events)
  end

  # A call with no result gets an `aborted` result at the normal end of a
  # connected turn: the live fold and the snapshot both show a closed cell.
  test "a join after a connected turn that ends with an open call", %{core: core, gate: gate} do
    {:ok, session} = Session.start(core, model: "gated/dangling." <> gate)
    {:ok, first, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    events = collect_until(:turn_end)
    live = fold(first, events)

    {:ok, snapshot, _} = Session.subscribe(session)
    joined = ViewModel.from_snapshot(snapshot)
    assert snapshot.seq == List.last(events).seq

    assert [_user, %Message{role: :assistant}, {:tool, %{id: "d"}, _, aborted}] =
             ViewModel.cells(joined)

    assert %Message{is_error: true, content: [%Message.Text{text: "aborted"}]} = aborted
    assert transcript(joined) == transcript(live)
  end

  # An abort while the first of three calls runs: the two calls that never
  # ran get `aborted` results. Every event of the session, folded,
  # gives the cells of a snapshot at the same seq.
  test "a join after an abort of three calls", %{core: core, gate: gate} do
    calls =
      for id <- ~w(c1 c2 c3),
          do: %Message.ToolCall{id: id, name: "gate", arguments: %{"gate" => gate}}

    :ok = Fake.script(core, "abort3", [["Running." | calls], ["Done."]])
    {:ok, session} = Session.start(core, model: "fake/abort3")
    {:ok, first, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:waiting, _tool}
    :ok = Session.abort(session)
    events = collect_until(:turn_end)
    live = fold(first, events)

    assert [_user, _assistant, c1, c2, c3, {:notice, "aborted"}] = ViewModel.cells(live)

    for {cell, id} <- [{c1, "c1"}, {c2, "c2"}, {c3, "c3"}],
        do: assert({:tool, %{id: ^id}, _, %Message{is_error: true}} = cell)

    {:ok, snapshot, _} = Session.subscribe(session)
    assert snapshot.seq == List.last(events).seq
    assert transcript(ViewModel.from_snapshot(snapshot)) == transcript(live)
  end

  test "a session with no events has seq 0 and no notice", %{core: core} do
    {:ok, session} = Session.start(core, model: "fake/echo")
    {:ok, snapshot, _} = Session.subscribe(session)

    assert %{seq: 0, messages: [], turn: nil, model: "fake/echo"} = snapshot

    vm = ViewModel.from_snapshot(snapshot)
    assert %{model: "fake/echo", streaming: nil, running?: false} = vm
    assert vm.queue == %{steers: 0, follow_ups: 0}
    assert ViewModel.cells(vm) == []
  end

  # A client that joins after the turn ended shows the transcript cells of
  # the client that watched, the partial reply too, and not its notice.
  defp assert_joins_after_end(session, live, events) do
    {:ok, snapshot, _} = Session.subscribe(session)
    assert snapshot.seq == List.last(events).seq
    joined = ViewModel.from_snapshot(snapshot)
    assert transcript(joined) == transcript(live)
    assert ViewModel.cells(joined) == Enum.drop(ViewModel.cells(live), -1)
  end

  # The events of the first client up to `seq`, which are in the mailbox.
  defp events_to(seq, acc \\ []) do
    assert_receive {:helyx_event, event}
    if event.seq == seq, do: Enum.reverse([event | acc]), else: events_to(seq, [event | acc])
  end

  defp fold(%ViewModel{} = vm, events), do: Helyx.Test.ViewModelRule.fold(vm, events)
  defp fold(snapshot, events), do: fold(ViewModel.from_snapshot(snapshot), events)
end
