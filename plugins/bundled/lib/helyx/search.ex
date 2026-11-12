defmodule Helyx.Search do
  @moduledoc false
  # The walk, the glob, and the result of the `grep` and `find` tools
  # (`docs/features/search-tools.md`). A helper (ADR 0005): no interface and
  # no registration entry.

  # Each bound is stated once here and the doc names the function
  # (`docs/features/search-tools.md`, "Bounds").
  @deadline_ms 10_000
  @max_entries 50_000
  @progress_entries 1_024
  @progress_ms 50
  @max_file_bytes 2_097_152
  @max_line_bytes 500
  @max_pattern_bytes 1_000
  @max_glob_bytes 256
  @max_context_lines 5
  @max_grep_limit 1_000
  @default_grep_limit 100
  @max_find_limit 2_000
  @default_find_limit 200

  # The room that the counts of the last lines take, so that the text of the
  # result stays under `Helyx.Message.max_result_bytes/0`.
  @last_lines_bytes 256

  @skipped ~w(.git _build deps node_modules target .elixir_ls)
  @cut_mark "…"

  alias Helyx.Search.Glob

  @typedoc "The tool whose deadline and result this is."
  @type tool :: :grep | :find

  @doc "The most bytes of a `grep` pattern."
  @spec max_pattern_bytes() :: pos_integer()
  def max_pattern_bytes, do: @max_pattern_bytes

  @doc "The most bytes of a `glob`."
  @spec max_glob_bytes() :: pos_integer()
  def max_glob_bytes, do: @max_glob_bytes

  @doc "The most lines of `context` on each side of a match."
  @spec max_context_lines() :: non_neg_integer()
  def max_context_lines, do: @max_context_lines

  @doc "The most matches that `grep` shows."
  @spec max_grep_limit() :: pos_integer()
  def max_grep_limit, do: @max_grep_limit

  @doc "The matches that `grep` shows without a `limit`."
  @spec default_grep_limit() :: pos_integer()
  def default_grep_limit, do: @default_grep_limit

  @doc "The most paths that `find` shows."
  @spec max_find_limit() :: pos_integer()
  def max_find_limit, do: @max_find_limit

  @doc "The paths that `find` shows without a `limit`."
  @spec default_find_limit() :: pos_integer()
  def default_find_limit, do: @default_find_limit

  @doc """
  The most entries that one walk visits, 50,000. A test sets
  `:grep_max_entries` or `:find_max_entries` of `helyx_plugins` to shorten it;
  any other value is the default.
  """
  @spec max_entries(tool()) :: pos_integer()
  def max_entries(tool) do
    case Application.get_env(:helyx_plugins, :"#{tool}_max_entries", @max_entries) do
      max when is_integer(max) and max > 0 -> max
      _other -> @max_entries
    end
  end

  @doc "The most bytes of a file that `grep` reads."
  @spec max_file_bytes() :: pos_integer()
  def max_file_bytes, do: @max_file_bytes

  @doc "The most bytes of one shown line, before its mark."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc """
  The bytes that the matches or paths of a result take, under
  `Helyx.Message.max_result_bytes/0` with the room of its last lines.
  """
  @spec budget() :: pos_integer()
  def budget, do: Helyx.Message.max_result_bytes() - @last_lines_bytes

  @doc """
  The wait of a search, in `System.monotonic_time(:millisecond)`, 10,000 ms.
  A test sets `:grep_deadline_ms` or `:find_deadline_ms` of `helyx_plugins`
  to shorten it; any other value is the default.
  """
  @spec deadline_ms(tool()) :: non_neg_integer()
  def deadline_ms(tool) do
    case Application.get_env(:helyx_plugins, :"#{tool}_deadline_ms", @deadline_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> @deadline_ms
    end
  end

  @doc """
  Searches the lines of `path` for `pattern` and returns the text of the
  result (`docs/features/search-tools.md`). The arguments are the checked
  ones of `Helyx.Tool.Grep`.
  """
  @spec grep(map(), Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def grep(args, cwd) do
    with {:ok, regex} <- compile(args["pattern"], args["ignore_case"]),
         {:ok, kind, root} <- locate(args["path"], cwd) do
      deadline = now() + deadline_ms(:grep)

      case search(&grep_run(&1, kind, root, cwd, regex, args, deadline), empty_grep(), deadline) do
        {:done, {:error, text}} -> {:error, text}
        {:done, {state, stop}} -> {:ok, render_grep(state, stop)}
        {:timeout, state} -> {:ok, render_grep(state, :deadline)}
      end
    end
  end

  @doc """
  Finds the files under `path` whose path matches `glob` and returns the text
  of the result (`docs/features/search-tools.md`). The arguments are the
  checked ones of `Helyx.Tool.Find`.
  """
  @spec find(map(), Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def find(args, cwd) do
    with {:ok, root} <- folder(args["path"], cwd) do
      deadline = now() + deadline_ms(:find)
      keep = file_filter(args["glob"], cwd)
      run = fn report -> walk(root, deadline, max_entries(:find), report, keep) end

      case search(run, [], deadline) do
        {:done, {files, stop}} ->
          {:ok, render_find(files, stop, cwd, args["limit"])}

        {:timeout, files} ->
          {:ok, render_find(files, :deadline, cwd, args["limit"])}
      end
    end
  end

  # The pattern is a regular expression; a compile error is the text of the
  # result. `Regex` bounds one match in steps, not in time, so the walk
  # checks the deadline and the Task ends it (`docs/features/search-tools.md`,
  # decision 5).
  defp compile(pattern, ignore_case) do
    options = if ignore_case, do: "i", else: ""

    case Regex.compile(pattern, options) do
      {:ok, regex} ->
        {:ok, regex}

      {:error, {message, position}} ->
        {:error, "the pattern is not valid: #{to_string(message)} at position #{position}"}
    end
  end

  # `read`'s rule: the path is expanded against the session folder, and an
  # absolute path, or one that leaves the folder, is allowed. `File.stat/1`
  # follows a link that the model named, as `read` does.
  defp locate(nil, cwd), do: {:ok, :dir, cwd}

  defp locate(path, cwd) do
    full = Path.expand(path, cwd)

    case File.stat(full) do
      {:ok, %File.Stat{type: :regular}} ->
        {:ok, :file, full}

      {:ok, %File.Stat{type: :directory}} ->
        {:ok, :dir, full}

      {:ok, %File.Stat{type: type}} ->
        {:error, "cannot search #{path}: not a file or a folder (#{type})"}

      {:error, reason} ->
        {:error, "cannot search #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp folder(nil, cwd), do: {:ok, cwd}

  defp folder(path, cwd) do
    full = Path.expand(path, cwd)

    case File.stat(full) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, full}
      {:ok, %File.Stat{type: _type}} -> {:error, "cannot search #{path}: not a folder"}
      {:error, reason} -> {:error, "cannot search #{path}: #{:file.format_error(reason)}"}
    end
  end

  # The search in a Task of the tool call, so that a match that does not end
  # is killed at the deadline. The Task reports its state as it goes; past
  # the deadline the caller keeps the last report. The result is rendered in
  # the caller, so the Task does no work past the deadline; the caller does no
  # glob match, because the walk keeps only the files that match.
  defp search(fun, empty, deadline) do
    tag = make_ref()
    parent = self()
    task = Task.async(fn -> fun.(fn state -> send(parent, {tag, :progress, state}) end) end)

    case Task.yield(task, max(deadline - now(), 0)) do
      {:ok, result} ->
        _ = drain(tag, empty)
        {:done, result}

      nil ->
        case Task.shutdown(task, :brutal_kill) do
          {:ok, result} ->
            _ = drain(tag, empty)
            {:done, result}

          nil ->
            {:timeout, drain(tag, empty)}
        end
    end
  end

  # Messages of one sender have an order, so the last one is the newest state.
  defp drain(tag, state) do
    receive do
      {^tag, :progress, newer} -> drain(tag, newer)
    after
      0 -> state
    end
  end

  ## grep

  defp empty_grep do
    %{
      matches: 0,
      files: 0,
      skipped: 0,
      lines: [],
      bytes: 0,
      kept: 0,
      full: false,
      reported_at: nil
    }
  end

  defp grep_run(report, :dir, root, cwd, regex, args, deadline) do
    keep = file_filter(args["glob"], cwd)
    {files, stop} = walk(root, deadline, max_entries(:grep), fn _files -> :ok end, keep)
    grep_files(Enum.sort(files), cwd, regex, args, deadline, stop, report, empty_grep())
  end

  defp grep_run(_report, :file, root, cwd, regex, args, deadline) do
    case Helyx.Text.read_file(root, max_file_bytes()) do
      {:ok, content} ->
        scan(%{empty_grep() | files: 1}, rel(root, cwd), content, regex, args, deadline)

      {:error, reason} ->
        {:error, "cannot read #{args["path"]}: #{reason}"}
    end
  end

  defp grep_files([], _cwd, _regex, _args, _deadline, stop, _report, state),
    do: {state, stop}

  defp grep_files([full | rest], cwd, regex, args, deadline, stop, report, state) do
    if now() >= deadline do
      {state, :deadline}
    else
      {state, next} = grep_file(state, full, cwd, regex, args, deadline, report)

      case next do
        :deadline -> {state, :deadline}
        nil -> grep_files(rest, cwd, regex, args, deadline, stop, report, state)
      end
    end
  end

  defp grep_file(state, full, cwd, regex, args, deadline, report) do
    case Helyx.Text.read_file(full, max_file_bytes()) do
      {:ok, content} ->
        before = state.matches
        {state, stop} = scan(state, rel(full, cwd), content, regex, args, deadline)

        state = if state.matches > before, do: %{state | files: state.files + 1}, else: state

        {report_state(state, report), stop}

      {:error, _reason} ->
        {%{state | skipped: state.skipped + 1}, nil}
    end
  end

  defp report_state(state, report) do
    at = now()

    if state.reported_at == nil or at - state.reported_at >= @progress_ms do
      report.(state)
      %{state | reported_at: at}
    else
      state
    end
  end

  # The lines of `content`, cut at a character boundary. A match shows its
  # line, the lines of `context` before it that were not shown, and the
  # `context` lines after it. `keep/3` stops at `limit` matches or `budget/0`.
  defp scan(state, rel, content, regex, args, deadline) do
    lines = content |> String.replace_suffix("\n", "") |> String.split("\n")
    context = args["context"]
    limit = args["limit"]

    result =
      Enum.reduce_while(Enum.with_index(lines, 1), {state, 0, [], 0}, fn {text, no}, acc ->
        scan_line(acc, text, no, rel, regex, context, limit, deadline)
      end)

    case result do
      {state, _last, _ring, _pending, :deadline} -> {state, :deadline}
      {state, _last, _ring, _pending} -> {state, nil}
    end
  end

  defp scan_line({state, last, ring, pending}, text, no, rel, regex, context, limit, deadline) do
    cond do
      now() >= deadline ->
        {:halt, {state, last, ring, pending, :deadline}}

      Regex.match?(regex, text) ->
        line = cut(text)
        {state, last} = emit_ring(state, rel, ring, last, limit)
        state = %{state | matches: state.matches + 1}
        {state, last} = emit(state, rel, no, line, true, last, limit)
        {:cont, {state, last, ring_add(ring, no, line, context), context}}

      pending > 0 ->
        line = cut(text)
        {state, last} = emit(state, rel, no, line, false, last, limit)
        {:cont, {state, last, ring_add(ring, no, line, context), pending - 1}}

      true ->
        line = cut(text)
        {:cont, {state, last, ring_add(ring, no, line, context), 0}}
    end
  end

  defp emit_ring(state, rel, ring, last, limit) do
    Enum.reduce(ring, {state, last}, fn {no, line}, {state, last} ->
      emit(state, rel, no, line, false, last, limit)
    end)
  end

  defp emit(state, _rel, no, _line, _match?, last, _limit) when no <= last, do: {state, last}

  defp emit(state, rel, no, line, match?, _last, limit) do
    text = "#{rel}:#{no}:#{line}"
    {keep(state, {rel, no, text, match?}, limit), no}
  end

  defp keep(%{full: true} = state, _line, _limit), do: state
  defp keep(%{kept: kept} = state, _line, limit) when kept >= limit, do: state

  defp keep(state, line, _limit) do
    size = byte_size(elem(line, 2)) + 1

    if state.bytes + size > budget() do
      %{state | full: true}
    else
      %{
        state
        | lines: [line | state.lines],
          bytes: state.bytes + size,
          kept: state.kept + if(elem(line, 3), do: 1, else: 0)
      }
    end
  end

  defp ring_add(ring, _no, _line, 0), do: ring
  defp ring_add(ring, no, line, context), do: Enum.take(ring ++ [{no, line}], -context)

  defp cut(text) do
    cut = Helyx.Text.cap(text, max_line_bytes(), :head)
    if cut == text, do: cut, else: cut <> @cut_mark
  end

  defp render_grep(state, stop) do
    kept = Enum.sort_by(state.lines, fn {rel, no, _text, _match?} -> {rel, no} end)

    body =
      case kept do
        [] -> "no match"
        _ -> Enum.map_join(kept, "\n", fn {_rel, _no, text, _match?} -> text end)
      end

    join(body, [summary(state), stop_line(stop, :grep)])
  end

  defp summary(state) do
    not_shown = state.matches - state.kept

    parts = [
      "#{state.matches} #{plural(state.matches, "match", "matches")} in " <>
        "#{state.files} #{plural(state.files, "file", "files")}"
    ]

    parts = if not_shown > 0, do: parts ++ ["#{not_shown} more not shown"], else: parts

    parts =
      if state.skipped > 0,
        do: parts ++ ["#{state.skipped} #{plural(state.skipped, "file", "files")} skipped"],
        else: parts

    if not_shown > 0 or state.skipped > 0, do: Enum.join(parts, "; ")
  end

  ## find

  defp render_find(files, stop, cwd, limit) do
    paths =
      files
      |> Enum.map(&rel(&1, cwd))
      |> Enum.sort()

    total = length(paths)
    shown = take_paths(paths, limit)
    extra = total - length(shown)
    body = if shown == [], do: "no match", else: Enum.join(shown, "\n")

    count =
      if extra > 0,
        do: "#{length(shown)} of #{total} paths shown; #{extra} more not shown"

    join(body, [count, stop_line(stop, :find)])
  end

  defp take_paths(paths, limit) do
    {shown, _bytes, _count} =
      Enum.reduce_while(paths, {[], 0, 0}, fn path, {acc, bytes, count} ->
        size = byte_size(path) + 1

        if count >= limit or bytes + size > budget(),
          do: {:halt, {acc, bytes, count}},
          else: {:cont, {[path | acc], bytes + size, count + 1}}
      end)

    Enum.reverse(shown)
  end

  ## the walk

  @doc """
  Visits the files under `root` and returns `{files, stop}`: the full paths
  that `filter` accepts, in the order of the walk, and `nil`, `:entries` past
  the `max_entries` argument, or `:deadline` at `deadline`. `report` gets the
  list so far every #{@progress_entries} entries. A file that `filter` refuses
  still counts for `max_entries`. A link to a folder is not entered.
  """
  @spec walk(
          Path.t(),
          integer(),
          non_neg_integer(),
          ([Path.t()] -> any()),
          (Path.t() -> boolean()) | nil
        ) :: {[Path.t()], nil | :entries | :deadline}
  def walk(root, deadline, max_entries, report \\ fn _files -> :ok end, filter \\ nil) do
    {files, stop, _visited} = walk_dir(root, [], {deadline, max_entries, report, filter}, 0)
    {files, stop}
  end

  defp walk_dir(dir, files, ctx, visited) do
    case File.ls(dir) do
      {:ok, names} -> walk_entries(Enum.sort(names), dir, files, ctx, visited)
      {:error, _reason} -> {files, nil, visited}
    end
  end

  defp walk_entries([], _dir, files, _ctx, visited), do: {files, nil, visited}

  defp walk_entries([name | rest], dir, files, {deadline, max, _report, _filter} = ctx, visited) do
    cond do
      name in @skipped -> walk_entries(rest, dir, files, ctx, visited)
      visited >= max -> {files, :entries, visited}
      now() >= deadline -> {files, :deadline, visited}
      true -> walk_entry(rest, dir, name, files, ctx, visited)
    end
  end

  defp walk_entry(rest, dir, name, files, {_deadline, _max, report, filter} = ctx, visited) do
    full = Path.join(dir, name)
    next = visited + 1

    case type(full) do
      :dir ->
        {files, stop, visited} = walk_dir(full, files, ctx, next)

        if stop,
          do: {files, stop, visited},
          else: walk_entries(rest, dir, files, ctx, visited)

      :file ->
        files = if is_nil(filter) or filter.(full), do: [full | files], else: files
        files = if rem(next, @progress_entries) == 0, do: report_files(files, report), else: files
        walk_entries(rest, dir, files, ctx, next)

      :skip ->
        walk_entries(rest, dir, files, ctx, next)
    end
  end

  defp report_files(files, report) do
    report.(Enum.reverse(files))
    files
  end

  # A link to a regular file is read, as `read` follows it; any other link is
  # left out, so a link to a folder cannot make the walk loop.
  defp type(full) do
    case File.lstat(full) do
      {:ok, %File.Stat{type: :directory}} -> :dir
      {:ok, %File.Stat{type: :regular}} -> :file
      {:ok, %File.Stat{type: :symlink}} -> link(full)
      {:ok, %File.Stat{type: _type}} -> :skip
      {:error, _reason} -> :skip
    end
  end

  defp link(full) do
    case File.stat(full) do
      {:ok, %File.Stat{type: :regular}} -> :file
      _other -> :skip
    end
  end

  ## the glob

  @doc """
  Whether `path` matches `glob`: `*` any run without a `/`, `**` any run, `**/`
  zero or more whole folders, `?` one character that is not a `/`, and a
  literal. A glob with no `/` matches the file name, so it holds at any depth.
  """
  @spec glob?(String.t(), String.t()) :: boolean()
  defdelegate glob?(glob, path), to: Helyx.Search.Glob

  # The glob of a search, compiled once. A glob with no `/` matches the name
  # and one with a `/` matches the path from the folder, as `glob?/2` does.
  defp file_filter(nil, _cwd), do: nil

  defp file_filter(glob, cwd) do
    compiled = Glob.compile(glob)
    fn full -> Glob.match?(compiled, rel(full, cwd)) end
  end

  ## helpers

  defp join(body, notes) do
    Enum.join([body | Enum.reject(notes, &is_nil/1)], "\n")
  end

  defp stop_line(nil, _tool), do: nil

  defp stop_line(:entries, tool),
    do: "[search stopped early: the #{max_entries(tool)} entry limit]"

  defp stop_line(:deadline, tool),
    do: "[search stopped early: the #{deadline_ms(tool)} ms deadline]"

  defp plural(1, one, _many), do: one
  defp plural(_count, _one, many), do: many

  defp rel(full, cwd), do: full |> Path.relative_to(cwd) |> valid()

  defp valid(text), do: if(String.valid?(text), do: text, else: String.replace_invalid(text))

  defp now, do: System.monotonic_time(:millisecond)
end
