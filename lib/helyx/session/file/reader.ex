defmodule Helyx.Session.File.Reader do
  @moduledoc false
  # Reads an open session file as one chain (ADR 0001): the header first,
  # then each entry with the id of the entry before it as its `parent_id`.
  # A line that does not decode to an entry is skipped: a torn append. Any
  # other break is `{:invalid_file, text}`. A chain error names its line,
  # and the count includes the skipped lines. The file is read one line at
  # a time, so only the transcript grows with the file
  # (docs/features/coding-agent.md, row "Session file on resume").

  require Logger

  import Helyx.Usage, only: [wire_tokens?: 1]

  alias Helyx.Message
  alias Helyx.Session.File.{Codec, Scan}
  alias Helyx.Session.{HookEntry, Id, ToolRegistry, Transcript}

  @no_header "the first entry is not a header"
  @max_summary_bytes Helyx.Summary.max_bytes()

  # One read of the file.
  @chunk_bytes 1_048_576

  # A line up to this size decodes in the caller, a longer one in a
  # process of its own with the heap cap (the heap of the caller's decode
  # is in the row "Session file on resume").
  @caller_decode_bytes 65_536

  defmodule Limits do
    @moduledoc false
    # `entry`: the most bytes of one line. `heap`: the heap cap of the
    # decode of one line.
    @enforce_keys [:entry, :heap]
    defstruct @enforce_keys
  end

  # Returns the leaf, the current model, the messages, and the resume ids,
  # and whether the file ends in a newline (`:clean` or `:no_newline`). A
  # line over either limit is `{:too_large, text}`.
  def read(io, cwd, %Limits{} = limits), do: lines(io, "", 1, cwd, limits, nil)

  # `buffer` holds the bytes read after the last line taken.
  defp lines(io, buffer, n, cwd, limits, acc) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        with {:ok, acc} <- line(line, n, cwd, limits, acc),
             do: lines(io, rest, n + 1, cwd, limits, acc)

      [partial] ->
        more(io, partial, n, cwd, limits, acc)
    end
  end

  # Reads on until the line that starts with `partial` ends. Only the new
  # chunk is searched for its newline, so a long line costs one pass, and
  # `partial` never holds more than `limits.entry` bytes.
  defp more(io, partial, n, cwd, limits, acc) do
    case :file.read(io, @chunk_bytes) do
      {:ok, chunk} ->
        chunk(io, partial, :binary.split(chunk, "\n"), n, cwd, limits, acc)

      :eof when partial == "" ->
        done(acc, :clean)

      :eof ->
        with {:ok, acc} <- line(partial, n, cwd, limits, acc), do: done(acc, :no_newline)

      {:error, _reason} = error ->
        error
    end
  end

  # The split of a new chunk at its first newline.
  defp chunk(io, partial, [line, rest], n, cwd, limits, acc) do
    with {:ok, acc} <- line(partial <> line, n, cwd, limits, acc),
         do: lines(io, rest, n + 1, cwd, limits, acc)
  end

  defp chunk(_io, partial, [chunk], n, _cwd, limits, _acc)
       when byte_size(partial) + byte_size(chunk) > limits.entry,
       do: over_entry(n, limits)

  defp chunk(io, partial, [chunk], n, cwd, limits, acc),
    do: more(io, partial <> chunk, n, cwd, limits, acc)

  defp line(text, n, cwd, limits, acc) do
    case entry(text, n, limits) do
      {:ok, entry} -> add(entry, n, cwd, acc)
      :none -> {:ok, acc}
      error -> error
    end
  end

  # The entry of the line `text`, number `n`: `{:ok, entry}`, `:none` for a
  # line that does not decode to an entry (a torn append, skipped), or
  # `{:error, {:too_large, text}}` for a line over a limit. A line over the
  # limit is no entry that a session writes, nor a torn part of one.
  def entry(text, n, limits) when byte_size(text) > limits.entry, do: over_entry(n, limits)

  def entry(text, n, limits) do
    case decode(text, limits.heap) do
      {:ok, %{"type" => _} = entry} ->
        {:ok, entry}

      :killed ->
        {:error,
         {:too_large,
          "line #{n} of the session file needs more than #{limits.heap} bytes of memory " <>
            "to load; start a new session"}}

      _not_an_entry ->
        :none
    end
  end

  defp over_entry(n, limits) do
    {:error,
     {:too_large,
      "line #{n} of the session file is over the #{limits.entry}-byte limit of one entry; " <>
        "start a new session"}}
  end

  defp decode(text, _heap) when byte_size(text) <= @caller_decode_bytes,
    do: Helyx.JSON.decode(text)

  # The decode runs in its own process with the heap cap, so a hostile or
  # corrupt line kills only that process. It is not linked, because the
  # heap kill would take the caller with it. The wait has no timeout: the
  # decode of at most `limits.entry` bytes in a capped heap is bounded work.
  defp decode(text, heap) do
    cap = %{size: div(heap, :erlang.system_info(:wordsize)), kill: true, error_logger: false}

    {pid, ref} =
      :erlang.spawn_opt(fn -> exit({:decoded, Helyx.JSON.decode(text)}) end, [
        :monitor,
        {:max_heap_size, cap}
      ])

    receive do
      {:DOWN, ^ref, :process, ^pid, {:decoded, result}} -> result
      {:DOWN, ^ref, :process, ^pid, :killed} -> :killed
      # `Helyx.JSON.decode/1` returns an error for any text that does not
      # decode, so another exit is a bug.
      {:DOWN, ^ref, :process, ^pid, reason} -> exit(reason)
    end
  end

  # The header: the first entry, with a string id and model, a known
  # version, and the directory of the pick. Its own `parent_id` is not read.
  defp add(%{"type" => "session", "id" => id, "model" => model} = header, _n, cwd, nil)
       when is_binary(id) and is_binary(model) do
    with :ok <- Scan.check_version(header),
         :ok <- check_cwd(header, cwd) do
      {:ok,
       %{
         leaf: id,
         ids: %{},
         model: model,
         messages: [],
         resume_ids: %{},
         summary: nil,
         compacted: nil,
         activated: [],
         count: 0
       }}
    end
  end

  defp add(_entry, _n, _cwd, nil), do: {:error, {:invalid_file, @no_header}}

  defp add(%{"id" => id, "parent_id" => leaf} = entry, _n, _cwd, %{leaf: leaf} = acc)
       when is_binary(id),
       do: fold(entry, %{acc | leaf: id})

  defp add(_entry, n, _cwd, _acc),
    do: {:error, {:invalid_file, "line #{n} does not continue the chain of the entry before it"}}

  # The header can change between the pick and this read under the lock.
  defp check_cwd(%{"cwd" => cwd}, cwd), do: :ok
  defp check_cwd(_header, _cwd), do: {:error, :not_found}

  # After the header the writer only produces messages, model changes,
  # tools changes, resume ids, compactions, summaries, system prompts, and
  # hook entries, every model field a string. Anything else is damage on
  # the disk, never dropped in silence, except in a system prompt entry
  # (see its clause) and a hook entry (see its clause).
  # A message id is its entry id, and a client keys messages by it, so a
  # repeated one is damage, and so is an id that `Id.new/0` never makes: it
  # could hold `:`, the separator of the ids that `Transcript.repair/1`
  # derives. Only message ids are kept, with the role of their message:
  # the other entries reach no client.
  defp fold(%{"type" => "message", "id" => id} = entry, acc) do
    cond do
      is_map_key(acc.ids, id) ->
        {:error, {:invalid_file, "a message repeats the id #{inspect(id)}"}}

      not Id.valid?(id) ->
        {:error, {:invalid_file, "a message id is not valid: #{inspect(id)}"}}

      true ->
        message = Codec.decode(entry)
        count = if message.role == :assistant, do: acc.count + 1, else: acc.count
        ids = Map.put(acc.ids, id, message.role)
        {:ok, %{acc | messages: [message | acc.messages], count: count, ids: ids}}
    end
  end

  defp fold(%{"type" => "model_change", "model" => model}, acc) when is_binary(model),
    do: {:ok, %{acc | model: model}}

  # The last tools change gives the activated tool names: distinct tool
  # names, as many as the cap of the writer at most
  # (docs/features/mcp-client.md).
  defp fold(%{"type" => "tools_change", "activated" => names}, acc) when is_list(names) do
    if length(names) <= ToolRegistry.max_activated() and Enum.all?(names, &Helyx.Tool.name?/1) and
         length(Enum.uniq(names)) == length(names),
       do: {:ok, %{acc | activated: names}},
       else: {:error, {:invalid_file, "a tools change entry is not valid"}}
  end

  defp fold(%{"type" => "tools_change"}, _acc),
    do: {:error, {:invalid_file, "a tools change entry is not valid"}}

  defp fold(%{"type" => "harness_session"} = entry, acc),
    do: {:ok, %{acc | resume_ids: resume_id(entry, acc)}}

  # A compaction of the provider after its resume id entry adds the number
  # of assistant messages at that compaction.
  defp fold(%{"type" => "compaction", "provider" => provider} = entry, acc)
       when is_binary(provider) do
    resume_ids = Transcript.compacted(acc.resume_ids, provider, acc.count)
    {:ok, %{acc | resume_ids: resume_ids, compacted: compacted(entry, acc.messages)}}
  end

  # A summary keeps a user or assistant message before it, has a text of
  # 1 to `Helyx.Summary.max_bytes/0` bytes, and a token count from 0 to
  # 10^9 (docs/features/summary-compaction.md). The last one wins.
  defp fold(
         %{"type" => "summary", "summary" => text, "first_kept_id" => id, "tokens_before" => n} =
           entry,
         acc
       )
       when is_binary(text) and text != "" and byte_size(text) <= @max_summary_bytes and
              is_binary(id) and
              :erlang.map_get(id, acc.ids) in [:user, :assistant] and wire_tokens?(n) do
    summary = %Helyx.Summary{text: text, first_kept_id: id, tokens_before: n}
    {:ok, %{acc | summary: summary, compacted: compacted(entry, acc.messages)}}
  end

  defp fold(%{"type" => "summary"}, _acc),
    do: {:error, {:invalid_file, "a summary entry is not valid"}}

  # A system prompt entry is a record for a reader of the file, and a
  # resume sends a fresh build: the chain check of `add/4` is all that it
  # needs, and nothing of it is kept, whatever its fields hold. So an
  # entry over the cap of the writer is skipped, not damage that stops the
  # resume (docs/features/turn-record.md, decisions 2 and 3).
  defp fold(%{"type" => "system_prompt"}, acc), do: {:ok, acc}

  # A hook entry is a log for the user: a resume reads nothing from it. A
  # bad one is dropped and logged, the smallest unit
  # (docs/features/hooks.md).
  defp fold(%{"type" => "hook"} = entry, acc) do
    if not HookEntry.valid?(entry),
      do: Logger.warning("a hook entry of the session file is not valid; it is skipped")

    {:ok, acc}
  end

  defp fold(entry, _acc),
    do: {:error, {:invalid_file, "entry the writer never produces: #{inspect(entry["type"])}"}}

  # The last resume id entry of each provider wins: a lost resume id is
  # followed by a new entry for the same provider. Each keeps the number of
  # assistant messages before it (`Helyx.Session.Transcript.resumable/3`).
  # The label is optional: with none, the provider starts fresh. A bad id
  # removes the label of its provider, so an earlier, stale label does not
  # come back. An entry with no usable provider removes every label,
  # because the reader cannot know which one it replaced. The entry type
  # "harness_session" and its key "harness_session_id" are stored names
  # (`Helyx.Session.File.append_resume_id/3`).
  defp resume_id(%{"provider" => provider} = entry, acc) when is_binary(provider) do
    if Message.resume_id?(entry["harness_session_id"]),
      do: Map.put(acc.resume_ids, provider, {entry["harness_session_id"], acc.count, nil}),
      else: Map.delete(acc.resume_ids, provider)
  end

  defp resume_id(_entry, _acc), do: %{}

  # The last compaction or summary (`Helyx.Session.Totals.of/2`): the
  # message id that its entry names, or with no `last_id` key (an entry from
  # before #712) the message before the entry; a `last_id` that is not a
  # string keeps none. A `tokens_after` that is not a count from 0 to 10^9
  # reads as nil, and a summary has none: it changes only the estimate.
  defp compacted(%{"last_id" => id} = entry, _messages) when is_binary(id),
    do: {id, tokens_after(entry)}

  defp compacted(%{"last_id" => _none}, _messages), do: nil
  defp compacted(entry, [last | _]), do: {last.id, tokens_after(entry)}
  defp compacted(_entry, []), do: nil

  defp tokens_after(entry), do: if(wire_tokens?(entry["tokens_after"]), do: entry["tokens_after"])

  defp done(nil, _tail), do: {:error, {:invalid_file, @no_header}}

  defp done(acc, tail),
    do: {:ok, %{acc | messages: Enum.reverse(acc.messages)}, tail}
end
