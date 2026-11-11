defmodule Helyx.Tool.GrepTest do
  # Not async: the deadline and entry-bound seams are application env of
  # `helyx_plugins` (`docs/features/search-tools.md`, "Bounds").
  use ExUnit.Case, async: false

  alias Helyx.Message
  alias Helyx.Search
  alias Helyx.Tool.Grep

  @moduletag :tmp_dir

  defp run(args, dir) do
    assert {:ok, text} = Grep.run(args, dir)
    text
  end

  defp write(dir, name, content) do
    full = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    full
  end

  test "a missing or wrongly typed argument is an error", %{tmp_dir: dir} do
    assert {:error, "pattern is required"} = Grep.run(%{}, dir)
    assert {:error, "pattern must be a string"} = Grep.run(%{"pattern" => 1}, dir)
    assert {:error, "path must be a string"} = Grep.run(%{"pattern" => "a", "path" => 1}, dir)
    assert {:error, "glob must be a string"} = Grep.run(%{"pattern" => "a", "glob" => 1}, dir)

    assert {:error, "ignore_case must be true or false"} =
             Grep.run(%{"pattern" => "a", "ignore_case" => "yes"}, dir)

    assert {:error, "context must be an integer"} =
             Grep.run(%{"pattern" => "a", "context" => "1"}, dir)

    assert {:error, "limit must be an integer"} =
             Grep.run(%{"pattern" => "a", "limit" => 1.5}, dir)
  end

  test "an argument that the tool does not name is an error", %{tmp_dir: dir} do
    assert {:error, "bogus is not an argument"} =
             Grep.run(%{"pattern" => "a", "bogus" => 1}, dir)
  end

  test "the pattern is bounded in bytes, a multibyte character counted by its bytes", %{
    tmp_dir: dir
  } do
    max = Search.max_pattern_bytes()

    assert run(%{"pattern" => String.duplicate("a", max)}, dir) == "no match"

    assert {:error, text} = Grep.run(%{"pattern" => String.duplicate("a", max + 1)}, dir)
    assert text == "pattern must be a string of at most #{max} bytes"

    assert run(%{"pattern" => String.duplicate("é", div(max, 2))}, dir) == "no match"

    assert {:error, _text} =
             Grep.run(%{"pattern" => String.duplicate("é", div(max, 2)) <> "a"}, dir)
  end

  test "the glob is bounded in bytes", %{tmp_dir: dir} do
    max = Search.max_glob_bytes()

    assert run(%{"pattern" => "a", "glob" => String.duplicate("a", max)}, dir) == "no match"

    assert {:error, text} =
             Grep.run(%{"pattern" => "a", "glob" => String.duplicate("a", max + 1)}, dir)

    assert text == "glob must be a string of at most #{max} bytes"
  end

  test "context and limit are bounded", %{tmp_dir: dir} do
    write(dir, "a.txt", "x\n")
    context = Search.max_context_lines()

    assert run(%{"pattern" => "x", "context" => 0}, dir) == "a.txt:1:x"
    assert run(%{"pattern" => "x", "context" => context}, dir) == "a.txt:1:x"

    assert {:error, text} = Grep.run(%{"pattern" => "x", "context" => context + 1}, dir)
    assert text == "context must be an integer from 0 to #{context}"
    assert {:error, _text} = Grep.run(%{"pattern" => "x", "context" => -1}, dir)

    assert {:error, text} = Grep.run(%{"pattern" => "x", "limit" => 0}, dir)
    assert text == "limit must be an integer from 1 to #{Search.max_grep_limit()}"

    assert {:error, _text} =
             Grep.run(%{"pattern" => "x", "limit" => Search.max_grep_limit() + 1}, dir)

    assert run(%{"pattern" => "x", "limit" => Search.max_grep_limit()}, dir) == "a.txt:1:x"
  end

  test "matches are grouped by file in sorted path order with their line numbers", %{
    tmp_dir: dir
  } do
    write(dir, "b.txt", "one hit\nno\nhit two\n")
    write(dir, "a.txt", "hit\n")
    write(dir, "z/c.txt", "hit\n")

    assert run(%{"pattern" => "hit"}, dir) ==
             "a.txt:1:hit\nb.txt:1:one hit\nb.txt:3:hit two\nz/c.txt:1:hit"
  end

  test "ignore_case folds case", %{tmp_dir: dir} do
    write(dir, "a.txt", "HIT\nhit\n")

    assert run(%{"pattern" => "hit"}, dir) == "a.txt:2:hit"
    assert run(%{"pattern" => "hit", "ignore_case" => true}, dir) == "a.txt:1:HIT\na.txt:2:hit"
  end

  test "context shows the lines around a match, once", %{tmp_dir: dir} do
    write(dir, "a.txt", "one\ntwo\nHIT\nfour\nfive\n")

    assert run(%{"pattern" => "HIT", "context" => 1}, dir) ==
             "a.txt:2:two\na.txt:3:HIT\na.txt:4:four"

    assert run(%{"pattern" => "HIT", "context" => 2}, dir) ==
             "a.txt:1:one\na.txt:2:two\na.txt:3:HIT\na.txt:4:four\na.txt:5:five"
  end

  test "two matches share the lines of context between them", %{tmp_dir: dir} do
    write(dir, "a.txt", "HIT\nx\nHIT\n")

    assert run(%{"pattern" => "HIT", "context" => 1}, dir) ==
             "a.txt:1:HIT\na.txt:2:x\na.txt:3:HIT"
  end

  test "a long line is cut at a character boundary and marked", %{tmp_dir: dir} do
    write(dir, "a.txt", String.duplicate("é", 400) <> " needle")

    ["a.txt:1:" <> shown] = run(%{"pattern" => "needle"}, dir) |> String.split("\n")

    assert String.valid?(shown)
    assert String.ends_with?(shown, "…")
    assert byte_size(shown) <= Search.max_line_bytes() + byte_size("…")
    assert shown == String.duplicate("é", div(Search.max_line_bytes(), 2)) <> "…"
  end

  test "the limit cuts the matches and the last line counts them", %{tmp_dir: dir} do
    for name <- ~w(a.txt b.txt c.txt), do: write(dir, name, "hit\n")

    assert run(%{"pattern" => "hit", "limit" => 2}, dir) ==
             "a.txt:1:hit\nb.txt:1:hit\n3 matches in 3 files; 1 more not shown"
  end

  test "the default limit is the documented one", %{tmp_dir: dir} do
    count = Search.default_grep_limit() + 1
    write(dir, "a.txt", String.duplicate("hit\n", count))
    text = run(%{"pattern" => "hit"}, dir)
    lines = String.split(text, "\n")

    assert length(lines) == Search.default_grep_limit() + 1
    assert Enum.all?(Enum.drop(lines, -1), &String.starts_with?(&1, "a.txt:"))

    assert List.last(lines) == "#{count} matches in 1 file; 1 more not shown"
  end

  test "no match is a normal result", %{tmp_dir: dir} do
    write(dir, "a.txt", "one\n")
    assert run(%{"pattern" => "zzz"}, dir) == "no match"
  end

  test "a binary file and an oversized file are skipped and counted", %{tmp_dir: dir} do
    write(dir, "bin.dat", <<255, 254, ?h, ?i, ?t>>)
    write(dir, "big.txt", String.duplicate("hit ", div(Search.max_file_bytes(), 4) + 1))
    write(dir, "a.txt", "hit\n")

    assert run(%{"pattern" => "hit"}, dir) == "a.txt:1:hit\n1 match in 1 file; 2 files skipped"
  end

  test "the fixed skip list is not walked, and a dot file is", %{tmp_dir: dir} do
    for folder <- ~w(.git _build deps node_modules target .elixir_ls) do
      write(dir, folder <> "/x.txt", "hit\n")
    end

    write(dir, ".hidden", "hit\n")

    assert run(%{"pattern" => "hit"}, dir) == ".hidden:1:hit"
  end

  test "the result stays under the byte limit and counts the rest", %{tmp_dir: dir} do
    line = String.duplicate("x", Search.max_line_bytes()) <> " hit"
    count = div(Message.max_result_bytes(), Search.max_line_bytes()) + 20
    write(dir, "a.txt", Enum.map_join(1..count, "\n", fn _line -> line end))

    text = run(%{"pattern" => "hit", "limit" => Search.max_grep_limit()}, dir)

    assert byte_size(text) <= Message.max_result_bytes()
    assert text =~ "#{count} matches in 1 file;"
    assert text =~ "more not shown"
  end

  test "the entry bound stops the walk and the result says so", %{tmp_dir: dir} do
    Application.put_env(:helyx_plugins, :grep_max_entries, 2)
    on_exit(fn -> Application.delete_env(:helyx_plugins, :grep_max_entries) end)

    for name <- ~w(a.txt b.txt c.txt), do: write(dir, name, "hit\n")

    assert run(%{"pattern" => "hit"}, dir) ==
             "a.txt:1:hit\nb.txt:1:hit\n[search stopped early: the 2 entry limit]"
  end

  # The wait is the injected deadline of a pattern that backtracks on each
  # long line: one match runs to the step limit of `Regex`, not to an end.
  @tag :slow
  test "the deadline ends a search that does not stop, and keeps the files it reported", %{
    tmp_dir: dir
  } do
    deadline = 2_000
    Application.put_env(:helyx_plugins, :grep_deadline_ms, deadline)
    on_exit(fn -> Application.delete_env(:helyx_plugins, :grep_deadline_ms) end)

    write(dir, "a.txt", "needle\n")
    long = String.duplicate("a", 150_000) <> "b"
    write(dir, "b.txt", Enum.map_join(1..13, "\n", fn _line -> long end))

    text = run(%{"pattern" => "(a+)+$|needle"}, dir)

    assert text =~ "a.txt:1:needle"
    assert text =~ "[search stopped early: the #{deadline} ms deadline]"
  end

  test "a named file is searched whatever the glob says", %{tmp_dir: dir} do
    write(dir, "a.txt", "hit\n")

    assert run(%{"pattern" => "hit", "path" => "a.txt", "glob" => "*.ex"}, dir) == "a.txt:1:hit"

    assert {:error, text} = Grep.run(%{"pattern" => "hit", "path" => "nope.txt"}, dir)
    assert text == "cannot search nope.txt: no such file or directory"
  end

  test "a path outside the session folder is allowed, as read allows it", %{tmp_dir: dir} do
    write(dir, "outside.txt", "hit\n")
    session = Path.join(dir, "session")
    File.mkdir_p!(session)

    outside = Path.join(dir, "outside.txt")
    assert run(%{"pattern" => "hit", "path" => "../outside.txt"}, session) == "#{outside}:1:hit"
    assert run(%{"pattern" => "hit", "path" => outside}, session) == "#{outside}:1:hit"
  end

  test "a link to a file is searched and a link to a folder is not entered", %{tmp_dir: dir} do
    write(dir, "outside/hit.txt", "hit\n")
    session = Path.join(dir, "session")
    File.mkdir_p!(session)
    File.ln_s!(Path.join(dir, "outside/hit.txt"), Path.join(session, "link.txt"))
    File.ln_s!(Path.join(dir, "outside"), Path.join(session, "link_dir"))

    assert run(%{"pattern" => "hit"}, session) == "link.txt:1:hit"
  end

  test "a link loop does not hang", %{tmp_dir: dir} do
    write(dir, "sub/a.txt", "hit\n")
    File.ln_s!(dir, Path.join(dir, "sub/up"))

    assert run(%{"pattern" => "hit"}, dir) == "sub/a.txt:1:hit"
  end

  test "a device named as the path is an error result, as read gives one", %{tmp_dir: dir} do
    assert {:error, text} = Grep.run(%{"pattern" => "hit", "path" => "/dev/null"}, dir)
    assert text == "cannot search /dev/null: not a file or a folder (device)"
  end
end
