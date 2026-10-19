defmodule Helyx.Session.Sync do
  @moduledoc false
  # The sync worker of one session instance (docs/features/memory.md): a
  # temporary child of Core's sync supervisor that the session starts
  # with its instance, and that monitors the session. It calls `sync/2` of the
  # Memory plugin one chunk at a time, in the order of the batches, each
  # call in a linked Task with a limit. A failed call drops its chunk with
  # a notice: a log line, also sent to the session until the worker
  # handles its end. After the session ends it drains the queue for at
  # most `@drain_ms`, and not at all past the session cap plus
  # `@drain_room` workers. A stop with a queue left logs the chunks it
  # drops.

  use GenServer, restart: :temporary, shutdown: 1_000

  require Logger

  alias Helyx.Session.Server.State

  @chunk_messages 64
  @chunk_bytes 1_048_576
  # The bounds of the queue; a live batch over them is dropped, a replay
  # never is.
  @max_chunks 1_024
  @max_bytes 64 * 1_048_576
  @call_ms 30_000
  @drain_ms 30_000
  # A drain starts only while the sync supervisor runs at most the
  # session cap plus this many workers.
  @drain_room 64

  defstruct [:memory, :opts, :session, :task, queue: :queue.new(), bytes: 0]

  # Starts the worker of the calling session at its instance start. The
  # worker gets the replay of a resume first, before any turn can start.
  @spec open(State.t()) :: State.t()
  def open(%State{plugins: %{memory: nil}} = state), do: %{state | sync: nil}

  def open(%State{plugins: %{memory: memory}} = state) do
    opts = [instance_id: state.instance_id] ++ State.base_opts(state)
    args = {memory, opts, self()}

    {:ok, sync} =
      DynamicSupervisor.start_child(Helyx.Core.sync_supervisor(state.core), {__MODULE__, args})

    messages =
      case state.sync do
        {:replay, messages} -> messages
        nil -> []
      end

    replay = for message <- messages, do: %{message: message, persisted: true}
    :ok = push(sync, :replay, replay)
    %{state | sync: sync}
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  # A batch of `%{message:, persisted:}` entries, `:replay` or `:live`. The
  # send does not wait: the session never blocks on its memory.
  @spec push(pid(), :replay | :live, [Helyx.Memory.entry()]) :: :ok
  def push(_pid, _kind, []), do: :ok

  def push(pid, kind, entries) do
    send(pid, {:sync, kind, entries})
    :ok
  end

  # The messages of the turn of the session, at its end or at a stop in it.
  @spec push_turn(State.t()) :: :ok
  def push_turn(%State{sync: nil}), do: :ok

  def push_turn(%State{activity: %Helyx.Session.Turn{}} = state),
    do: push(state.sync, :live, Helyx.Session.Server.Records.turn_entries(state))

  def push_turn(_state), do: :ok

  # The trap makes the exit of a sync Task a message, and runs
  # `terminate/2`, which kills the Task, at a stop of the supervisor.
  @impl true
  def init({memory, opts, session}) do
    Process.flag(:trap_exit, true)
    Process.monitor(session)
    {:ok, %__MODULE__{memory: memory, opts: opts, session: session}}
  end

  # Every callback but `init/1` runs in `Helyx.Reason.no_args/1`, and a
  # crash report shows no state and no message
  # (docs/features/session-lifecycle.md, "Log and crash reports").
  @impl true
  def handle_info(message, state), do: Helyx.Reason.no_args(fn -> info(message, state) end)

  @impl true
  def format_status(status), do: Helyx.Reason.crash_status(status)

  defp info({:sync, kind, entries}, state) do
    chunks = chunks(entries)
    bytes = Enum.sum_by(chunks, &elem(&1, 1))

    if kind == :live and
         (:queue.len(state.queue) + length(chunks) > @max_chunks or
            state.bytes + bytes > @max_bytes) do
      notice(state, "dropped", entries)
      {:noreply, state}
    else
      queue = Enum.reduce(chunks, state.queue, &:queue.in(&1, &2))
      next(%{state | queue: queue, bytes: state.bytes + bytes})
    end
  end

  defp info({ref, result}, %__MODULE__{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    next(result(state, result))
  end

  defp info(
         {:DOWN, ref, :process, _pid, reason},
         %__MODULE__{task: %Task{ref: ref}} = state
       ),
       do: next(failed(state, reason))

  defp info({:call_timeout, ref}, %__MODULE__{task: %Task{ref: ref} = task} = state) do
    # A reply that came at the limit counts.
    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> next(result(state, result))
      _killed -> next(failed(state, :timeout))
    end
  end

  # The session ended: the queue drains, within a bound of time and of
  # draining workers.
  defp info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{session: pid} = state) do
    state = %{state | session: nil}

    if not :queue.is_empty(state.queue) and
         workers(state) > Helyx.Core.max_sessions() + @drain_room do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :drain_end, @drain_ms)
      next(state)
    end
  end

  defp info(:drain_end, state), do: {:stop, :normal, state}

  # The exit of a sync Task, whose `:DOWN` or reply counts, and the
  # timer of an ended call, which is left to fire.
  defp info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  defp info({:call_timeout, _ref}, state), do: {:noreply, state}

  # Every stop with a queue left logs it: the drain limit, the drain cap,
  # and a Core stop.
  @impl true
  def terminate(_reason, state), do: Helyx.Reason.no_args(fn -> stop(state) end)

  defp stop(state) do
    if state.task, do: Process.exit(state.task.pid, :kill)

    if not :queue.is_empty(state.queue) do
      chunks = :queue.to_list(state.queue)
      lost = Enum.sum_by(chunks, fn {chunk, _bytes} -> unsaved(chunk) end)

      Logger.warning(
        "memory sync stopped with #{length(chunks)} chunks left after the session end; " <>
          "#{lost} of their messages were not saved and are lost"
      )
    end
  end

  # The supervisor links each child and its own parent; a call to it
  # could wait for its stop.
  defp workers(state) do
    sup = Process.whereis(Helyx.Core.sync_supervisor(state.opts[:core]))
    {:links, links} = Process.info(sup, :links)
    length(links) - 1
  end

  defp next(%__MODULE__{task: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {chunk, _bytes}}, _queue} ->
        sup = Helyx.Core.task_supervisor(state.opts[:core])
        %{memory: memory, opts: opts} = state
        task = Task.Supervisor.async(sup, fn -> memory.sync(chunk, opts) end)
        Process.send_after(self(), {:call_timeout, task.ref}, @call_ms)
        {:noreply, %{state | task: task}}

      {:empty, _queue} when state.session == nil ->
        {:stop, :normal, state}

      {:empty, _queue} ->
        {:noreply, state}
    end
  end

  defp next(state), do: {:noreply, state}

  defp result(state, :ok), do: done(state)
  defp result(state, {:error, text}) when is_binary(text), do: failed(state, text)
  defp result(state, other), do: failed(state, {:bad_sync, other})

  # The chunk of the ended call leaves the queue.
  defp done(state) do
    {{:value, {_chunk, bytes}}, queue} = :queue.out(state.queue)
    %{state | queue: queue, bytes: state.bytes - bytes, task: nil}
  end

  defp failed(state, reason) do
    {:value, {chunk, _bytes}} = :queue.peek(state.queue)
    Helyx.Reason.log("memory sync failed", reason)
    notice(state, "failed for", chunk)
    done(state)
  end

  # The notice is always a log line, and goes to the session until the
  # worker handles its end.
  defp notice(state, what, entries) do
    count = length(entries)

    text =
      case unsaved(entries) do
        0 -> "memory sync #{what} #{count} messages; the saved ones come back at the next resume"
        n -> "memory sync #{what} #{count} messages; #{n} of them were not saved and are lost"
      end

    Logger.warning(text)
    if state.session, do: send(state.session, {:memory_notice, self(), text})
  end

  defp unsaved(entries), do: Enum.count(entries, &(not &1.persisted))

  # Chunks of at most @chunk_messages entries and @chunk_bytes, with their
  # bytes; an entry over @chunk_bytes goes alone.
  defp chunks(entries) do
    entries
    |> Enum.chunk_while(
      {[], 0, 0},
      fn entry, {acc, n, bytes} ->
        size = :erlang.external_size(entry)

        if acc != [] and (n == @chunk_messages or bytes + size > @chunk_bytes),
          do: {:cont, {Enum.reverse(acc), bytes}, {[entry], 1, size}},
          else: {:cont, {[entry | acc], n + 1, bytes + size}}
      end,
      fn {acc, _n, bytes} -> {:cont, {Enum.reverse(acc), bytes}, nil} end
    )
  end
end
