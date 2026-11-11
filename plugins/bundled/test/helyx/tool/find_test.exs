defmodule Helyx.Tool.FindTest do
  # Not async: the deadline and entry-bound seams are application env of
  # `helyx_plugins` (`docs/features/search-tools.md`, "Bounds").
  use ExUnit.Case, async: false

  alias Helyx.Message
  alias Helyx.Search
  alias Helyx.Tool.Find

  @moduletag :tmp_dir

  defp run(args, dir) do
    assert {:ok, text} = Find.run(args, dir)
    text
  end

  defp write(dir, name) do
    full = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "")
    full
  end

  test "a missing or wrongly typed argument is an error", %{tmp_dir: dir} do
    assert {:error, "glob is required"} = Find.run(%{}, dir)
    assert {:error, "glob must be a string"} = Find.run(%{"glob" => 1}, dir)
    assert {:error, "path must be a string"} = Find.run(%{"glob" => "*", "path" => 1}, dir)
    assert {:error, "limit must be an integer"} = Find.run(%{"glob" => "*", "limit" => 1.5}, dir)
  end

  test "an argument that the tool does not name is an error", %{tmp_dir: dir} do
    assert {:error, "bogus is not an argument"} = Find.run(%{"glob" => "*", "bogus" => 1}, dir)
  end

  test "the glob is bounded in bytes", %{tmp_dir: dir} do
    max = Search.max_glob_bytes()

    assert run(%{"glob" => String.duplicate("a", max)}, dir) == "no match"
    assert run(%{"glob" => String.duplicate("é", div(max, 2))}, dir) == "no match"

    assert {:error, text} = Find.run(%{"glob" => String.duplicate("a", max + 1)}, dir)
    assert text == "glob must be a string of at most #{max} bytes"

    assert {:error, _text} = Find.run(%{"glob" => String.duplicate("é", div(max, 2)) <> "a"}, dir)
  end

  test "the limit is bounded", %{tmp_dir: dir} do
    write(dir, "a.ex")

    assert {:error, text} = Find.run(%{"glob" => "*", "limit" => 0}, dir)
    assert text == "limit must be an integer from 1 to #{Search.max_find_limit()}"

    assert {:error, _text} =
             Find.run(%{"glob" => "*", "limit" => Search.max_find_limit() + 1}, dir)

    assert run(%{"glob" => "*", "limit" => 1}, dir) == "a.ex"
    assert run(%{"glob" => "*", "limit" => Search.max_find_limit()}, dir) == "a.ex"
  end

  test "the result holds files, not folders, sorted and relative", %{tmp_dir: dir} do
    write(dir, "b.ex")
    write(dir, "a/z.ex")
    File.mkdir_p!(Path.join(dir, "empty"))
    write(dir, "a.ex")

    assert run(%{"glob" => "*.ex"}, dir) == "a.ex\na/z.ex\nb.ex"
  end

  test "a glob with no / holds at any depth and a glob with a / is a path", %{tmp_dir: dir} do
    write(dir, "a.ex")
    write(dir, "src/b.ex")
    write(dir, "src/deep/c.ex")
    write(dir, "src/d_test.exs")

    assert run(%{"glob" => "*.ex"}, dir) == "a.ex\nsrc/b.ex\nsrc/deep/c.ex"
    assert run(%{"glob" => "src/*.ex"}, dir) == "src/b.ex"
    assert run(%{"glob" => "**/*_test.exs"}, dir) == "src/d_test.exs"
  end

  test "the fixed skip list is not walked", %{tmp_dir: dir} do
    for folder <- ~w(.git _build deps node_modules target .elixir_ls) do
      write(dir, folder <> "/x.ex")
    end

    write(dir, "a.ex")

    assert run(%{"glob" => "*.ex"}, dir) == "a.ex"
  end

  test "a link to a file is a file, a link to a folder is not entered, and a loop does not hang",
       %{
         tmp_dir: dir
       } do
    write(dir, "real/a.ex")
    write(dir, "b.ex")
    File.ln_s!(Path.join(dir, "real"), Path.join(dir, "link_dir"))
    File.ln_s!(Path.join(dir, "b.ex"), Path.join(dir, "link.ex"))
    File.ln_s!(dir, Path.join(dir, "real/up"))

    assert run(%{"glob" => "*.ex"}, dir) == "b.ex\nlink.ex\nreal/a.ex"
  end

  test "no match is a normal result", %{tmp_dir: dir} do
    write(dir, "a.txt")
    assert run(%{"glob" => "*.ex"}, dir) == "no match"
  end

  test "the limit cuts the paths and the last line counts them", %{tmp_dir: dir} do
    for name <- ~w(a.ex b.ex c.ex), do: write(dir, name)

    assert run(%{"glob" => "*.ex", "limit" => 2}, dir) ==
             "a.ex\nb.ex\n2 of 3 paths shown; 1 more not shown"
  end

  @tag :slow
  test "the default limit is the documented one", %{tmp_dir: dir} do
    count = Search.default_find_limit() + 1

    for n <- 1..count, do: write(dir, "f#{String.pad_leading("#{n}", 4, "0")}.ex")

    text = run(%{"glob" => "*.ex"}, dir)

    expected =
      Enum.map(1..Search.default_find_limit(), fn n ->
        "f#{String.pad_leading("#{n}", 4, "0")}.ex"
      end) ++ ["#{Search.default_find_limit()} of #{count} paths shown; 1 more not shown"]

    assert text == Enum.join(expected, "\n")
  end

  test "the result stays under the byte limit and counts the rest", %{tmp_dir: dir} do
    # A long path, so that about 100 of them pass `budget/0`.
    folder = Enum.map_join(1..4, "/", fn _part -> String.duplicate("d", 150) end)
    count = 120

    for n <- 1..count, do: write(dir, "#{folder}/f#{n}.ex")

    text = run(%{"glob" => "*.ex", "limit" => Search.max_find_limit()}, dir)

    assert byte_size(text) <= Message.max_result_bytes()
    assert text =~ "of #{count} paths shown;"
    assert text =~ "more not shown"
  end

  test "the entry bound stops the walk and the result says so", %{tmp_dir: dir} do
    Application.put_env(:helyx_plugins, :find_max_entries, 2)
    on_exit(fn -> Application.delete_env(:helyx_plugins, :find_max_entries) end)

    for name <- ~w(a.ex b.ex c.ex), do: write(dir, name)

    assert run(%{"glob" => "*.ex"}, dir) ==
             "a.ex\nb.ex\n[search stopped early: the 2 entry limit]"
  end

  test "the deadline ends a search", %{tmp_dir: dir} do
    Application.put_env(:helyx_plugins, :find_deadline_ms, 0)
    on_exit(fn -> Application.delete_env(:helyx_plugins, :find_deadline_ms) end)

    write(dir, "a.ex")

    assert run(%{"glob" => "*.ex"}, dir) == "no match\n[search stopped early: the 0 ms deadline]"
  end

  test "a path outside the session folder is allowed, as read allows it", %{tmp_dir: dir} do
    write(dir, "outside.ex")
    session = Path.join(dir, "session")
    File.mkdir_p!(session)

    outside = Path.join(dir, "outside.ex")
    assert run(%{"glob" => "*.ex", "path" => ".."}, session) == outside
    assert run(%{"glob" => "*.ex", "path" => outside |> Path.dirname()}, session) == outside
  end

  test "a path that is a file is an error, as is a missing one", %{tmp_dir: dir} do
    write(dir, "a.ex")

    assert {:error, text} = Find.run(%{"glob" => "*", "path" => "a.ex"}, dir)
    assert text == "cannot search a.ex: not a folder"

    assert {:error, text} = Find.run(%{"glob" => "*", "path" => "nope"}, dir)
    assert text == "cannot search nope: no such file or directory"
  end
end
