defmodule Helyx.Hub.LiveRead do
  @moduledoc false
  # The read of the live sessions of the Core (`docs/features/live-records.md`),
  # in a Task outside the Hub process, so a session that does not answer
  # blocks the Task, never the Hub. `seed_pending` is the one mechanism of the
  # start and the repair: a read that fails, is killed, or has a snapshot that
  # does not answer leaves it set, and the next poll starts a read. The Hub
  # takes the result as a message and applies the sessions that answered.

  # The bound of the list and of one snapshot, the bound of the whole read, and
  # the margin before the Hub kills it (live-records.md, "Bounds").
  @seed_ms 5_000
  @read_ms @seed_ms + @seed_ms
  @kill_margin_ms 1_000

  def seed_ms, do: @seed_ms
  def read_ms, do: @read_ms
  def kill_margin_ms, do: @kill_margin_ms

  def init(state), do: Map.merge(state, %{seed_pending: true, live_read: nil})

  # A pending read, or a drop of the feed that Hub has not read, starts one
  # read when none is in flight. It returns at once.
  def maybe_read(%{live_read: nil} = state) do
    dropped = Helyx.Sessions.dropped(state.feed)

    if state.seed_pending or dropped > state.feed_dropped,
      do: start(state, dropped),
      else: state
  end

  def maybe_read(state), do: state

  defp start(%{core: core, wake: %{sup: sup}} = state, dropped) do
    task = Task.Supervisor.async_nolink(sup, fn -> run(core) end)
    timer = Process.send_after(self(), {:live_read_timeout, task.ref}, @read_ms + @kill_margin_ms)
    %{state | live_read: %{task: task, ref: task.ref, timer: timer, dropped: dropped}}
  end

  @doc false
  # The body of the read Task: `{:ok, sessions, seeds, pending?}`. A snapshot
  # that does not answer is `:error` in `seeds`, and `pending?` is true.
  def run(core) do
    pairs =
      for live <- Helyx.Sessions.list_live(core),
          pid = Helyx.Session.pid(%Helyx.Session{id: live.id, core: core}),
          is_pid(pid),
          do: {live, pid}

    reads =
      for {live, pid} <- pairs,
          do: {live, pid, Task.async(fn -> open_asks(core, live.id) end)}

    {sessions, seeds, pending?} =
      Enum.reduce(reads, {[], [], false}, fn {live, pid, task}, acc ->
        outcome = Task.yield(task, @seed_ms) || Task.shutdown(task, :brutal_kill)
        collect_seed({live, pid, outcome}, acc)
      end)

    {:ok, Enum.reverse(sessions), Enum.reverse(seeds), pending?}
  end

  defp collect_seed({live, pid, {:ok, {:ok, ask_ids}}}, {sessions, seeds, pending?}),
    do: {[{live, pid} | sessions], [{live.id, {:ok, ask_ids}} | seeds], pending?}

  defp collect_seed({live, _pid, _error_or_timeout}, {sessions, seeds, _pending?}),
    do: {sessions, [{live.id, :error} | seeds], true}

  defp open_asks(core, id) do
    case Helyx.Session.subscribe(%Helyx.Session{id: id, core: core}, tail: 1) do
      {:ok, %Helyx.Session.Snapshot{asks: asks}, _ref} -> {:ok, Enum.map(asks, & &1.ask_id)}
      _error -> :error
    end
  catch
    :exit, _reason -> :error
  end

  # The read of `ref` and the state without it, or nil when no read has it.
  # The timer and the monitor end here, so only the message of this read
  # reaches the Hub.
  @doc false
  def take(%{live_read: %{ref: ref} = read} = state, ref) do
    Process.cancel_timer(read.timer)
    Process.demonitor(ref, [:flush])
    {read, %{state | live_read: nil}}
  end

  def take(_state, _ref), do: nil

  # The result of the read: the successes and the new counts, or the error
  # that keeps the read pending for the next poll.
  @doc false
  def outcome(state, read, {:ok, sessions, seeds, pending?}) do
    state = %{
      state
      | seed_pending: pending?,
        feed_dropped: max(state.feed_dropped, read.dropped)
    }

    {{:ok, sessions, seeds}, state}
  end

  def outcome(state, _read, _other), do: {:error, %{state | seed_pending: true}}

  # The `:DOWN` of a read whose result did not come: a crash leaves it
  # pending, and the next poll reads again.
  def failed(state, ref) do
    case take(state, ref) do
      nil -> state
      {_read, state} -> %{state | seed_pending: true}
    end
  end

  # The Hub's timer past the read's bound: kill it, and leave the read pending.
  def timeout(state, ref) do
    case take(state, ref) do
      nil ->
        state

      {read, state} ->
        _ = Task.shutdown(read.task, :brutal_kill)
        %{state | seed_pending: true}
    end
  end
end
