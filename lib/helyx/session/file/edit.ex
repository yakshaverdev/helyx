defmodule Helyx.Session.File.Edit do
  @moduledoc false
  # The delete of a saved session file and the removal of messages from it
  # (docs/features/session-edit.md). Each call takes the writer lock of the
  # file (`Helyx.Session.Lock`), works under it, and releases it, so no
  # session writes the file meanwhile; a held lock is `{:error, :running}`.
  # The caller traps exits, as `Lock.take/1` needs, and owns the port. The
  # change of the file itself, an unlink or the rename of the rewritten
  # copy, is a command of the perl process that holds the lock, so it never
  # happens after the lock has ended.

  alias Helyx.Message
  alias Helyx.Session.File, as: SessionFile
  alias Helyx.Session.File.Reader
  alias Helyx.Session.{Killer, Lock}

  defmodule Copy do
    @moduledoc false
    # The state of the copy: the removed ids, the id of the last kept
    # entry (`leaf`) and message (`last`), the removed ids that wait for the
    # next kept user or assistant message (`pending`), and that message for
    # each of them (`next`).
    @enforce_keys [:removed]
    defstruct [:removed, :leaf, :last, pending: [], next: %{}]
  end

  @doc false
  # Removes the session file `path` and the copy that a removal left. The
  # lock file stays, as at a stop: only its `flock` counts, and a removed
  # lock file would let a second process lock a new file of that path while
  # an older open still holds the first.
  # The copy goes first, so an error leaves the session file and a retry.
  def delete(path) do
    locked(path, fn lock ->
      with :ok <- exists(path),
           :ok <- edit_failed(Lock.remove_file(lock, tmp(path))),
           do: edit_failed(Lock.remove_file(lock, path))
    end)
  end

  @doc false
  # Removes the message `message_id` and the messages that pair with it from
  # the session file `path` of `cwd`, and gives their ids in file order. The
  # file is read and checked as a resume reads it, with no repair write,
  # then copied without them to `<path>.tmp`, and the copy replaces the
  # file by a rename. The `killer` of the deadline (`Helyx.Session.Killer`)
  # is cancelled before the rename is sent: past that point the result is
  # the answer of perl.
  def remove_message(path, cwd, message_id, killer) do
    locked(path, fn lock ->
      with :ok <- exists(path),
           {:ok, resumed} <- SessionFile.read_picked(path, cwd),
           {:ok, ids} <- group(resumed.messages, message_id) do
        replace(lock, path, ids, killer)
      end
    end)
  end

  defp locked(path, fun) do
    case Lock.take(path) do
      {:ok, lock} ->
        result = fun.(lock)
        Lock.release(lock)
        result

      {:error, {:session_locked, _id}} ->
        {:error, :running}

      {:error, {:lock_failed, _text}} = error ->
        error
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

  defp replace(lock, path, ids, killer) do
    tmp = tmp(path)

    # The removes of the copy are commands of the lock holder too: after
    # the lock has ended, another removal can own a copy at that path.
    result =
      with {:ok, %File.Stat{mode: mode}} <- File.stat(path),
           :ok <- edit_failed(Lock.remove_file(lock, tmp)),
           :ok <- copy(path, tmp, MapSet.new(ids)),
           :ok <- File.chmod(tmp, mode),
           :ok <- Killer.cancel(killer),
           do: edit_failed(Lock.rename_file(lock, tmp, path))

    if result != :ok, do: Lock.remove_file(lock, tmp)
    with :ok <- result, do: {:ok, ids}
  end

  # The copy is made new, with `O_EXCL`, so no file or link at its path is
  # written through.
  defp copy(path, tmp, removed) do
    result =
      File.open(tmp, [:write, :exclusive, :binary, :raw], fn out ->
        File.open(path, [:read, :binary, :raw, :read_ahead], fn input ->
          lines(input, out, 1, SessionFile.limits([]), %Copy{removed: removed})
        end)
      end)

    case result do
      {:ok, {:ok, result}} -> result
      {:ok, error} -> error
      error -> error
    end
  end

  # The read under the lock checked every line and the chain; the file has
  # not changed since. A line that does not decode to an entry, a torn
  # append, is not copied: a read skips it.
  defp lines(input, out, n, limits, state) do
    case :file.read_line(input) do
      :eof ->
        :ok

      {:ok, line} ->
        text = String.trim_trailing(line, "\n")

        with {:ok, state} <- line(out, text, Reader.entry(text, n, limits), state),
             do: lines(input, out, n + 1, limits, state)

      {:error, _reason} = error ->
        error
    end
  end

  defp line(_out, _text, :none, state), do: {:ok, state}
  defp line(_out, _text, {:error, _reason} = error, _state), do: error

  defp line(out, text, {:ok, entry}, state) do
    case keep(entry, state) do
      {:drop, state} ->
        {:ok, state}

      {:keep, kept, state} ->
        # An entry that keeps its fields keeps its bytes.
        text = if kept == entry, do: text, else: JSON.encode!(kept)
        with :ok <- IO.binwrite(out, [text, "\n"]), do: {:ok, %{state | leaf: kept["id"]}}
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
