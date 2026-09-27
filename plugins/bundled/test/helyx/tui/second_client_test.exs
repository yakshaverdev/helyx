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
  alias Helyx.TUI.ViewModel

  import Helyx.Test.ViewModelRule

  # Every wait of this file: no `assert_receive` uses the 100 ms default,
  # so a busy machine does not fail the test.
  @wait 1_000

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
    def run(%{"gate" => gate}, _cwd), do: Helyx.TUI.SecondClientTest.wait(gate)
  end

  defmodule Gated do
    @moduledoc false
    # A provider with a local turn. The model is the name of the gate. The
    # last message of the context picks the reply:
    #
    #   "ok"     a text delta, the gate, more text, one gate call
    #   "fail"   a text delta, the gate, then a stream error
    #   "abort"  a text delta, the gate, more text, two gate calls
    #   other    the text "done"
    @behaviour Helyx.Provider

    @impl true
    def id, do: "gated"

    @impl true
    def stream(gate, %Helyx.Context{messages: messages}, _opts) do
      last = List.last(messages)
      text = if last.role == :user, do: Message.text(last)

      steps(text, gate)
      |> Stream.flat_map(fn
        :gate ->
          Helyx.TUI.SecondClientTest.wait(gate)
          []

        event ->
          [event]
      end)
      |> then(&{:ok, &1})
    end

    defp steps("ok", gate),
      do: [{:text_delta, "hel"}, :gate, {:text_delta, "lo"}] ++ calls(gate, 1)

    defp steps("fail", _gate), do: [{:text_delta, "hel"}, :gate, {:error, :boom}]

    defp steps("abort", gate),
      do: [{:text_delta, "hel"}, :gate, {:text_delta, "lo"}] ++ calls(gate, 2)

    defp steps(_other, _gate), do: [{:text_delta, "done"}, done(:end_turn)]

    defp calls(gate, count) do
      Enum.map(1..count, fn n ->
        {:tool_call, %Message.ToolCall{id: "t#{n}", name: "gate", arguments: %{"gate" => gate}}}
      end) ++ [done(:tool_use)]
    end

    defp done(stop), do: {:done, %{stop_reason: stop, usage: %{}}}
  end

  @doc false
  def wait(gate) do
    send(String.to_existing_atom(gate), {:waiting, self()})

    receive do
      :go -> {:ok, "done"}
    end
  end

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Gated, Gate]})
    gate = :"gate_#{System.unique_integer([:positive])}"
    Process.register(self(), gate)
    {:ok, session} = Session.start(core, model: "gated/#{gate}")
    {:ok, snapshot} = Session.subscribe(session)
    %{session: session, live: %{vm: ViewModel.from_snapshot(snapshot), events: []}}
  end

  test "a turn that succeeds", %{session: session, live: live} do
    :ok = Session.prompt(session, "ok")
    {old, live} = join_during_streaming(session, live)

    # The gate call runs; the client comes back, steers, and sees the steer.
    assert_receive {:waiting, tool}, @wait
    {client, view, live} = reconnect(session, live, old)
    steer(client)
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
    steer(client)
    {view, live} = to_end(client, view, live)
    assert view == transcript(live.vm)
  end

  # The accepted difference of ADR 0006 section 3: the second gate call
  # never starts, and the abort gives it an `aborted` result. A client that
  # joins after it shows a closed cell for it; the live client has none.
  test "an abort", %{session: session, live: live} do
    :ok = Session.prompt(session, "abort")
    {old, live} = join_during_streaming(session, live)
    assert_receive {:waiting, _tool}, @wait
    :ok = Session.abort(session)
    live = catch_up(live)

    assert [_abort, %Message{}, {:tool, %{id: "t1"}, _, %Message{}}, {:notice, "aborted"}] =
             live.vm.cells

    {client, view, live} = reconnect(session, live, old, &without_unstarted_call/1)
    steer(client)
    {view, live} = to_end(client, view, live)
    assert without_unstarted_call(view) == transcript(live.vm)
  end

  # The second client joins while the reply streams, checks the rule, and
  # disconnects. The gate is released after it is gone. A snapshot shows no
  # notice and no partial reply of a failed or aborted turn, so only the
  # live side leaves them out.
  defp join_during_streaming(session, live) do
    assert_receive {:waiting, stream}, @wait
    {client, snapshot} = connect(session)
    assert %{partial: %Message{content: [%Message.Text{text: "hel"}]}} = snapshot.turn
    live = catch_up(live, snapshot.seq)
    joined = ViewModel.from_snapshot(snapshot)
    assert joined.streaming == [%Message.Text{text: "hel"}]
    assert joined == transcript(live.vm)

    disconnect(client)
    send(stream, :go)
    {joined, live}
  end

  # The client subscribes again. The new snapshot replaces its old view
  # model: its seq is the snapshot's, and no event at or below it changes
  # the view. `accepted` removes the accepted difference before the
  # comparison.
  defp reconnect(session, live, old, accepted \\ & &1) do
    {client, snapshot} = connect(session)
    live = catch_up(live, snapshot.seq)
    view = ViewModel.from_snapshot(snapshot)
    assert view.seq == snapshot.seq and view.seq > old.seq
    assert fold(view, live.events) == view
    assert accepted.(view) == transcript(live.vm)
    {client, view, live}
  end

  # The client sends a steer.
  defp steer(client) do
    send(client, {:steer, "steer"})
    assert_receive {:steered, ^client, :ok}, @wait
  end

  # Both clients fold their events up to the end of the turn. The second
  # client sees its steer as a user message, and leaves.
  defp to_end(client, view, live) do
    events = client_events(client)
    live = catch_up(live)
    assert List.last(events).seq == live.vm.seq
    view = fold(view, events)
    assert Enum.any?(view.cells, &match?(%Message{role: :user, content: [%{text: "steer"}]}, &1))
    disconnect(client)
    {view, live}
  end

  # A second client: a process that subscribes, sends the test its snapshot
  # and then each event, and steers on request. The test folds its view
  # model.
  defp connect(session) do
    test = self()

    client =
      spawn_link(fn ->
        {:ok, snapshot} = Session.subscribe(session)
        send(test, {:snapshot, self(), snapshot})
        serve(session, test)
      end)

    assert_receive {:snapshot, ^client, snapshot}, @wait
    {client, snapshot}
  end

  defp serve(session, test) do
    receive do
      {:helyx_event, %Event{} = event} ->
        send(test, {:event, self(), event})
        serve(session, test)

      {:steer, text} ->
        send(test, {:steered, self(), Session.steer(session, text)})
        serve(session, test)

      :disconnect ->
        :ok
    end
  end

  defp disconnect(client) do
    ref = Process.monitor(client)
    send(client, :disconnect)
    assert_receive {:DOWN, ^ref, :process, ^client, _reason}, @wait
  end

  defp client_events(client, acc \\ []) do
    receive do
      {:event, ^client, %Event{type: :agent_end} = event} -> Enum.reverse([event | acc])
      {:event, ^client, event} -> client_events(client, [event | acc])
    after
      @wait -> flunk("the second client got no agent_end")
    end
  end

  # The live client folds its events up to `seq`, or up to an agent_end
  # when `seq` is nil. `events` holds every event it received.
  defp catch_up(live, seq \\ nil)
  defp catch_up(%{vm: %{seq: at}} = live, seq) when seq != nil and at >= seq, do: live

  defp catch_up(live, seq) do
    receive do
      {:helyx_event, %Event{} = event} ->
        live = %{vm: ViewModel.apply(live.vm, event), events: live.events ++ [event]}
        if seq == nil and event.type == :agent_end, do: live, else: catch_up(live, seq)
    after
      @wait -> flunk("the live client got no event up to #{inspect(seq)}")
    end
  end

  defp without_unstarted_call(view) do
    {[{:tool, %{id: "t2"}, _line, aborted}], cells} =
      Enum.split_with(view.cells, &match?({:tool, %{id: "t2"}, _, _}, &1))

    assert %Message{is_error: true, content: [%Message.Text{text: "aborted"}]} = aborted
    %{view | cells: cells}
  end
end
