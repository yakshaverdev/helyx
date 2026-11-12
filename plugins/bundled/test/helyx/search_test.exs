defmodule Helyx.SearchTest do
  # The glob and the walk of `Helyx.Search` (`docs/features/search-tools.md`).
  # Not async: the entry-bound and deadline seams of `find` are application
  # env of `helyx_plugins`.
  use ExUnit.Case, async: false

  alias Helyx.Search

  @moduletag :tmp_dir

  # One match steps the live set of a glob at most once for each token and
  # each unit of the path. A step does a few set operations, so this factor
  # leaves room for the set of live positions and for garbage collection.
  @glob_match_factor 128

  # Every 1,024 entries, a walk reports the files that it holds so far.
  @walk_report_entries 1_024

  # At least 40 glob and path pairs, with the expected result written from the
  # semantics: `*` any run without a `/`, `**` any run, `**/` zero or more
  # whole folders, `?` one character that is not a `/`, and a literal. A glob
  # with no `/` matches the file name, so `*` holds at any depth.
  @glob_cases [
    # a literal
    {"abc", "abc", true},
    {"abc", "abd", false},
    {"abc", "ab", false},
    {"abc", "abcd", false},
    {"src/a.ex", "src/a.ex", true},
    {"src/a.ex", "a.ex", false},
    {"{a,b}.ex", "a.ex", false},
    {"[ab].ex", "a.ex", false},
    {"[ab].ex", "[ab].ex", true},
    {"a", "", false},
    # `*`
    {"*", "a.ex", true},
    {"*", "", true},
    {"*", "a/b", true},
    {"*.ex", "src/deep/a.ex", true},
    {"*.ex", "src/deep/a.exs", false},
    {"a*", "abc", true},
    {"a*", "bac", false},
    {"*a", "ba", true},
    {"*a", "ab", false},
    {"*a*", "xay", true},
    {"a*b", "ab", true},
    {"a*b", "axxb", true},
    {"a*b", "axx", false},
    {"src/*", "src/a/b", false},
    # `**` and `**/`
    {"**", "a/b", true},
    {"**", "", true},
    {"a/**", "a/b", true},
    {"a/**", "a", false},
    {"a/**", "a/", true},
    {"a/**/b", "a/b", true},
    {"a/**/b", "a/x/b", true},
    {"a/**/b", "a/x/y/b", true},
    {"a/**/b", "a/xb", false},
    {"**/a", "a", true},
    {"**/a", "x/a", true},
    {"**/a", "x/y/a", true},
    {"**/a", "xa", false},
    {"**/*.ex", "a.ex", true},
    {"**/*.ex", "x/y/a.ex", true},
    {"**/*.ex", "x/y/a.exs", false},
    {"**/**/a", "a", true},
    {"**/**/a", "x/y/a", true},
    {"a/**/**/b", "a/b", true},
    {"a/**/**/b", "a/x/y/b", true},
    {"**/", "", true},
    {"**/", "a/", true},
    {"x/**/", "x/", true},
    {"x/**/", "x", false},
    # `?`
    {"?", "a", true},
    {"?", "", false},
    {"?", "ab", false},
    {"?", "/", false},
    {"a?c", "abc", true},
    {"a?c", "ac", false},
    {"a?c", "a/c", false},
    {"?", "é", true},
    {"a?c", "aéc", true},
    # tokens in pairs
    {"*?", "a", true},
    {"?*", "a", true},
    {"**?", "a/b", true},
    {"?*", "", false},
    {"a/**/b*", "a/x/bc", true},
    {"src/*/*.ex", "src/a/b.ex", true},
    {"src/*/*.ex", "src/b.ex", false},
    # a byte that is not UTF-8 is one unit
    {"a?", "a" <> <<0xE9>>, true},
    {<<0xE9>>, <<0xE9>>, true},
    {<<0xE9>>, "é", false},
    {"?", <<0xE9>>, true},
    {"*", <<0xE9, 0xE9>>, true},
    # an empty path
    {"**/a", "", false}
  ]

  defp deadline, do: System.monotonic_time(:millisecond) + 60_000

  defp reductions, do: elem(:erlang.process_info(self(), :reductions), 1)

  defp write(dir, name) do
    full = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "")
    full
  end

  test "a glob with many * matches a long name in linear work" do
    glob = String.duplicate("*a", 20) <> "b"
    name = String.duplicate("a", 200)

    before = reductions()
    refute Search.glob?(glob, name)
    used = reductions() - before

    assert used < byte_size(glob) * String.length(name) * @glob_match_factor
  end

  test "a glob and a path give the result of the semantics" do
    for {glob, path, expected} <- @glob_cases do
      assert Search.glob?(glob, path) == expected,
             "glob #{inspect(glob)} on #{inspect(path)}: expected #{expected}"
    end
  end

  test "a glob without a / matches the file name at any depth" do
    assert Search.glob?("*.ex", "a.ex")
    assert Search.glob?("*.ex", "src/deep/a.ex")
    refute Search.glob?("*.ex", "a.exs")
    refute Search.glob?("*.ex", "src/a.exs")
    assert Search.glob?("a?c.ex", "abc.ex")
    refute Search.glob?("a?c.ex", "ac.ex")
    assert Search.glob?("a?.ex", "aé.ex")
    refute Search.glob?("a?.ex", "a/é.ex")
  end

  test "**/ holds zero or more whole folders" do
    assert Search.glob?("**/*_test.exs", "a_test.exs")
    assert Search.glob?("**/*_test.exs", "test/a_test.exs")
    assert Search.glob?("**/*_test.exs", "test/deep/a_test.exs")
    refute Search.glob?("**/*_test.exs", "test/a.exs")
    refute Search.glob?("**/*_test.exs", "test/deep/a.exs")
  end

  test "a glob with a / matches the path from the folder" do
    assert Search.glob?("src/*.ex", "src/a.ex")
    refute Search.glob?("src/*.ex", "a.ex")
    refute Search.glob?("src/*.ex", "src/sub/a.ex")
    assert Search.glob?("src/**", "src/sub/a.ex")
    assert Search.glob?("**", "anything/at/all.ex")
  end

  test "a brace and a class are a literal" do
    refute Search.glob?("{a,b}.ex", "a.ex")
    refute Search.glob?("[ab].ex", "a.ex")
    assert Search.glob?("{a,b}.ex", "{a,b}.ex")
    assert Search.glob?("[ab].ex", "[ab].ex")
  end

  test "an empty glob matches nothing" do
    refute Search.glob?("", "a.ex")
  end

  test "the walk returns every file", %{tmp_dir: dir} do
    write(dir, "b.ex")
    write(dir, "a.ex")
    write(dir, "sub/c.ex")

    assert {files, nil} = Search.walk(dir, deadline(), 10)

    assert Enum.map(files, &Path.relative_to(&1, dir)) |> Enum.sort() == [
             "a.ex",
             "b.ex",
             "sub/c.ex"
           ]
  end

  test "the walk stops at the entry bound and keeps what it found", %{tmp_dir: dir} do
    for name <- ~w(a.ex b.ex c.ex d.ex e.ex), do: write(dir, name)

    # Five entries: all fit under a bound of five, and the fifth passes four.
    assert {files, nil} = Search.walk(dir, deadline(), 5)
    assert length(files) == 5

    assert {files, :entries} = Search.walk(dir, deadline(), 4)
    assert Enum.map(files, &Path.basename/1) |> Enum.sort() == ~w(a.ex b.ex c.ex d.ex)

    assert {[], :entries} = Search.walk(dir, deadline(), 0)
  end

  test "the walk stops at its deadline with nothing found", %{tmp_dir: dir} do
    write(dir, "a.ex")
    assert {[], :deadline} = Search.walk(dir, System.monotonic_time(:millisecond) - 1, 10)
  end

  test "a skipped folder costs no entry and is not entered", %{tmp_dir: dir} do
    write(dir, "target/x/a.ex")
    write(dir, "a.ex")

    # `target` sorts after `a.ex` and the bound is reached at `a.ex`.
    assert {[full], nil} = Search.walk(dir, deadline(), 1)
    assert Path.basename(full) == "a.ex"
  end

  test "a link to a folder is not entered and a link to a file is a file", %{tmp_dir: dir} do
    write(dir, "real/a.ex")
    write(dir, "b.ex")
    File.ln_s!(Path.join(dir, "real"), Path.join(dir, "link_dir"))
    File.ln_s!(Path.join(dir, "b.ex"), Path.join(dir, "link_file.ex"))

    {files, nil} = Search.walk(dir, deadline(), 100)

    assert Enum.map(files, &Path.relative_to(&1, dir)) |> Enum.sort() ==
             ["b.ex", "link_file.ex", "real/a.ex"]
  end

  test "a link loop does not make the walk hang", %{tmp_dir: dir} do
    write(dir, "sub/a.ex")
    loop!(dir, "sub/up")

    assert {[full], nil} = Search.walk(dir, deadline(), 100)
    assert Path.relative_to(full, dir) == "sub/a.ex"
  end

  test "the walk keeps only the files that the filter accepts and counts the rest", %{
    tmp_dir: dir
  } do
    for n <- 1..@walk_report_entries do
      ext = if rem(n, 2) == 0, do: ".ex", else: ".txt"
      File.write!(Path.join(dir, "f" <> String.pad_leading("#{n}", 4, "0") <> ext), "")
    end

    report = fn files -> send(self(), {:walk_report, files}) end
    keep = fn full -> Path.extname(full) == ".ex" end

    assert {files, nil} = Search.walk(dir, deadline(), 10_000, report, keep)

    assert length(files) == div(@walk_report_entries, 2)
    assert Enum.all?(files, &(Path.extname(&1) == ".ex"))

    assert_received {:walk_report, reported}

    assert length(reported) == div(@walk_report_entries, 2)
    assert Enum.all?(reported, &(Path.extname(&1) == ".ex"))
  end

  test "find holds only the files that match, and a refused file still counts", %{tmp_dir: dir} do
    Application.put_env(:helyx_plugins, :find_max_entries, 2)
    on_exit(fn -> Application.delete_env(:helyx_plugins, :find_max_entries) end)

    write(dir, "a.ex")
    write(dir, "b.txt")
    write(dir, "c.ex")

    assert {:ok, text} = Search.find(%{"glob" => "*.ex", "limit" => 10}, dir)
    assert text == "a.ex\n[search stopped early: the 2 entry limit]"
  end

  test "find ends at its deadline even when the glob is slow", %{tmp_dir: dir} do
    Application.put_env(:helyx_plugins, :find_deadline_ms, 1)
    on_exit(fn -> Application.delete_env(:helyx_plugins, :find_deadline_ms) end)

    name = String.duplicate("a", 190)

    for n <- 1..300 do
      File.write!(Path.join(dir, String.pad_leading("#{n}", 4, "0") <> name), "")
    end

    glob = String.duplicate("*a", 20) <> "b"

    assert {:ok, text} = Search.find(%{"glob" => glob, "limit" => 10}, dir)
    assert text == "no match\n[search stopped early: the 1 ms deadline]"
  end

  # A loop that stays in the tree after the test makes the file walk of Credo
  # hang, so the link goes at the exit.
  defp loop!(dir, name) do
    link = Path.join(dir, name)
    File.ln_s!(dir, link)
    on_exit(fn -> File.rm(link) end)
  end
end
