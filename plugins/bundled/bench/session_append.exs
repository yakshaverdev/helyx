# The session-side cost of a long, tool-heavy session (#669). Not a test:
# it prints the numbers, and its checks only stop a run that measured the
# wrong thing. Run from plugins/bundled:
#
#     mix run bench/session_append.exs
#
# The prior transcript is rounds of a user message, an assistant message with
# one tool call, and its 100-byte result. The parts, each at about 1,000,
# 10,000, and 30,000 prior messages:
#
#   * append: `transcript ++ [message]`, as `Records` appends.
#   * open_calls: `Transcript.open_calls/1` with a batch of 8 calls, 4 open.
#   * copy: one send of the transcript to another process, which answers
#     `:ok`. A provider round sends its context in the same way
#     (`Server.Prepare`).
#   * resume fold: `File.Reader.read/2` and `Transcript.repair/1` of the file.
#   * file append: `File.append_message/2` of one 1 KiB and one 64 KiB result.
#   * json: `JSON.encode!/1` of the entry of the same results.
#   * batch: one turn through a resumed session with the Fake provider and no
#     ModelContext plugin: 1 or 4 rounds of 8 tool calls with a 1 KiB or
#     64 KiB result, then a text reply. Each batch runs with persistence on,
#     and with persistence off. For "off", the file is read-only: the first
#     append fails, and the session stops saving.
#
# A part gives the median of its runs: time in ms and reductions, and the
# words that its result adds to the heap, shared terms counted once, in KiB.
# A batch counts the session process only, and its heap is the growth of
# the flat size of the transcript in the session state. The tools and the
# provider run in other processes. The heap does not count the bytes of a
# binary over 64 bytes, which is outside the process heap.
#
# A batch that fails, or a persistence mode that did not hold over a batch,
# stops the run. Each size runs in a new process, so one size does not pay
# for the heap of another.
defmodule Helyx.Bench.SessionAppend do
  @moduledoc false

  alias Helyx.{Event, Message, Session}
  alias Helyx.Session.File.{Codec, Reader}
  alias Helyx.Session.{Id, Transcript}

  @runs 21
  @batches 5
  @calls 8
  @bytes [1024, 65_536]
  @cwd "/bench"
  @model "fake/bench"

  defmodule Tool do
    @moduledoc false
    # Returns `bytes` bytes, so a batch has results of a fixed size.
    @behaviour Helyx.Tool

    @impl true
    def name, do: "blob"
    @impl true
    def description, do: "Returns bytes."
    @impl true
    def parameters, do: %{"type" => "object"}
    @impl true
    def run(%{"bytes" => bytes}, _cwd), do: {:ok, String.duplicate("x", bytes)}
  end

  def json do
    for bytes <- @bytes do
      entry = Codec.encode(result("c", bytes))
      line("json #{bytes}B", measure(entry, &JSON.encode!/1))
    end
  end

  def run(size, root) do
    transcript = Enum.flat_map(1..div(size, 3), &round_messages/1)
    dir = Path.join(root, "s#{size}")
    file = write(dir, transcript)
    n = length(transcript)

    message = Message.user("next")
    line("n=#{n} append", measure(transcript, &(&1 ++ [message])))

    open = transcript ++ open_batch()
    line("n=#{n} open_calls", measure(open, &Transcript.open_calls/1))

    mib = div(:erts_debug.flat_size(transcript) * 8, 1024 * 1024)
    echo = spawn_link(&echo/0)
    line("n=#{n} copy (#{mib} MiB)", measure(transcript, &copy(echo, &1)))

    raw = File.read!(file.path)
    label = "n=#{n} resume fold (#{div(byte_size(raw), 1024)} KiB)"
    line(label, measure(raw, &fold/1, 5))

    for {rounds, bytes} <- [{1, 1024}, {1, 65_536}, {4, 1024}], persist <- [:on, :off] do
      batch_dir = Path.join(root, "b#{size}-#{rounds}-#{bytes}-#{persist}")
      File.cp_r!(dir, batch_dir)
      label = "n=#{n} batch #{rounds}x#{@calls} calls #{bytes}B persistence #{persist}"
      line(label, batches(batch_dir, rounds, bytes, persist))
    end

    # After the batches, which copy the file first.
    for bytes <- @bytes do
      append = &Helyx.Session.File.append_message(file, %{&1 | id: Id.new()})
      line("n=#{n} file append #{bytes}B", measure(result("c", bytes), append))
    end
  end

  defp fold(raw) do
    {:ok, read, _tail} = Reader.read(raw, @cwd)
    Transcript.repair(read.messages)
  end

  # A one-way copy: the echo process answers `:ok`.
  defp copy(echo, term) do
    send(echo, {self(), term})
    receive do: (:ok -> :ok)
  end

  defp echo do
    receive do: ({from, _term} -> send(from, :ok))
    echo()
  end

  # One resumed session, one warm-up batch, then @batches batches. A batch
  # is one turn of `rounds` provider replies of @calls calls each, then a
  # text reply: 2 + rounds * (@calls + 1) messages with the prompt.
  defp batches(dir, rounds, bytes, persist) do
    core = :"bench_#{System.unique_integer([:positive])}"
    {:ok, sup} = Helyx.Core.start_link(name: core, plugins: [Helyx.Provider.Fake, Tool])
    calls = for i <- 1..@calls, do: call("b#{i}", bytes)
    turn = List.duplicate(calls, rounds) ++ [["Done."]]

    :ok =
      Helyx.Provider.Fake.script(core, "bench", Enum.concat(List.duplicate(turn, @batches + 1)))

    {:ok, session} = Session.resume(core, sessions_dir: dir, cwd: @cwd)
    {:ok, _snapshot, _ref} = Session.subscribe(session, tail: 1)

    [file] = Path.wildcard(Path.join(dir, "*/*.jsonl"))
    if persist == :off, do: File.chmod!(file, 0o444)
    batch(session, file, rounds, persist)
    samples = for _ <- 1..@batches, do: batch(session, file, rounds, persist)
    Supervisor.stop(sup)
    median(samples)
  end

  # The heap of a batch is the growth of the flat size of the transcript, not
  # of the whole state, which also holds the replay ring of the events. It is
  # read outside the timed part and the counted reductions.
  defp batch(session, file, rounds, persist) do
    pid = Session.pid(session)
    bytes = File.stat!(file).size
    words = :erts_debug.flat_size(:sys.get_state(pid).transcript)
    {:reductions, r0} = Process.info(pid, :reductions)
    t0 = System.monotonic_time(:microsecond)
    :ok = Session.prompt(session, "go")
    results = turn_end(0)
    t1 = System.monotonic_time(:microsecond)
    {:reductions, r1} = Process.info(pid, :reductions)
    # Every call of the batch succeeded.
    ^results = rounds * @calls
    # The mode held over the batch: with persistence on, the file grew and
    # the session still saves; with it off, the file did not grow.
    state = :sys.get_state(pid)
    true = File.stat!(file).size > bytes == (persist == :on)
    true = is_nil(state.file) == (persist == :off)
    {t1 - t0, r1 - r0, :erts_debug.flat_size(state.transcript) - words}
  end

  # The count of tool results that succeeded, at a turn end that is done.
  defp turn_end(results) do
    receive do
      {:helyx_event, %Event{type: :turn_end, data: %{outcome: :done}}} ->
        results

      {:helyx_event, %Event{type: :turn_end} = event} ->
        raise "batch failed: #{inspect(event)}"

      {:helyx_event, %Event{type: :tool_execution_end, data: %{message: %{is_error: false}}}} ->
        turn_end(results + 1)

      {:helyx_event, _event} ->
        turn_end(results)
    end
  end

  # The file of a session with `transcript`, written by the session writer.
  defp write(dir, transcript) do
    {:ok, file} = Helyx.Session.File.create(dir, Id.new(), @cwd, @model)
    Enum.reduce(transcript, file, &Helyx.Session.File.append_message(&2, &1))
  end

  defp round_messages(i) do
    content = [%Message.Text{text: "Run."}, call("c#{i}", 100)]
    answer = %Message{role: :assistant, content: content, id: Id.new()}
    [%{Message.user("go #{i}") | id: Id.new()}, answer, result("c#{i}", 100)]
  end

  # An assistant message with @calls calls and the results of half of them.
  defp open_batch do
    calls = for i <- 1..@calls, do: call("o#{i}", 100)
    answer = %Message{role: :assistant, content: calls, id: Id.new()}
    results = for c <- Enum.take(calls, div(@calls, 2)), do: Message.tool_result(c, {:ok, "ok"})
    [answer | results]
  end

  defp call(id, bytes),
    do: %Message.ToolCall{id: id, name: "blob", arguments: %{"bytes" => bytes}}

  defp result(id, bytes),
    do: %{
      Message.tool_result(call(id, bytes), {:ok, String.duplicate("x", bytes)})
      | id: Id.new()
    }

  # The heap of a part is the same in each run: the words of the result
  # that the input does not hold (`size_shared/1` counts a shared term
  # once). It comes from one more run, so no timed run holds a result.
  defp measure(input, fun, runs \\ @runs) do
    samples =
      for _ <- 1..runs do
        :erlang.garbage_collect()
        r0 = reductions()
        {us, _value} = :timer.tc(fun, [input])
        {us, reductions() - r0}
      end

    words = :erts_debug.size_shared({input, fun.(input)}) - :erts_debug.size_shared({input, nil})
    {us, reductions} = median(samples)
    {us, reductions, words}
  end

  defp reductions, do: self() |> Process.info(:reductions) |> elem(1)

  # The median of each column of the samples.
  defp median(samples) do
    samples
    |> Enum.map(&Tuple.to_list/1)
    |> Enum.zip_with(&(&1 |> Enum.sort() |> Enum.at(div(length(&1), 2))))
    |> List.to_tuple()
  end

  defp line(label, {us, reductions, words}) do
    kib = Float.round(words * 8 / 1024, 1)

    IO.puts(
      "#{label}: #{Float.round(us / 1000, 3)} ms, #{reductions} reductions, #{kib} KiB heap"
    )
  end
end

# The write failure of the `off` batches logs one warning per session.
Logger.configure(level: :error)
# A new folder of this run: the mkdir fails on a folder that exists, so the
# delete at the end removes only what this run made.
root = Path.join(System.tmp_dir!(), "helyx_bench_" <> Base.encode16(:crypto.strong_rand_bytes(8)))
File.mkdir!(root)

try do
  Helyx.Bench.SessionAppend.json()

  # A worker that is not linked: its crash raises here, so the `after` runs.
  for size <- [1_000, 10_000, 30_000] do
    {pid, ref} = spawn_monitor(Helyx.Bench.SessionAppend, :run, [size, root])
    receive do: ({:DOWN, ^ref, :process, ^pid, reason} -> :normal = reason)
  end
after
  File.rm_rf!(root)
end
