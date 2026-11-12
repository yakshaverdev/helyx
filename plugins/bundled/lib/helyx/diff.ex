defmodule Helyx.Diff do
  @moduledoc false
  # The `diff` UI block of `edit` and `write` (`docs/features/diff-blocks.md`).
  # A helper module (ADR 0005): no interface and no registration entry.

  alias Helyx.Text

  # The lines around a change that a hunk shows, on each side. Three lines
  # are enough to place a change in its function or block.
  @context_lines 3
  # One line of a block, in bytes. A shorter line keeps the block readable
  # and bounds what one long line adds twice, to `text` and to `hunks`.
  @line_bytes 1_000
  # The lines of one block, in bytes as `text` writes them, line ends
  # included and counted once although each line is in `text` and in `hunks`:
  # the block stays near 50 KB, under the 65,536-byte bound of
  # `Helyx.UIBlock.check/1` unless JSON escapes many characters.
  @budget_bytes 24_576
  # The most lines of one middle that the diff searches, on either side. The
  # search costs O((N+M)·D), so the common first and last lines are taken off
  # before it. A middle at this count, with every line different, measured
  # 0.8 s for a block on a 10-core machine with a load average near 18, and
  # 0.4 s in an earlier run at a lower load; a larger count multiplies that
  # time, and a tool call is abortable. A middle over this count is not shown.
  @max_diff_lines 2_000
  # The largest text that is split into lines, in bytes: the read bound of the
  # tools (`Helyx.Text.max_file_bytes/0`), so a file that a tool reads always
  # splits. A `write` whose provider does not bound the tool arguments can
  # bring a larger text; it is not split, and the block holds the line counts,
  # which cost one walk of the text.
  @max_text_bytes Text.max_file_bytes()
  # The path of the call as the model gave it, cut so that the two header
  # lines of the text stay bounded.
  @max_path_bytes 1_024
  @cut_marker " …"

  @doc "The context lines of a hunk on each side of a change."
  @spec context_lines() :: pos_integer()
  def context_lines, do: @context_lines

  @doc "The byte limit of one line of a block."
  @spec line_bytes() :: pos_integer()
  def line_bytes, do: @line_bytes

  @doc "The byte limit of the lines of one block, in `text` and in `hunks` together."
  @spec budget_bytes() :: pos_integer()
  def budget_bytes, do: @budget_bytes

  @doc "The largest middle of a diff, in lines, on either side of the common lines."
  @spec max_diff_lines() :: pos_integer()
  def max_diff_lines, do: @max_diff_lines

  @doc "The byte limit of the path of a block."
  @spec max_path_bytes() :: pos_integer()
  def max_path_bytes, do: @max_path_bytes

  @doc """
  The `diff` UI block of a change from `old_text` to `new_text`. Each hunk
  holds `context_lines/0` lines around a change, joined when the gap between
  two changes is short. The lines are cut at `line_bytes/0` and the block
  stops at `budget_bytes/0`; either cut sets `cut: true`. The common first
  and last lines of the texts are taken off before the search, so a large
  file with a small change costs a walk of its lines. A middle over
  `max_diff_lines/0` lines is not searched: the block holds no counts and a
  text that says so. A text over the split bound is not split.
  `from_line_hint` is the file line number of the first line of the texts, so
  that hunk starts are file line numbers.
  """
  @spec block(String.t(), String.t(), String.t(), pos_integer() | nil) :: map()
  def block(path, old_text, new_text, from_line_hint \\ nil) do
    path = Text.cap(path, @max_path_bytes, :head)
    first = from_line_hint || 1

    if byte_size(old_text) > @max_text_bytes or byte_size(new_text) > @max_text_bytes,
      do: long(path, line_count(new_text)),
      else: path |> changed(lines(old_text), lines(new_text), first) |> ends(old_text, new_text)
  end

  # `lines/1` drops the line ends, so a change of only a line end or of the
  # final newline gives no hunk. The text says so: the file did change.
  defp ends(%{"hunks" => [], "path" => path} = block, old_text, new_text)
       when old_text != new_text and not is_map_key(block, "cut"),
       do: %{block | "text" => "#{path}: only the line ends or the final newline changed"}

  defp ends(block, _old_text, _new_text), do: block

  @doc """
  The `diff` block of a write whose old file is not read: an empty hunks
  list, `cut: true`, and a text with the reason. The counts are absent,
  because the old text is unknown.
  """
  @spec unreadable(String.t(), String.t()) :: map()
  def unreadable(path, reason) do
    path = Text.cap(path, @max_path_bytes, :head)

    %{
      "kind" => "diff",
      "text" => "#{path}: written; the old file is not shown (#{reason})",
      "path" => path,
      "hunks" => [],
      "cut" => true
    }
  end

  # A diff over a bound is not shown, and the text says which count stopped
  # it. The counts of the changed lines are absent: no search found them.
  defp long(path, written) do
    %{
      "kind" => "diff",
      "text" =>
        "#{path}: #{written} lines written, the diff is not shown over #{@max_diff_lines} lines",
      "path" => path,
      "hunks" => [],
      "cut" => true
    }
  end

  defp changed(path, old, new, first) do
    {prefix, old_middle, new_middle, suffix} = split(old, new)

    if length(old_middle) > @max_diff_lines or length(new_middle) > @max_diff_lines do
      long(path, length(new))
    else
      rows = rows(build(prefix, difference(old_middle, new_middle), suffix), first, first, [])

      {hunks, cut?} = hunks(ranges(rows), rows)

      block = %{
        "kind" => "diff",
        "text" => text(path, hunks),
        "path" => path,
        "added" => Enum.count(rows, &match?({:ins, _, _, _}, &1)),
        "removed" => Enum.count(rows, &match?({:del, _, _, _}, &1)),
        "hunks" => hunks
      }

      if cut?, do: Map.put(block, "cut", true), else: block
    end
  end

  # The common first and last lines of the two texts. The search runs on the
  # middle alone, so a large file with a small change costs a walk of its
  # lines, not a search over all of them. The suffix is taken from what the
  # prefix left, so the two never overlap.
  defp split(old, new) do
    {prefix, old, new} = prefix(old, new, [])
    {suffix, old, new} = suffix(Enum.reverse(old), Enum.reverse(new), [])
    {prefix, Enum.reverse(old), Enum.reverse(new), Enum.reverse(suffix)}
  end

  defp prefix([line | old], [line | new], acc), do: prefix(old, new, [line | acc])
  defp prefix(old, new, acc), do: {Enum.reverse(acc), old, new}

  defp suffix([line | old], [line | new], acc), do: suffix(old, new, [line | acc])
  defp suffix(old, new, acc), do: {Enum.reverse(acc), old, new}

  defp build(prefix, middle, suffix), do: context(prefix) ++ middle ++ context(suffix)

  defp context([]), do: []
  defp context(lines), do: [eq: lines]

  # One side empty has the answer without a search: the myers search costs
  # O((N+M)²) even then, and those cases are a new file and an emptied one.
  defp difference([], []), do: []
  defp difference([], new), do: [ins: new]
  defp difference(old, []), do: [del: old]
  defp difference(old, new), do: List.myers_difference(old, new)

  # One row for each line of the two texts, in order, with the old and the
  # new line number before the row.
  defp rows([], _old, _new, acc), do: Enum.reverse(acc)

  defp rows([{:eq, lines} | rest], old, new, acc),
    do: rows(rest, old + length(lines), new + length(lines), equal(lines, old, new, acc))

  defp rows([{:del, lines} | rest], old, new, acc),
    do: rows(rest, old + length(lines), new, deleted(lines, old, new, acc))

  defp rows([{:ins, lines} | rest], old, new, acc),
    do: rows(rest, old, new + length(lines), inserted(lines, old, new, acc))

  defp equal([], _old, _new, acc), do: acc

  defp equal([line | rest], old, new, acc),
    do: equal(rest, old + 1, new + 1, [{:eq, old, new, line} | acc])

  defp deleted([], _old, _new, acc), do: acc

  defp deleted([line | rest], old, new, acc),
    do: deleted(rest, old + 1, new, [{:del, old, new, line} | acc])

  defp inserted([], _old, _new, acc), do: acc

  defp inserted([line | rest], old, new, acc),
    do: inserted(rest, old, new + 1, [{:ins, old, new, line} | acc])

  # The row ranges of the hunks: a change and its context, and two changes
  # in one hunk when the equal lines between them are at most twice the
  # context.
  defp ranges(rows) do
    count = length(rows)

    {ranges, start, last, _gap} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], nil, 0, 0}, &range/2)

    ranges =
      if start == nil, do: ranges, else: [{start, min(last + @context_lines, count - 1)} | ranges]

    Enum.reverse(ranges)
  end

  defp range({row, at}, {ranges, start, last, gap}) when elem(row, 0) != :eq do
    cond do
      start == nil -> {ranges, max(0, at - @context_lines), at, 0}
      gap <= 2 * @context_lines -> {ranges, start, at, 0}
      true -> {[{start, last + @context_lines} | ranges], at - @context_lines, at, 0}
    end
  end

  defp range({_row, _at}, {ranges, nil, last, gap}), do: {ranges, nil, last, gap}
  defp range({_row, _at}, {ranges, start, last, gap}), do: {ranges, start, last, gap + 1}

  # The hunks of the ranges, in order, until the byte budget is spent. A
  # hunk that the budget stops is kept with the lines that fit, and every
  # line after it is left out.
  defp hunks(ranges, rows) do
    rows = List.to_tuple(rows)
    last = tuple_size(rows) - 1

    {hunks, _room, cut?} =
      Enum.reduce_while(ranges, {[], @budget_bytes, false}, fn {from, to}, {hunks, room, cut?} ->
        slice = for at <- from..min(to, last), do: elem(rows, at)

        case hunk(slice, room) do
          {:ok, hunk, used, line_cut?} ->
            {:cont, {[hunk | hunks], room - used, cut? or line_cut?}}

          {:full, nil, _used, _line_cut?} ->
            {:halt, {hunks, room, true}}

          {:full, hunk, _used, _line_cut?} ->
            {:halt, {[hunk | hunks], room, true}}
        end
      end)

    {Enum.reverse(hunks), cut?}
  end

  defp hunk(rows, room), do: collect(rows, room, empty(), 0, false)

  defp collect([], _room, hunk, used, cut?), do: {:ok, to_block(hunk), used, cut?}

  defp collect([row | rest], room, hunk, used, cut?) do
    {text, line_cut?} = render(row)
    size = byte_size(text) + 1

    if size > room,
      do: {:full, to_block(hunk), used, cut? or line_cut?},
      else: collect(rest, room - size, put(hunk, row, text), used + size, cut? or line_cut?)
  end

  defp empty do
    %{first_old: nil, first_new: nil, old?: false, new?: false, old: 0, new: 0, lines: []}
  end

  defp put(hunk, {tag, old, new, _line}, text) do
    %{
      hunk
      | first_old: hunk.first_old || old,
        first_new: hunk.first_new || new,
        old?: hunk.old? or tag != :ins,
        new?: hunk.new? or tag != :del,
        old: hunk.old + if(tag == :ins, do: 0, else: 1),
        new: hunk.new + if(tag == :del, do: 0, else: 1),
        lines: [text | hunk.lines]
    }
  end

  # A hunk of no line is nil: the budget ran out before its first line.
  defp to_block(%{lines: []}), do: nil

  defp to_block(hunk) do
    %{
      "old_start" => hunk.first_old - if(hunk.old?, do: 0, else: 1),
      "old_lines" => hunk.old,
      "new_start" => hunk.first_new - if(hunk.new?, do: 0, else: 1),
      "new_lines" => hunk.new,
      "lines" => Enum.reverse(hunk.lines)
    }
  end

  # A line is its sign and its content, without the line end. A content
  # over the line bound is cut at a character boundary and marked.
  defp render({tag, _old, _new, line}) do
    {sign(tag) <> display(line), byte_size(line) > @line_bytes}
  end

  defp sign(:eq), do: " "
  defp sign(:del), do: "-"
  defp sign(:ins), do: "+"

  defp display(line) do
    if byte_size(line) > @line_bytes,
      do: Text.cap(line, @line_bytes, :head) <> @cut_marker,
      else: line
  end

  defp text(path, hunks) do
    IO.iodata_to_binary([
      "--- a/",
      path,
      "\n+++ b/",
      path,
      "\n",
      Enum.map(hunks, &hunk_text/1)
    ])
  end

  defp hunk_text(hunk) do
    [
      "@@ -",
      "#{hunk["old_start"]},#{hunk["old_lines"]}",
      " +",
      "#{hunk["new_start"]},#{hunk["new_lines"]}",
      " @@\n",
      Enum.map(hunk["lines"], &[&1, "\n"])
    ]
  end

  # The lines of a text, without the line ends. A trailing newline ends the
  # last line and starts no blank one.
  defp lines(""), do: []

  defp lines(text) do
    parts = String.split(text, "\n")
    parts = if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
    Enum.map(parts, &String.replace_suffix(&1, "\r", ""))
  end

  defp line_count(text), do: line_count(text, 0)

  defp line_count("", count), do: count

  defp line_count(text, count) do
    case :binary.match(text, "\n") do
      :nomatch -> count + 1
      {at, 1} -> line_count(binary_part(text, at + 1, byte_size(text) - at - 1), count + 1)
    end
  end
end
