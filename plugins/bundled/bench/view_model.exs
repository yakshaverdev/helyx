# The cost of a long transcript in the TUI view model (#407, #667). Not a
# test: it asserts nothing and only prints the numbers. Run from
# plugins/bundled:
#
#     mix run bench/view_model.exs [cells ...]
#
# with the cell counts 1,000, 10,000, and 100,000 when none is given. A
# count is rounded down to whole rounds of three cells; the line prints the
# count that ran.
# Each round is one user message, one assistant message with one tool call,
# and its result: three cells. It times the live fold of the events, the
# snapshot fold of the messages, and one static frame of the transcript.
# Then a reply streams into a fixed 100x40 viewport: each delta frame folds
# one text delta and draws the transcript, as the TUI does for each event,
# and each spinner frame draws it with no change, as for a busy tick. A
# frame line gives p50 and p95 of the time and the reductions, and the
# words that the garbage collector reclaimed over all frames of the kind,
# per frame. The code is in a module, so it runs compiled and not through
# the evaluator, and each size runs in a new process, so one size does not
# pay for the heap of another.
defmodule Helyx.Bench.ViewModel do
  @moduledoc false

  alias ExRatatui.Layout.Rect
  alias Helyx.{Event, Message}
  alias Helyx.Session.Snapshot
  alias Helyx.TUI.{Transcript, ViewModel}

  @area %Rect{width: 100, height: 40}
  # 200 deltas of 150 bytes, and a paragraph break after every fourth: a
  # reply of 30,100 bytes. Few frames keep a run under a minute on a loaded
  # machine.
  @deltas 200
  @spinner_frames 50
  @delta String.duplicate("Some **bold** words and `code` in a long reply. ", 3)

  def run(cells) do
    messages = Enum.flat_map(1..div(cells, 3)//1, &messages/1)
    events = messages |> Enum.with_index(1) |> Enum.map(&event/1)

    snapshot = %Snapshot{
      instance_id: "i",
      seq: length(events),
      messages: messages,
      turn: nil,
      model: "bench/m",
      queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
      persisting: true,
      more: false,
      usage: %Helyx.Session.Totals{},
      context: nil
    }

    empty = ViewModel.from_snapshot(%{snapshot | seq: 0, messages: []})
    {live_ms, vm} = ms(fn -> Enum.reduce(events, empty, &ViewModel.apply(&2, &1)) end)

    {snapshot_ms, _vm} = ms(fn -> ViewModel.from_snapshot(snapshot) end)
    {frame_ms, _widget} = ms(fn -> frame(vm) end)
    count = length(ViewModel.cells(vm))

    vm =
      ViewModel.apply(
        vm,
        event(:message_start, %{message: %Message{role: :assistant, content: []}}, 0)
      )

    deltas = Enum.map(1..@deltas, &delta/1)
    {vm, delta_line} = frames(vm, deltas, &frame(ViewModel.apply(&2, &1)))

    {_vm, spinner_line} =
      frames(vm, List.duplicate(nil, @spinner_frames), fn _, vm -> frame(vm) end)

    """
    cells=#{count} live_fold=#{live_ms}ms snapshot_fold=#{snapshot_ms}ms frame=#{frame_ms}ms
      delta+render #{delta_line}
      spinner      #{spinner_line}\
    """
  end

  # The TUI draws the transcript with `screen/3` and `widget/1`.
  defp frame(vm), do: {vm, vm |> Transcript.screen(nil, @area) |> Transcript.widget()}

  # Runs `step` once for each input and gives the last view model and the
  # line of numbers.
  defp frames(vm, inputs, step) do
    :erlang.garbage_collect()
    {_gcs, reclaimed_before, _} = :erlang.statistics(:garbage_collection)

    {vm, samples} =
      Enum.reduce(inputs, {vm, []}, fn input, {vm, samples} ->
        {:reductions, r0} = Process.info(self(), :reductions)
        {us, {vm, _widget}} = :timer.tc(fn -> step.(input, vm) end)
        {:reductions, r1} = Process.info(self(), :reductions)
        {vm, [{us, r1 - r0} | samples]}
      end)

    :erlang.garbage_collect()
    {_gcs, reclaimed_after, _} = :erlang.statistics(:garbage_collection)
    {times, reductions} = Enum.unzip(samples)
    kw = div((reclaimed_after - reclaimed_before) * 8, length(inputs) * 1024)

    line =
      "p50=#{percentile(times, 50) / 1000}ms p95=#{percentile(times, 95) / 1000}ms " <>
        "reds_p50=#{percentile(reductions, 50)} reds_p95=#{percentile(reductions, 95)} " <>
        "alloc=#{kw}KiB/frame"

    {vm, line}
  end

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, div(length(sorted) * p, 100)))
  end

  # A text delta, and a paragraph break after every fourth.
  defp delta(i) do
    text = if rem(i, 4) == 0, do: @delta <> "\n\n", else: @delta

    event(:message_update, %{text_delta: text}, i)
  end

  defp messages(i) do
    call = %Message.ToolCall{id: "c#{i}", name: "bash", arguments: %{"command" => "ls"}}
    answer = %Message{role: :assistant, content: [%Message.Text{text: "Run."}, call]}
    [Message.user("go #{i}"), answer, Message.tool_result(call, {:ok, "lib\ntest"})]
  end

  defp event({%Message{role: :tool_result} = message, seq}),
    do: event(:tool_execution_end, %{message: message}, seq)

  defp event({message, seq}), do: event(:message_end, %{message: message}, seq)

  defp event(type, data, seq),
    do: %Event{type: type, session_id: "s", instance_id: "i", turn_id: "t", seq: seq, data: data}

  defp ms(fun) do
    {us, value} = :timer.tc(fun)
    {Float.round(us / 1000, 1), value}
  end
end

sizes =
  case System.argv() do
    [] -> [1_000, 10_000, 100_000]
    args -> Enum.map(args, &String.to_integer/1)
  end

for cells <- sizes do
  task = Task.async(fn -> Helyx.Bench.ViewModel.run(cells) end)
  IO.puts(Task.await(task, :infinity))
end
