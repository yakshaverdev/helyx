defmodule Helyx.Session.File.Reader do
  @moduledoc false
  # Reads the bytes of a session file as one chain (ADR 0001): the header
  # first, then each entry with the id of the entry before it as its
  # `parent_id`. A line that does not decode to an entry is skipped: a torn
  # append. Any other break is `{:invalid_file, text}`. A chain error names
  # its line, and the count includes the skipped lines. No I/O.

  import Helyx.Usage, only: [wire_tokens?: 1]

  alias Helyx.Message
  alias Helyx.Session.File.{Codec, Scan}
  alias Helyx.Session.{Id, Transcript}

  @no_header "the first entry is not a header"
  @max_summary_bytes Helyx.Summary.max_bytes()

  # Returns the leaf, the current model, the messages, and the resume ids,
  # and whether the bytes end in a newline (`:clean` or `:no_newline`).
  # Walks the lines one at a time, so a file of many short lines never
  # becomes a list of all its lines.
  def read(raw, cwd), do: lines(raw, 1, cwd, nil)

  defp lines(raw, n, cwd, acc) do
    case :binary.split(raw, "\n") do
      [line, rest] -> with {:ok, acc} <- line(line, n, cwd, acc), do: lines(rest, n + 1, cwd, acc)
      [""] -> done(acc, :clean)
      [line] -> with {:ok, acc} <- line(line, n, cwd, acc), do: done(acc, :no_newline)
    end
  end

  defp line(text, n, cwd, acc) do
    case decode(text) do
      {:ok, %{"type" => _} = entry} -> add(entry, n, cwd, acc)
      _not_an_entry -> {:ok, acc}
    end
  end

  # The decode raises, not returns, for an integer over the BEAM limit.
  defp decode(text) do
    JSON.decode(text)
  rescue
    SystemLimitError -> :error
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
  # resume ids, compactions, and summaries, every model field a string. Anything else
  # is damage on the disk, never dropped in silence.
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
