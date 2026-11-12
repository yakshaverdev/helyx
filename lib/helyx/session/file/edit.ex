defmodule Helyx.Session.File.Edit do
  @moduledoc false
  # The delete of a saved session file and the removal of messages from it
  # (docs/features/session-edit.md). Each call registers `{:edit, id}` in the
  # session Registry of the Core, then looks up the id. A session of the id,
  # or another edit of it, is `{:error, :running}`. The Core holds the lock
  # of the data folder, so no other OS process writes the folder.

  alias Helyx.Message
  alias Helyx.Session.File, as: SessionFile
  alias Helyx.Session.File.Reader
  alias Helyx.Session.Killer

  defmodule Copy do
    @moduledoc false
    # The state of the copy. `out` is the open copy; `buffer` holds the kept
    # lines not yet written, reversed, `size` bytes.
    @enforce_keys [:removed, :calls, :out]
    defstruct [:removed, :calls, :out, :leaf, :last, pending: [], next: %{}, buffer: [], size: 0]
  end

  # The bytes of kept lines in one append to the copy.
  @batch_bytes 1_048_576

  @doc false
  # Runs `fun`, the work of a call of `Helyx.Sessions`, in a Task of `core`,
  # and gives its report. With a budget, the killer kills the Task at its
  # deadline, also when the caller is gone. `fun` gets the pid of the killer
  # and disarms it before it renames, so a kill never follows a rename. The
  # report is `:timeout` only when the killer reports its own kill, and
  # `:unknown` for any other end of the Task with no result.
  def run(core, budget, fun) do
    caller = self()

    task =
      Task.Supervisor.async_nolink(Helyx.Core.task_supervisor(core), fn ->
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

  # The killer ends after the Task, at its kill or at the `:DOWN` of the Task.
  defp report({:exit, _reason}, {pid, monitor}) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, :fired} -> {:error, :timeout}
      {:DOWN, ^monitor, :process, ^pid, _reason} -> {:error, :unknown}
    end
  end

  @doc false
  # Removes the file `path` of the session `id` of `core` and the copy that a
  # removal left. The copy goes first, so an error leaves the session file
  # and a retry.
  def delete(core, id, path) do
    claimed({core, id, path}, fn ->
      with :ok <- exists(path),
           :ok <- remove(tmp(path)),
           do: remove(path)
    end)
  end

  @doc false
  # Removes the message `message_id` and the messages that pair with it from
  # the file `path` of the session `id` of `core`, of the folder `cwd`, and
  # gives their ids in file order: message ids only, as no caller knows the id
  # of another entry. The `hook` entries of their calls go too, and are not in
  # the ids. The copy replaces the file by a rename, and the `killer` of the
  # deadline (`Helyx.Session.Killer`) is disarmed before the rename is sent.
  def remove_message({_core, _id, path} = session, cwd, message_id, killer) do
    claimed(session, fn ->
      with :ok <- exists(path),
           {:ok, resumed, _tail, limits} <- SessionFile.read_picked(path, cwd, []),
           {:ok, ids} <- group(resumed.messages, message_id),
           :ok <- replace(copy_state(resumed.messages, ids), {path, limits}, killer),
           do: {:ok, ids}
    end)
  end

  defp copy_state(messages, ids) do
    removed = MapSet.new(ids)
    %Copy{removed: removed, calls: call_ids(messages, removed), out: nil}
  end

  # The Registry is the exclusion of the Core: the edit registers its key
  # first, then looks up the session, and a session open does the reverse
  # (`Helyx.Session.Server.Open`). The key goes before the result returns,
  # so a call after the result does not see it.
  defp claimed({core, id, _path}, fun) do
    registry = Helyx.Core.sessions_registry(core)

    case Registry.register(registry, {:edit, id}, nil) do
      {:ok, _owner} ->
        result = if Registry.lookup(registry, id) == [], do: fun.(), else: {:error, :running}
        :ok = Registry.unregister(registry, {:edit, id})
        result

      {:error, {:already_registered, _pid}} ->
        {:error, :running}
    end
  end

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

  # A file that is not there counts as removed.
  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> edit_failed(reason)
    end
  end

  defp edit_failed(:ok), do: :ok
  defp edit_failed({:error, reason}), do: edit_failed(reason)

  defp edit_failed(reason),
    do: {:error, {:edit_failed, List.to_string(:file.format_error(reason))}}

  defp tmp(path), do: path <> ".tmp"

  # The message and the messages that pair with it: an assistant message with
  # the run of tool results right after it, whose calls it holds. So the
  # transcript keeps complete call and result pairs.
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

  # The tool calls of a removed assistant message and the call of a removed
  # tool result.
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

  # The copy is made new with an exclusive create, so no file or link at its
  # path is written through. It gets the mode of the session file before its
  # first byte. A copy left by an error or a kill is removed by the next
  # removal or delete of the id.
  defp replace(%Copy{} = state, {path, limits}, killer) do
    tmp = tmp(path)

    result =
      with {:ok, %File.Stat{mode: mode}} <- File.stat(path),
           :ok <- remove(tmp),
           {:ok, out} <- open_copy(tmp, mode),
           :ok <- write_copy(%{state | out: out}, {path, limits}),
           :ok <- Killer.disarm(killer),
           do: edit_failed(File.rename(tmp, path))

    if result != :ok, do: remove(tmp)
    result
  end

  defp open_copy(tmp, mode) do
    with {:ok, out} <- File.open(tmp, [:write, :exclusive, :raw, :binary]),
         :ok <- chmod(out, tmp, mode) do
      {:ok, out}
    else
      {:error, reason} -> edit_failed(reason)
    end
  end

  defp chmod(out, tmp, mode) do
    case File.chmod(tmp, Bitwise.band(mode, 0o7777)) do
      :ok ->
        :ok

      {:error, reason} ->
        File.close(out)
        {:error, reason}
    end
  end

  # The copy closes on every path, so no descriptor outlives the call.
  defp write_copy(state, source) do
    result = copy(state, source)
    closed = File.close(state.out)
    if result == :ok, do: edit_failed(closed), else: result
  end

  # The BEAM reads the session file and writes the copy in this Task.
  defp copy(state, {path, limits}) do
    result =
      File.open(path, [:read, :binary, :raw, :read_ahead], fn input ->
        with {:ok, state} <- lines(input, 1, limits, state),
             do: flush(state)
      end)

    with {:ok, result} <- result, do: result
  end

  defp flush(%Copy{buffer: []}), do: :ok

  defp flush(state), do: edit_failed(:file.write(state.out, Enum.reverse(state.buffer)))

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

  # The read checked every line and the chain; no session of the Core writes
  # the file while the edit holds its key. A line that does not decode to an
  # entry, a torn append, is not copied: a read skips it.
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
  # user or assistant message before it, and with none it goes.
  defp keep(%{"type" => "summary", "first_kept_id" => first} = entry, state) do
    first = if MapSet.member?(state.removed, first), do: Map.get(state.next, first), else: first

    case first do
      nil -> {:drop, state}
      first -> {:keep, relink(%{entry | "first_kept_id" => first}, state), state}
    end
  end

  # A `hook` entry of a removed call goes: it is a log of the answers about
  # that call for the user (docs/features/hooks.md), and its `arguments` and
  # `reason` can hold text of the call and its result.
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
