# The cost of a long transcript in the TUI view model (#407). Not a test: it
# asserts nothing and only prints the times. Run from plugins/bundled:
#
#     mix run bench/view_model.exs
#
# Each round is one user message, one assistant message with one tool call,
# and its result: three cells. It times the live fold of the events, the
# snapshot fold of the messages, and one frame of the transcript. The code is
# in a module, so it runs compiled and not through the evaluator, and each
# size runs in a new process, so one size does not pay for the heap of
# another.
defmodule Helyx.Bench.ViewModel do
  @moduledoc false

  alias ExRatatui.Layout.Rect
  alias Helyx.{Event, Message}
  alias Helyx.Session.Snapshot
  alias Helyx.TUI.{Transcript, ViewModel}

  def run(rounds) do
    messages = Enum.flat_map(1..rounds, &messages/1)
    events = messages |> Enum.with_index(1) |> Enum.map(&event/1)

    {live_ms, vm} =
      ms(fn -> Enum.reduce(events, ViewModel.new("bench/m"), &ViewModel.apply(&2, &1)) end)

    snapshot = %Snapshot{
      instance_id: "i",
      seq: length(events),
      messages: messages,
      turn: nil,
      model: "bench/m",
      queue: %{steers: 0, follow_ups: 0}
    }

    {snapshot_ms, _vm} = ms(fn -> ViewModel.from_snapshot(snapshot) end)
    {frame_ms, _widget} = ms(fn -> Transcript.widget(vm, nil, %Rect{width: 100, height: 40}) end)
    cells = length(ViewModel.cells(vm))
    "cells=#{cells} live_fold=#{live_ms}ms snapshot_fold=#{snapshot_ms}ms frame=#{frame_ms}ms"
  end

  defp messages(i) do
    call = %Message.ToolCall{id: "c#{i}", name: "bash", arguments: %{"command" => "ls"}}
    answer = %Message{role: :assistant, content: [%Message.Text{text: "Run."}, call]}
    [Message.user("go #{i}"), answer, Message.tool_result(call, {:ok, "lib\ntest"})]
  end

  defp event({%Message{role: :tool_result} = message, seq}),
    do: event(:tool_execution_end, message, seq)

  defp event({message, seq}), do: event(:message_end, message, seq)

  defp event(type, message, seq) do
    data = %{message: message}
    %Event{type: type, session_id: "s", instance_id: "i", turn_id: "t", seq: seq, data: data}
  end

  defp ms(fun) do
    {us, value} = :timer.tc(fun)
    {Float.round(us / 1000, 1), value}
  end
end

for rounds <- [1_000, 10_000, 100_000] do
  task = Task.async(fn -> Helyx.Bench.ViewModel.run(rounds) end)
  IO.puts(Task.await(task, :infinity))
end
