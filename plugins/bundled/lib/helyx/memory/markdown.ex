defmodule Helyx.Memory.Markdown do
  # The bounds of a recall: the files that it reads, in order, and the
  # bytes of them in total.
  @max_files 1_000
  @max_file_bytes 1_048_576
  @max_scan_bytes 16 * 1_048_576
  @max_terms 16
  @max_records 32
  @max_record_bytes 1_024
  @max_note_bytes 4_096
  # A record id is `<path>:<line>` and Core takes at most 256 bytes; a file
  # of 1 MiB has at most 7 digits of line number.
  @max_path_bytes 240
  # The write order (#852): a time name `log/time/<bucket>/<seq>-<hash>.md`,
  # with `bucket` the `seq` divided by 1,000. Fixed widths sort as text.
  @per_bucket 1_000
  @bucket ~r/\A[0-9]{9}\z/
  @time_name ~r/\A[0-9]{12}-[0-9a-f]{64}\.md\z/

  @moduledoc """
  The reference memory: a folder of markdown files (`docs/features/memory.md`).

  The folder is `opts[:dir]`, else the `:memory_markdown_dir` env of
  `helyx_plugins`, else `~/.helyx/memory`. `sync/2` writes each message to
  `log/<sha256 of the id>.md` and to a time name that keeps the write order,
  through a temporary file and a hard link, so a message is stored once, also
  for two calls at once. `recall/2` reads at most #{@max_files} files and
  #{@max_scan_bytes} bytes in total, and gives at most #{@max_records} records
  cut to #{@max_record_bytes} bytes.

  The tool `memory_write` appends a note of 1 to #{@max_note_bytes} bytes, as
  one line, to `notes.md`.
  """

  @behaviour Helyx.Memory
  @behaviour Helyx.Tool

  @impl Helyx.Memory
  def recall(%{text: text}, opts) do
    dir = dir(opts)

    case terms(text) do
      [] -> {:ok, []}
      terms -> {:ok, dir |> files() |> scan(dir, terms)}
    end
  end

  defp terms(text) do
    ~r/[\p{L}\p{N}_]+/u
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> Enum.filter(&(String.length(&1) >= 3))
    |> Enum.uniq()
    |> Enum.take(@max_terms)
  end

  defp files(dir) do
    notes = Enum.take(md_files(dir), @max_files)
    notes ++ log_files(Path.join(dir, "log"), @max_files - length(notes))
  end

  # The newest time names, one per hash.
  defp log_files(_log, 0), do: []

  defp log_files(log, room) do
    time = Path.join(log, "time")
    buckets = Enum.reverse(dir_names(time, @bucket))
    {paths, _seen, _left} = newest(buckets, time, {[], MapSet.new(), room})
    Enum.reverse(paths)
  end

  # `acc` is the paths newest last, the hashes taken, and the room left.
  defp newest(_buckets, _time, {_paths, _seen, 0} = acc), do: acc
  defp newest([], _time, acc), do: acc

  defp newest([bucket | buckets], time, acc) do
    dir = Path.join(time, bucket)

    acc =
      dir
      |> dir_names(@time_name)
      |> Enum.reverse()
      |> Enum.reduce_while(acc, &take_newest(&1, &2, dir))

    newest(buckets, time, acc)
  end

  defp take_newest(_name, {_paths, _seen, 0} = acc, _dir), do: {:halt, acc}

  defp take_newest(<<_seq::binary-12, ?-, hash::binary-64, ".md">> = name, acc, dir) do
    {paths, seen, room} = acc

    if MapSet.member?(seen, hash),
      do: {:cont, acc},
      else: {:cont, {[Path.join(dir, name) | paths], MapSet.put(seen, hash), room - 1}}
  end

  # A list, not a wildcard: the folder name can hold glob characters.
  defp md_files(dir), do: for(name <- md_names(dir), do: Path.join(dir, name))

  defp md_names(dir), do: for(name <- dir_names(dir), Path.extname(name) == ".md", do: name)

  # The names of `dir` in name order, or none when it cannot be listed.
  defp dir_names(dir, pattern \\ ~r//) do
    case list_names(dir, pattern) do
      {:ok, names} -> names
      {:error, _reason} -> []
    end
  end

  defp list_names(dir, pattern) do
    with {:ok, names} <- File.ls(dir),
         do: {:ok, for(name <- Enum.sort(names), name =~ pattern, do: name)}
  end

  defp scan(files, dir, terms) do
    {hits, _bytes} =
      Enum.reduce_while(files, {[], 0}, fn path, {hits, bytes} ->
        rel = Path.relative_to(path, dir)

        case read(path, rel) do
          {:ok, text} when bytes + byte_size(text) <= @max_scan_bytes ->
            hits = [matches(text, rel, terms) | hits]
            {:cont, {hits, bytes + byte_size(text)}}

          {:ok, _text} ->
            {:halt, {hits, bytes}}

          :skip ->
            {:cont, {hits, bytes}}
        end
      end)

    hits
    |> Enum.reverse()
    |> List.flatten()
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(@max_records)
    |> Enum.map(fn {_score, record} -> record end)
  end

  # A regular file only (`Helyx.Text.read_file/2`): a FIFO or a device is
  # never opened. A name that cannot make a valid record id is skipped. The
  # stat skips a large file unread; the bounded read skips one that grew
  # after the stat.
  defp read(path, rel) do
    with true <- byte_size(rel) <= @max_path_bytes and String.valid?(rel),
         {:ok, %File.Stat{size: size}} when size <= @max_file_bytes <- File.stat(path),
         {:ok, text} <- Helyx.Text.read_file(path, @max_file_bytes) do
      {:ok, text}
    else
      _ -> :skip
    end
  end

  defp matches(text, rel, terms) do
    {first, label, lines} = label(String.split(text, "\n"))

    hits =
      for {line, n} <- Enum.with_index(lines, first),
          lower = String.downcase(line),
          score = Enum.count(terms, &String.contains?(lower, &1)),
          score > 0,
          do: {score, n, line}

    # Only the best lines of a file can be among the best of all files, and
    # the sort is stable. A common word matches most lines, and a record of
    # each would cost more than the scan.
    hits
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(@max_records)
    |> Enum.map(fn {score, n, line} ->
      source = "#{rel}:#{n}"
      text = Helyx.Text.cap(label <> line, @max_record_bytes, :head)
      {score, %{id: source, source: source, text: text}}
    end)
  end

  # The number of the first line after the header of a synced message,
  # the label of its role, and the lines.
  defp label(["<!-- helyx-memory role=" <> rest | lines]) do
    case rest do
      "assistant " <> _ -> {2, "(generated by the assistant) ", lines}
      "tool_result " <> _ -> {2, "(tool output) ", lines}
      _ -> {2, "", lines}
    end
  end

  defp label(lines), do: {1, "", lines}

  @impl Helyx.Memory
  def sync(entries, opts) do
    log = Path.join(dir(opts), "log")

    with :ok <- File.mkdir_p(Path.join(log, "time")),
         {:ok, seq} <- next_seq(log) do
      entries
      |> Enum.reject(
        &(&1.message.role == :assistant and &1.message.stop_reason in [:aborted, :error])
      )
      |> Enum.reduce_while({:ok, seq}, &store_next(&1, &2, log, opts))
      |> elem(0)
    else
      {:error, reason} -> {:error, "memory folder failed: #{:file.format_error(reason)}"}
    end
  end

  # The next write number: one above the highest in the highest bucket, and
  # at least the first number of that bucket. Fixed widths: the last name is
  # the highest. Two calls at once can take one number; the tie sorts by hash.
  # A listing that fails fails the sync: a number from a partial view would
  # sort the message below the newest ones for good, as the replay skips it.
  # An empty listing, or a `log/time/` that is gone, starts at 0.
  defp next_seq(log) do
    time = Path.join(log, "time")

    case list_names(time, @bucket) do
      {:ok, []} -> {:ok, 0}
      {:error, :enoent} -> {:ok, 0}
      {:ok, buckets} -> next_in(time, List.last(buckets))
      error -> error
    end
  end

  defp next_in(time, bucket) do
    top = String.to_integer(bucket) * @per_bucket

    with {:ok, names} <- list_names(Path.join(time, bucket), @time_name) do
      case List.last(names) do
        nil -> {:ok, top}
        <<seq::binary-12, _rest::binary>> -> {:ok, max(top, String.to_integer(seq) + 1)}
      end
    end
  end

  defp store_next(%{message: message}, {:ok, seq}, log, opts) do
    case store(log, message, seq, opts) do
      {:ok, next} ->
        {:cont, {:ok, next}}

      {:error, reason} ->
        {:halt, {{:error, "memory write failed: #{:file.format_error(reason)}"}, seq}}
    end
  end

  # Insert-or-ignore: the link to the name of the id fails when the name
  # exists. A crash before the link leaves a `.tmp-` file, which recall
  # does not read, and the replay writes the message again.
  defp store(log, message, seq, opts) do
    hash = Base.encode16(:crypto.hash(:sha256, message.id), case: :lower)
    name = Path.join(log, hash <> ".md")

    if File.exists?(name),
      do: {:ok, seq},
      else: link(log, name, {seq, hash}, message, opts)
  end

  defp time_name(log, seq, hash) do
    bucket = pad(div(seq, @per_bucket), 9)
    Path.join([log, "time", bucket, "#{pad(seq, 12)}-#{hash}.md"])
  end

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")

  # The time name first: a crash after it leaves a second time name at the
  # replay, which recall reads once; a crash after the id name first would
  # leave the message with no time name, and recall would not read it.
  defp link(log, name, number, message, opts) do
    tmp = Path.join(log, ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12)))

    result =
      with :ok <- File.write(tmp, [header(message, opts), "\n", body(message), "\n"]),
           {:ok, time, next} <- link_time(tmp, log, number),
           :ok <- link_id(tmp, name, time),
           do: {:ok, next}

    File.rm(tmp)
    result
  end

  # A call with its own time name: a time name that exists belongs to
  # another call of the same message at the same number, which can still
  # fail, so this call takes the next number. Each try takes a name that
  # exists, so the tries end.
  defp link_time(tmp, log, {seq, hash}) do
    time = time_name(log, seq, hash)

    with :ok <- File.mkdir_p(Path.dirname(time)) do
      case File.ln(tmp, time) do
        :ok -> {:ok, time, seq + 1}
        {:error, :eexist} -> link_time(tmp, log, {seq + 1, hash})
        error -> error
      end
    end
  end

  # The loser of a race, or a failed link, removes its own time name.
  defp link_id(tmp, name, time) do
    with {:error, reason} <- File.ln(tmp, name) do
      File.rm(time)
      if reason == :eexist, do: :ok, else: {:error, reason}
    end
  end

  defp header(message, opts) do
    origin = if message.origin, do: message.origin.kind, else: "none"

    "<!-- helyx-memory role=#{message.role} origin=#{origin} id=#{inspect(message.id)} " <>
      "session=#{opts[:session_id]} date=#{Date.utc_today()} -->"
  end

  defp body(message) do
    calls =
      for %Helyx.Message.ToolCall{name: name} <- message.content, do: "\n[tool call: #{name}]"

    Helyx.Message.text(message) <> Enum.join(calls)
  end

  defp dir(opts) do
    opts[:dir] || Application.get_env(:helyx_plugins, :memory_markdown_dir) ||
      Path.join(System.user_home!(), ".helyx/memory")
  end

  @impl Helyx.Tool
  def name, do: "memory_write"

  @impl Helyx.Tool
  def description, do: "Save a note to long-term memory. Later turns and sessions can recall it."

  @impl Helyx.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{"text" => %{"type" => "string", "description" => "The note, one line"}},
      "required" => ["text"]
    }
  end

  @impl Helyx.Tool
  def run(%{"text" => text}, _cwd) when is_binary(text), do: write_note(text, dir([]))
  def run(_args, _cwd), do: {:error, "text must be a string"}

  @doc false
  # The note of `memory_write`, in `dir`.
  def write_note(text, _dir) when byte_size(text) not in 1..@max_note_bytes//1,
    do: {:error, "the note must have 1 to #{@max_note_bytes} bytes"}

  def write_note(text, dir) do
    line = "- " <> String.replace(text, ["\r\n", "\n", "\r"], " ") <> "\n"

    path = Path.join(dir, "notes.md")

    # A regular file only: a write to a FIFO blocks.
    with :ok <- File.mkdir_p(dir),
         :ok <- regular_or_none(path),
         :ok <- File.write(path, line, [:append]) do
      {:ok, "saved"}
    else
      {:error, reason} -> {:error, "memory write failed: #{:file.format_error(reason)}"}
    end
  end

  defp regular_or_none(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _other} -> {:error, :eftype}
      {:error, :enoent} -> :ok
      error -> error
    end
  end
end
