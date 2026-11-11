defmodule Helyx.SearchTest do
  # The glob and the walk of `Helyx.Search` (`docs/features/search-tools.md`).
  use ExUnit.Case, async: true

  alias Helyx.Search

  @moduletag :tmp_dir

  defp deadline, do: System.monotonic_time(:millisecond) + 60_000

  defp write(dir, name) do
    full = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "")
    full
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

  # A loop that stays in the tree after the test makes the file walk of Credo
  # hang, so the link goes at the exit.
  defp loop!(dir, name) do
    link = Path.join(dir, name)
    File.ln_s!(dir, link)
    on_exit(fn -> File.rm(link) end)
  end
end
