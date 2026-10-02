defmodule Helyx.TUI.SecondClientTest do
  # The second-client test of ADR 0006 (#191). A second client uses only the
  # contract: `Session.subscribe/1`, `Session.steer/2`, and the events. It
  # joins during streaming, disconnects (its process ends), subscribes again,
  # and sends a steer. The test process is the client that watched from the
  # start. Each join checks the rule of ADR 0006 section 3 against it: the
  # view models are equal except for notices and the partial reply of an
  # aborted or failed turn (`transcript/1`).
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message, Session}
  alias Helyx.Test.{Gate, Gated, LateClient}
  alias Helyx.TUI.ViewModel

  import Helyx.Test.ViewModelRule

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Gated.Loop, Gate]})
    gate = Gate.open()
    {:ok, session} = Session.start(core, model: "gated/#{gate}")
    {:ok, snapshot} = Session.subscribe(session)
    %{session: session, live: %{vm: ViewModel.from_snapshot(snapshot), events: []}}
  end

  test "a turn that succeeds", %{session: session, live: live} do
    :ok = Session.prompt(session, "ok")
    {old, live} = join_during_streaming(session, live)

    # The gate call runs; the client comes back, steers, and sees the steer.
    assert_receive {:waiting, tool}
    {client, view, live} = reconnect(session, live, old)
    LateClient.steer(client, "steer")
    send(tool, :go)

    {view, live} = to_end(client, view, live)
    assert view == transcript(live.vm)
    assert [_ok, %Message{}, {:tool, _, _, %Message{}}, _steer, %Message{}] = view.cells
  end

  test "a turn that fails", %{session: session, live: live} do
    :ok = Session.prompt(session, "fail")
    {old, live} = join_during_streaming(session, live)
    live = catch_up(live)
    assert [_fail, %Message{stop_reason: :error}, {:notice, "error: " <> _}] = live.vm.cells

    {client, view, live} = reconnect(session, live, old)
    LateClient.steer(client, "steer")
    {view, live} = to_end(client, view, live)
    assert view == transcript(live.vm)
  end

  # The second gate call never starts, and the abort gives it an `aborted`
  # result. The live client and a client that joins after it both show a
  # closed cell for it.
  test "an abort", %{session: session, live: live} do
    :ok = Session.prompt(session, "abort")
    {old, live} = join_during_streaming(session, live)
    assert_receive {:waiting, _tool}
    :ok = Session.abort(session)
    live = catch_up(live)

    assert [
             _abort,
             %Message{},
             {:tool, %{id: "t1"}, _, %Message{}},
             {:tool, %{id: "t2"}, _,
              %Message{is_error: true, content: [%Message.Text{text: "aborted"}]}},
             {:notice, "aborted"}
           ] = live.vm.cells

    {client, view, live} = reconnect(session, live, old)
    LateClient.steer(client, "steer")
    {view, live} = to_end(client, view, live)
    assert view == transcript(live.vm)
  end

  # The second client joins while the reply streams, checks the rule, and
  # disconnects. The gate is released after it is gone. A snapshot shows no
  # notice and no partial reply of a failed or aborted turn, so only the
  # live side leaves them out.
  defp join_during_streaming(session, live) do
    assert_receive {:waiting, stream}
    {client, snapshot} = LateClient.connect(session)
    assert %{partial: %Message{content: [%Message.Text{text: "hel"}]}} = snapshot.turn
    live = catch_up(live, snapshot.seq)
    joined = ViewModel.from_snapshot(snapshot)
    assert joined.streaming == [%Message.Text{text: "hel"}]
    assert joined == transcript(live.vm)

    LateClient.disconnect(client)
    send(stream, :go)
    {joined, live}
  end

  # The client subscribes again. The new snapshot replaces its old view
  # model: its seq is the snapshot's, and no event at or below it changes
  # the view.
  defp reconnect(session, live, old) do
    {client, snapshot} = LateClient.connect(session)
    live = catch_up(live, snapshot.seq)
    view = ViewModel.from_snapshot(snapshot)
    assert view.seq == snapshot.seq and view.seq > old.seq
    assert fold(view, live.events) == view
    assert view == transcript(live.vm)
    {client, view, live}
  end

  # Both clients fold their events up to the end of the turn. The second
  # client sees its steer as a user message, and leaves.
  defp to_end(client, view, live) do
    events = LateClient.events_to_end(client)
    live = catch_up(live)
    assert List.last(events).seq == live.vm.seq
    view = fold(view, events)
    assert Enum.any?(view.cells, &match?(%Message{role: :user, content: [%{text: "steer"}]}, &1))
    LateClient.disconnect(client)
    {view, live}
  end

  # The live client folds its events up to `seq`, or up to an agent_end
  # when `seq` is nil. `events` holds every event it received.
  defp catch_up(live, seq \\ nil)
  defp catch_up(%{vm: %{seq: at}} = live, seq) when seq != nil and at >= seq, do: live

  defp catch_up(live, seq) do
    assert_receive {:helyx_event, %Event{} = event}
    live = %{vm: ViewModel.apply(live.vm, event), events: live.events ++ [event]}
    if seq == nil and event.type == :agent_end, do: live, else: catch_up(live, seq)
  end
end
