defmodule Helyx.Ledger do
  @moduledoc """
  The usage ledger of a sessions folder: the fold of the session files over a
  window into totals, days, models, projects, sessions, replies, tools, hooks,
  denies, compactions, and skips. Nothing new is stored: the report derives
  from the session files, which are the record of truth. The rules, the
  bounds, and the known ceiling are in `docs/features/usage-ledger.md`.
  """

  import Bitwise

  alias Helyx.Ledger.Lines
  alias Helyx.Message
  alias Helyx.Session.File.Codec
  alias Helyx.Session.HookEntry
  alias Helyx.Session.Id
  alias Helyx.Session.Totals

  # The report reads every byte of every kept file; more than this is a job
  # for the indexed store of a later slice.
  @max_files 10_000

  # 2^40 ms is about 35 years. Every larger wall time goes into this bucket.
  @max_bucket 40

  defstruct since: nil,
            until: nil,
            files: 0,
            skipped_files: 0,
            skipped_entries: 0,
            too_large: 0,
            torn: 0,
            totals: %Totals{},
            by_day: %{},
            by_model: %{},
            by_project: %{},
            sessions: %{},
            replies: %{},
            tools: %{},
            hooks: %{},
            denies: %{},
            compactions: 0

  @typedoc "One session of the ledger, keyed by the base name of its file."
  @type session :: %{
          cwd: String.t(),
          prompt: String.t() | nil,
          totals: Totals.t(),
          parent: String.t() | nil
        }

  @typedoc "The tool calls and the histogram of the wall times of one tool."
  @type tool :: %{
          calls: non_neg_integer(),
          errors: non_neg_integer(),
          buckets: %{non_neg_integer() => non_neg_integer()},
          max: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          since: DateTime.t() | nil,
          until: DateTime.t() | nil,
          files: non_neg_integer(),
          skipped_files: non_neg_integer(),
          skipped_entries: non_neg_integer(),
          too_large: non_neg_integer(),
          torn: non_neg_integer(),
          totals: Totals.t(),
          by_day: %{String.t() => Totals.t()},
          by_model: %{String.t() => Totals.t()},
          by_project: %{String.t() => Totals.t()},
          sessions: %{String.t() => session()},
          replies: %{String.t() => %{String.t() => non_neg_integer()}},
          tools: %{String.t() => tool()},
          hooks: %{{String.t(), String.t()} => non_neg_integer()},
          denies: %{String.t() => non_neg_integer()},
          compactions: non_neg_integer()
        }

  @doc """
  Reads the session files under `dir` and folds the entries of the window
  from `:since` up to `:until` into a ledger.

  `:since` and `:until` are UTC `DateTime`s with `since < until`; any other
  value is `{:error, :invalid_window}`. `:cwd` is an absolute folder path that
  keeps one project after `Path.expand/1` of it and of each header `cwd`; a
  relative path is `{:error, :invalid_cwd}` and an absent one reads every
  folder. `:max_files` lowers the file count for a test.

  A file counts in `:skipped_files` when its folder cannot be listed, when it
  is not regular, when it is over the file bound, when it cannot be opened,
  or when its first entry is not a header with a string `cwd`. A file whose
  header `cwd` does not match `:cwd` is left out and is not counted.
  """
  @spec read(Path.t(), keyword()) :: {:ok, t()} | {:error, :invalid_window | :invalid_cwd}
  def read(dir, opts) do
    with {:ok, since, until} <- window(opts),
         {:ok, cwd} <- cwd(opts) do
      max_files = opts |> Keyword.get(:max_files, @max_files) |> max(0)
      {:ok, fold_dir(dir, since, until, cwd, max_files)}
    end
  end

  @doc false
  @spec percentile(tool(), float()) :: non_neg_integer() | nil
  def percentile(%{buckets: buckets, max: max}, p) do
    total = buckets |> Map.values() |> Enum.sum()

    if total == 0, do: nil, else: edge(buckets, max, ceil(p * total), 0, 0)
  end

  defp edge(_buckets, _max, _target, k, _running) when k > @max_bucket, do: nil

  defp edge(buckets, max, target, k, running) do
    running = running + Map.get(buckets, k, 0)

    cond do
      running < target -> edge(buckets, max, target, k + 1, running)
      k == @max_bucket -> max
      true -> 1 <<< k
    end
  end

  defp window(opts) do
    since = opts[:since]
    until = opts[:until]

    if match?(%DateTime{}, since) and match?(%DateTime{}, until) and
         DateTime.compare(since, until) == :lt do
      {:ok, since, until}
    else
      {:error, :invalid_window}
    end
  end

  defp cwd(opts) do
    case Keyword.fetch(opts, :cwd) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, path} when is_binary(path) ->
        if Path.type(path) == :absolute,
          do: {:ok, Path.expand(path)},
          else: {:error, :invalid_cwd}

      {:ok, _other} ->
        {:error, :invalid_cwd}
    end
  end

  defp fold_dir(dir, since, until, cwd, max_files) do
    {paths, skipped} = list_files(dir)
    since_unix = DateTime.to_unix(since)

    {kept, skipped} =
      Enum.reduce(paths, {[], skipped}, fn path, {kept, skipped} ->
        case File.stat(path, time: :posix) do
          {:ok, %File.Stat{type: :regular, mtime: mtime}} when mtime >= since_unix ->
            {[{mtime, path} | kept], skipped}

          {:ok, %File.Stat{type: :regular}} ->
            {kept, skipped}

          {:ok, _stat} ->
            {kept, skipped + 1}

          {:error, _reason} ->
            {kept, skipped + 1}
        end
      end)

    {kept, over} = kept |> Enum.sort(:desc) |> Enum.split(max_files)

    ledger = %__MODULE__{since: since, until: until, skipped_files: skipped + length(over)}
    Enum.reduce(kept, ledger, fn {_mtime, path}, ledger -> read_file(path, ledger, cwd) end)
  end

  defp list_files(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.reduce(names, {[], 0}, &list_folder(dir, &1, &2))
      {:error, _reason} -> {[], 1}
    end
  end

  defp list_folder(dir, name, acc) do
    folder = Path.join(dir, name)

    case File.stat(folder) do
      {:ok, %File.Stat{type: :directory}} -> list_folder_files(folder, acc)
      _other -> acc
    end
  end

  defp list_folder_files(folder, {paths, skipped}) do
    case File.ls(folder) do
      {:ok, files} -> {jsonl(files, folder) ++ paths, skipped}
      {:error, _reason} -> {paths, skipped + 1}
    end
  end

  defp jsonl(names, folder) do
    for name <- names,
        Path.extname(name) == ".jsonl",
        Id.valid?(Path.basename(name, ".jsonl")),
        do: Path.join(folder, name)
  end

  defp read_file(path, ledger, cwd) do
    file = %{id: Path.basename(path, ".jsonl"), header: :pending, calls: %{}}
    acc = %{ledger: ledger, file: file, cwd: cwd}

    case Lines.fold(path, acc, &fold/2) do
      {:ok, acc} -> finish(acc)
      {:error, _reason} -> %{ledger | skipped_files: ledger.skipped_files + 1}
    end
  end

  defp finish(%{file: %{header: header}} = acc) when is_map(header),
    do: %{acc.ledger | files: acc.ledger.files + 1}

  defp finish(%{file: %{header: :mismatch}} = acc), do: acc.ledger
  defp finish(acc), do: %{acc.ledger | skipped_files: acc.ledger.skipped_files + 1}

  # The first decodable entry decides the file. A torn line before it is a
  # skip, as a resume treats it.
  defp fold({:entry, entry}, %{file: %{header: :pending}} = acc) do
    case header(entry) do
      {:ok, header} -> start_file(acc, header)
      :error -> %{acc | file: %{acc.file | header: :invalid}}
    end
  end

  defp fold({:entry, _entry}, %{file: %{header: header}} = acc)
       when header in [:invalid, :mismatch],
       do: acc

  defp fold({:entry, entry}, %{file: %{header: header}} = acc) when is_map(header) do
    case timestamp(entry) do
      {:ok, dt} -> fold_entry(entry, dt, acc)
      :error -> bump(acc, :skipped_entries)
    end
  end

  defp fold({:skip, _kind}, %{file: %{header: header}} = acc)
       when header in [:invalid, :mismatch],
       do: acc

  defp fold({:skip, :torn}, acc), do: bump(acc, :torn)
  defp fold({:skip, :too_large}, acc), do: bump(acc, :too_large)

  defp start_file(acc, header) do
    if match_cwd?(acc.cwd, header["cwd"]) do
      session = %{cwd: header["cwd"], prompt: nil, totals: %Totals{}, parent: parent(header)}

      acc = put_in(acc.ledger.sessions[acc.file.id], session)
      %{acc | file: %{acc.file | header: header}}
    else
      %{acc | file: %{acc.file | header: :mismatch}}
    end
  end

  defp header(%{"type" => "session", "cwd" => cwd} = entry) when is_binary(cwd), do: {:ok, entry}
  defp header(_entry), do: :error

  defp parent(%{"parent" => %{"session_id" => id}}) when is_binary(id), do: id
  defp parent(_header), do: nil

  defp match_cwd?(nil, _cwd), do: true

  defp match_cwd?(cwd, header_cwd) when is_binary(header_cwd),
    do: Path.expand(header_cwd) == cwd

  defp timestamp(%{"ts" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _reason} -> :error
    end
  end

  defp timestamp(_entry), do: :error

  defp bump(acc, field), do: %{acc | ledger: Map.update!(acc.ledger, field, &(&1 + 1))}

  defp in_window?(dt, %{since: since, until: until}) do
    DateTime.compare(dt, since) != :lt and DateTime.compare(dt, until) == :lt
  end

  defp fold_entry(%{"type" => "message"} = entry, dt, acc) do
    case decode(entry) do
      :skip -> bump(acc, :skipped_entries)
      %Message{} = message -> fold_message(message, dt, acc)
    end
  end

  # The hook answer is a count of the window; a bad hook entry is a skip.
  defp fold_entry(%{"type" => "hook"} = entry, dt, acc) do
    if HookEntry.valid?(entry) do
      if in_window?(dt, acc.ledger), do: add_hook(acc, entry) |> add_deny(entry), else: acc
    else
      bump(acc, :skipped_entries)
    end
  end

  defp fold_entry(%{"type" => "compaction"}, dt, acc) do
    if in_window?(dt, acc.ledger), do: bump(acc, :compactions), else: acc
  end

  defp fold_entry(_entry, _dt, acc), do: acc

  defp decode(entry) do
    Codec.decode(entry)
  rescue
    _ -> :skip
  end

  # The prompt is the session's first user message, whether it is inside the
  # window or not: it names the session in the report.
  defp fold_message(%Message{role: :user, origin: %{kind: :user}} = message, _dt, acc),
    do: add_prompt(acc, message)

  defp fold_message(%Message{role: :assistant} = message, dt, acc) do
    acc = add_calls(acc, message, dt)
    if in_window?(dt, acc.ledger), do: add_assistant(acc, message, dt), else: acc
  end

  defp fold_message(%Message{role: :tool_result} = message, dt, acc) do
    if in_window?(dt, acc.ledger), do: add_tool_result(acc, message, dt), else: acc
  end

  defp add_prompt(acc, message) do
    case acc.ledger.sessions[acc.file.id] do
      %{prompt: nil} ->
        prompt = message |> Message.text() |> String.slice(0, 60)
        put_in(acc.ledger.sessions[acc.file.id].prompt, prompt)

      _session ->
        acc
    end
  end

  # A call outside the window still joins `calls`, so a result inside the
  # window finds it.
  defp add_calls(acc, %Message{content: content}, dt) do
    ts = DateTime.to_unix(dt, :millisecond)

    calls =
      Enum.reduce(content, acc.file.calls, fn
        %Message.ToolCall{id: id, name: name}, calls -> Map.put(calls, id, {name, ts})
        _block, calls -> calls
      end)

    %{acc | file: %{acc.file | calls: calls}}
  end

  defp add_assistant(acc, message, dt) do
    model = message.model || "unknown"
    project = acc.file.header["cwd"]
    id = acc.file.id

    ledger = %{acc.ledger | totals: Totals.add(acc.ledger.totals, message)}
    ledger = add_count(ledger, :by_day, day(dt), message)
    ledger = add_count(ledger, :by_model, model, message)
    ledger = add_count(ledger, :by_project, project, message)
    ledger = update_session(ledger, id, message)
    ledger = add_reply(ledger, model, message.stop_reason)

    %{acc | ledger: ledger}
  end

  defp add_count(ledger, field, key, message) do
    Map.update!(ledger, field, fn counts ->
      Map.update(counts, key, Totals.add(%Totals{}, message), &Totals.add(&1, message))
    end)
  end

  defp update_session(ledger, id, message) do
    Map.update!(ledger, :sessions, fn sessions ->
      Map.update!(sessions, id, fn session ->
        %{session | totals: Totals.add(session.totals, message)}
      end)
    end)
  end

  defp add_reply(ledger, model, stop_reason) do
    reason = if stop_reason == nil, do: "none", else: Atom.to_string(stop_reason)

    Map.update!(ledger, :replies, fn replies ->
      Map.update(replies, model, %{reason => 1}, fn counts ->
        Map.update(counts, reason, 1, &(&1 + 1))
      end)
    end)
  end

  defp add_hook(acc, %{"point" => point, "answer" => answer}) do
    %{
      acc
      | ledger:
          Map.update!(acc.ledger, :hooks, fn hooks ->
            Map.update(hooks, {point, answer}, 1, &(&1 + 1))
          end)
    }
  end

  defp add_deny(acc, %{"answer" => "deny", "tool" => tool}) when is_binary(tool) do
    %{
      acc
      | ledger:
          Map.update!(acc.ledger, :denies, fn denies ->
            Map.update(denies, tool, 1, &(&1 + 1))
          end)
    }
  end

  defp add_deny(acc, _entry), do: acc

  defp add_tool_result(acc, message, dt) do
    name = message.tool_name || "unknown"
    wall = wall_ms(acc, message, dt)

    %{acc | ledger: Map.update!(acc.ledger, :tools, &add_tool(&1, name, message.is_error, wall))}
  end

  defp add_tool(tools, name, is_error, wall) do
    Map.update(tools, name, new_tool(is_error, wall), &bump_tool(&1, is_error, wall))
  end

  defp new_tool(is_error, wall) do
    %{calls: 1, errors: error_count(is_error), buckets: %{}, max: nil}
    |> add_wall(wall)
  end

  defp bump_tool(tool, is_error, wall) do
    %{tool | calls: tool.calls + 1, errors: tool.errors + error_count(is_error)}
    |> add_wall(wall)
  end

  defp error_count(true), do: 1
  defp error_count(false), do: 0

  # A negative wall time is a clock step, not a duration.
  defp wall_ms(acc, %Message{tool_call_id: id}, dt) do
    case Map.fetch(acc.file.calls, id) do
      {:ok, {_name, call_ms}} ->
        ms = DateTime.to_unix(dt, :millisecond) - call_ms
        if ms >= 0, do: ms

      :error ->
        nil
    end
  end

  defp add_wall(tool, nil), do: tool

  defp add_wall(tool, ms) do
    k = bucket(ms)

    tool
    |> Map.update!(:buckets, &Map.update(&1, k, 1, fn n -> n + 1 end))
    |> Map.update!(:max, fn
      nil -> ms
      max -> max(max, ms)
    end)
  end

  # Bucket k holds 2^(k - 1) <= v < 2^k ms, and bucket 0 holds 0. The
  # histogram has a fixed size for any number of calls.
  defp bucket(0), do: 0
  defp bucket(ms), do: min(bit_length(ms, 0), @max_bucket)

  defp bit_length(0, n), do: n
  defp bit_length(v, n), do: bit_length(v >>> 1, n + 1)

  defp day(dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()
end
