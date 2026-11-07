defmodule Helyx.Session.File.Edit do
  @moduledoc false
  # The delete of a saved session file and the removal of messages from it
  # (docs/features/session-edit.md). Each call takes the writer lock of the
  # file (`Helyx.Session.Lock`), works under it, and releases it, so no
  # session writes the file meanwhile; a held lock, or a session of the id
  # in the Registry of the Core after the take, is `{:error, :running}`.
  # The caller traps exits, as `Lock.take/1` needs, and owns the port:
  # `run/3` runs each call in such a Task and derives its report. The
  # change of the file itself, an unlink or the rename of the rewritten
  # copy, is a command of the perl process that holds the lock, so it never
  # happens after the lock has ended.

  alias Helyx.Message
  alias Helyx.Session.File, as: SessionFile
  alias Helyx.Session.File.Reader
  alias Helyx.Session.{Killer, Lock}

  defmodule Copy do
    @moduledoc false
    # The state of the copy: the removed message ids, and the call ids of
    # their tool calls and results (`calls`), the id of the last kept
    # entry (`leaf`) and message (`last`), the removed ids that wait for the
    # next kept user or assistant message (`pending`), and that message for
    # each of them (`next`).
    # `lock` writes the copy; `buffer` holds the kept lines not yet sent,
    # reversed, `size` bytes.
    @enforce_keys [:removed, :calls, :lock]
    defstruct [:removed, :calls, :lock, :leaf, :last, pending: [], next: %{}, buffer: [], size: 0]
  end

  # The bytes of kept lines in one append to the copy.
  @batch_bytes 1_048_576

  @doc false
  # Runs `fun`, the work of a call of `Helyx.Sessions`, in a Task of `core`
  # and gives its report. The work runs in a Task that owns the port of the lock and traps its
  # exits, so the caller gets no message of it. With a budget, the caller
  # arms a killer of the Task, which kills it at its deadline, also when the
  # caller is gone: its port closes, and perl exits and frees the lock.
  # `fun` gets the pid of the killer and disarms it before it sends the
  # rename, so a kill of the killer never follows a sent rename. The report
  # derives from what happened: `:timeout` only when the killer reports its
  # own kill, and `:unknown` for any other end of the Task with no result,
  # such as the kill of its supervisor at a Core stop, which can come after
  # the rename was sent.
  def run(core, budget, fun) do
    caller = self()

    task =
      Task.Supervisor.async_nolink(Helyx.Core.task_supervisor(core), fn ->
        Process.flag(:trap_exit, true)
        fun.(killer(caller, budget))
      end)

    killer = if budget, do: Killer.arm(task.pid, budget)
    if killer, do: send(task.pid, {:killer, elem(killer, 0)})
    report(Task.yield(task, :infinity), killer)
  end

  # The killer comes from the caller; a caller that ends first sends none.
  defp killer(_caller, nil), do: nil

  defp killer(caller, _budget) do
    monitor = Process.monitor(caller)

    receive do
      {:killer, pid} ->
        Process.demonitor(monitor, [:flush])
        pid

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        exit(:normal)
    end
  end

  defp report({:ok, result}, nil), do: result

  defp report({:ok, result}, killer) do
    Killer.cancel(killer)
    result
  end

  defp report({:exit, _reason}, nil), do: {:error, :unknown}

  # The killer ends after the Task, at its kill or at the `:DOWN` of the
  # Task.
  defp report({:exit, _reason}, {pid, monitor}) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, :fired} -> {:error, :timeout}
      {:DOWN, ^monitor, :process, ^pid, _reason} -> {:error, :unknown}
    end
  end

  @doc false
  # Removes the file `path` of the session `id` of `core` and the copy that
  # a removal left. The lock file stays, as at a stop: only its `flock`
  # counts, and a removed lock file would let a second process lock a new
  # file of that path while an older open still holds the first.
  # The copy goes first, so an error leaves the session file and a retry.
  def delete(core, id, path) do
    locked({core, id, path}, fn lock ->
      with :ok <- exists(path),
           :ok <- edit_failed(Lock.remove_file(lock, tmp(path))),
           do: edit_failed(Lock.remove_file(lock, path))
    end)
  end

  @doc false
  # Removes the message `message_id` and the messages that pair with it from
  # the file `path` of the session `id` of `core`, of the folder `cwd`, and
  # gives their ids in file order, message ids only: no caller knows the id
  # of another entry. The `hook` entries of their calls go too, and are not
  # in the ids. The file is read and checked as a resume reads it, with no
  # repair write, then copied without them to `<path>.tmp`, and the copy
  # replaces the file by a rename. The `killer`
  # of the deadline (`Helyx.Session.Killer`) is disarmed before the rename
  # is sent: past that point the result is the answer of perl.
  def remove_message({_core, _id, path} = session, cwd, message_id, killer) do
    locked(session, fn lock ->
      with :ok <- exists(path),
           {:ok, resumed, _tail, limits} <- SessionFile.read_picked(path, cwd, []),
           {:ok, ids} <- group(resumed.messages, message_id),
           :ok <- replace(copy_state(lock, resumed.messages, ids), {path, limits}, killer),
           do: {:ok, ids}
    end)
  end

  defp copy_state(lock, messages, ids) do
    removed = MapSet.new(ids)
    %Copy{removed: removed, calls: call_ids(messages, removed), lock: lock}
  end

  # A session of the id in the Registry of `core` is refused after the
  # take: one that lost its lock goes on, and one in its open takes the lock
  # after it, so the check before the take is not enough. A session that
  # registers after this check gets `{:session_locked, id}` at its take. A
  # session of another Core or OS process is seen at the take while it
  # holds the lock; one that lost its lock is not seen (session-edit.md,
  # accepted holes).
  defp locked({core, id, path}, fun) do
    case Lock.take(path) do
      {:ok, lock} ->
        result = if registered?(core, id), do: {:error, :running}, else: fun.(lock)
        Lock.release(lock)
        result

      {:error, {:session_locked, _id}} ->
        {:error, :running}

      {:error, {:lock_failed, _text}} = error ->
        error
    end
  end

  defp registered?(core, id), do: Registry.lookup(Helyx.Core.sessions_registry(core), id) != []

  # The file can go between the find and the take, by another delete. A
  # symlink is refused: the unlink and the rename would change the link and
  # leave the file that it names.
  defp exists(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :not_regular}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  # The answer of a file command of the lock holder.
  defp edit_failed(:ok), do: :ok
  defp edit_failed({:error, text}), do: {:error, {:edit_failed, text}}

  defp tmp(path), do: path <> ".tmp"

  # The message and the messages that pair with it: an assistant message
  # with the run of tool results right after it, whose calls it holds. A
  # tool result in such a run gives the whole group; any other message is
  # alone. So the transcript keeps complete call and result pairs.
  defp group(messages, id) do
    {before, rest} = Enum.split_while(messages, &(&1.id != id))

    case rest do
      [] ->
        {:error, :message_not_found}

      [%Message{role: :assistant} | _] ->
        {:ok, with_results(rest)}

      [%Message{role: :tool_result} | _] ->
        case Enum.drop_while(Enum.reverse(before), &tool_result?/1) do
          [%Message{role: :assistant} | _] = earlier ->
            {:ok, with_results(Enum.drop(before, length(earlier) - 1) ++ rest)}

          _no_call ->
            {:ok, [id]}
        end

      [_message | _] ->
        {:ok, [id]}
    end
  end

  defp with_results([call | rest]),
    do: [call.id | for(result <- Enum.take_while(rest, &tool_result?/1), do: result.id)]

  defp tool_result?(message), do: message.role == :tool_result

  # The call ids of the removed messages: the tool calls of a removed
  # assistant message and the call of a removed tool result.
  defp call_ids(messages, removed) do
    for %Message{id: id} = message <- messages,
        MapSet.member?(removed, id),
        call_id <- calls(message),
        is_binary(call_id),
        into: MapSet.new(),
        do: call_id
  end

  defp calls(%Message{role: :tool_result, tool_call_id: id}), do: [id]
  defp calls(%Message{content: content}), do: for(%Message.ToolCall{id: id} <- content, do: id)

  defp replace(%Copy{lock: lock} = state, {path, limits}, killer) do
    tmp = tmp(path)

    # Every change of the copy is a command of the lock holder: after the
    # lock has ended, perl has ended, so no byte reaches the copy, and a
    # delete or another removal that takes the lock owns the copy's path.
    result =
      with {:ok, %File.Stat{mode: mode}} <- File.stat(path),
           :ok <- edit_failed(Lock.create_copy(lock, tmp)),
           :ok <- copy(state, {path, limits}),
           :ok <- edit_failed(Lock.close_copy(lock, mode)),
           :ok <- Killer.disarm(killer),
           do: edit_failed(Lock.rename_file(lock, tmp, path))

    if result != :ok, do: Lock.remove_file(lock, tmp)
    result
  end

  # The BEAM reads the session file; perl writes the copy, which it made
  # new with `O_EXCL` and mode 0600 (`Lock.create_copy/2`), so no file or
  # link at its path is written through and no other user reads it. The
  # kept lines go to perl in batches of at least `@batch_bytes`.
  defp copy(state, {path, limits}) do
    result =
      File.open(path, [:read, :binary, :raw, :read_ahead], fn input ->
        with {:ok, state} <- lines(input, 1, limits, state),
             do: flush(state)
      end)

    with {:ok, result} <- result, do: result
  end

  defp flush(%Copy{buffer: []}), do: :ok

  defp flush(state),
    do: edit_failed(Lock.append_copy(state.lock, Enum.reverse(state.buffer)))

  # The batch holds at most `@batch_bytes` and one line of at most the line
  # limit of the read (64 MiB).
  defp emit(state, data) do
    state = %{state | buffer: [data | state.buffer], size: state.size + IO.iodata_length(data)}

    if state.size < @batch_bytes do
      {:ok, state}
    else
      with :ok <- flush(state), do: {:ok, %{state | buffer: [], size: 0}}
    end
  end

  # The read under the lock checked every line and the chain; the file has
  # not changed since. A line that does not decode to an entry, a torn
  # append, is not copied: a read skips it.
  defp lines(input, n, limits, state) do
    case :file.read_line(input) do
      :eof ->
        {:ok, state}

      {:ok, line} ->
        text = String.trim_trailing(line, "\n")

        with {:ok, state} <- line(text, Reader.entry(text, n, limits), state),
             do: lines(input, n + 1, limits, state)

      {:error, _reason} = error ->
        error
    end
  end

  defp line(_text, :none, state), do: {:ok, state}
  defp line(_text, {:error, _reason} = error, _state), do: error

  defp line(text, {:ok, entry}, state) do
    case keep(entry, state) do
      {:drop, state} ->
        {:ok, state}

      {:keep, kept, state} ->
        # An entry that keeps its fields keeps its bytes.
        text = if kept == entry, do: text, else: JSON.encode!(kept)
        emit(%{state | leaf: kept["id"]}, [text, "\n"])
    end
  end

  # The header starts the chain.
  defp keep(%{"type" => "session"} = header, state), do: {:keep, header, state}

  defp keep(%{"type" => "message", "id" => id} = entry, state) do
    if MapSet.member?(state.removed, id) do
      {:drop, %{state | pending: [id | state.pending]}}
    else
      {:keep, relink(entry, state), kept_message(entry, state)}
    end
  end

  # A summary whose first kept message is removed keeps from the next kept
  # user or assistant message before it, and with none it goes: the resume
  # then has the summary before it, or none.
  defp keep(%{"type" => "summary", "first_kept_id" => first} = entry, state) do
    first = if MapSet.member?(state.removed, first), do: Map.get(state.next, first), else: first

    case first do
      nil -> {:drop, state}
      first -> {:keep, relink(%{entry | "first_kept_id" => first}, state), state}
    end
  end

  # A `hook` entry of a removed call goes: it is a log of the answers about
  # that call for the user (docs/features/hooks.md), no code reads it, and
  # its `arguments` and `reason` can hold text of the call and its result.
  # It goes wherever it is in the file, and by its call id alone.
  defp keep(%{"type" => "hook", "call_id" => id} = entry, state) do
    if MapSet.member?(state.calls, id),
      do: {:drop, state},
      else: {:keep, relink(entry, state), state}
  end

  defp keep(entry, state), do: {:keep, relink(entry, state), state}

  # The next kept user or assistant message is the first kept message of a
  # summary that named a removed message before it.
  defp kept_message(%{"id" => id, "role" => role}, state) when role in ["user", "assistant"] do
    next = Map.merge(state.next, Map.new(state.pending, &{&1, id}))
    %{state | last: id, pending: [], next: next}
  end

  defp kept_message(%{"id" => id}, state), do: %{state | last: id}

  # The entry continues the chain of the kept entries, and a `last_id` that
  # names a removed message names the last kept message before it.
  defp relink(entry, state) do
    entry = %{entry | "parent_id" => state.leaf}

    case entry do
      %{"last_id" => id} when is_binary(id) ->
        if MapSet.member?(state.removed, id), do: %{entry | "last_id" => state.last}, else: entry

      _other ->
        entry
    end
  end
end
