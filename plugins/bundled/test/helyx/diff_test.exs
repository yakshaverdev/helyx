defmodule Helyx.DiffTest do
  use ExUnit.Case, async: true

  alias Helyx.Diff

  @lines Enum.map_join(1..20, "\n", &"l#{&1}") <> "\n"

  defp block(old_text, new_text), do: Diff.block("a.txt", old_text, new_text)

  defp replaced(text, line, value),
    do: String.replace(text, "l#{line}\n", value <> "\n", global: false)

  # The text with its first and its last line changed, so the common prefix
  # and the common suffix are empty and a middle keeps every line.
  defp changed_ends(count) do
    Enum.map_join(1..count, "\n", fn
      1 -> "first"
      n when n == count -> "last"
      n -> "l#{n}"
    end) <> "\n"
  end

  test "a one-line change in the middle gives the file lines around it" do
    block = block(@lines, replaced(@lines, 10, "changed"))

    assert block["kind"] == "diff"
    assert block["path"] == "a.txt"
    assert block["added"] == 1
    assert block["removed"] == 1
    refute Map.has_key?(block, "cut")

    assert [hunk] = block["hunks"]

    assert hunk == %{
             "old_start" => 10 - Diff.context_lines(),
             "old_lines" => 2 * Diff.context_lines() + 1,
             "new_start" => 10 - Diff.context_lines(),
             "new_lines" => 2 * Diff.context_lines() + 1,
             "lines" => [" l7", " l8", " l9", "-l10", "+changed", " l11", " l12", " l13"]
           }

    assert block["text"] ==
             "--- a/a.txt\n+++ b/a.txt\n@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-l10\n+changed\n l11\n l12\n l13\n"
  end

  test "a change at the first line keeps the context that exists" do
    assert [hunk] = block(@lines, replaced(@lines, 1, "first"))["hunks"]
    assert hunk["old_start"] == 1
    assert hunk["old_lines"] == Diff.context_lines() + 1
    assert hunk["new_start"] == 1
    assert hunk["new_lines"] == Diff.context_lines() + 1
    assert hunk["lines"] == ["-l1", "+first", " l2", " l3", " l4"]
  end

  test "a change at the last line keeps the context that exists" do
    assert [hunk] = block(@lines, replaced(@lines, 20, "last"))["hunks"]
    assert hunk["old_start"] == 20 - Diff.context_lines()
    assert hunk["old_lines"] == Diff.context_lines() + 1
    assert hunk["new_start"] == 20 - Diff.context_lines()
    assert hunk["new_lines"] == Diff.context_lines() + 1
    assert hunk["lines"] == [" l17", " l18", " l19", "-l20", "+last"]
  end

  test "two changes far apart give two hunks, and changes within the double context give one" do
    gap = 2 * Diff.context_lines()
    joined = replaced(replaced(@lines, 3, "x"), 3 + gap + 1, "y")
    assert [_hunk] = block(@lines, joined)["hunks"]

    apart = replaced(replaced(@lines, 3, "x"), 3 + gap + 2, "y")
    assert [first, second] = block(@lines, apart)["hunks"]
    assert first["old_start"] < second["old_start"]
  end

  test "a CRLF file shows no carriage return" do
    block = Diff.block("a.txt", "a\r\nb\r\nc\r\n", "a\r\nB\r\nc\r\n")

    assert [hunk] = block["hunks"]
    assert hunk["lines"] == [" a", "-b", "+B", " c"]
    refute String.contains?(block["text"], "\r")
  end

  test "a new file is all added lines" do
    block = block("", "a\nb\nc\n")

    assert block["added"] == 3
    assert block["removed"] == 0

    assert block["hunks"] == [
             %{
               "old_start" => 0,
               "old_lines" => 0,
               "new_start" => 1,
               "new_lines" => 3,
               "lines" => ["+a", "+b", "+c"]
             }
           ]
  end

  test "the line hint makes the hunk starts file line numbers" do
    assert [hunk] = Diff.block("a.txt", "a\n", "b\n", 10)["hunks"]
    assert hunk["old_start"] == 10
    assert hunk["new_start"] == 10
  end

  test "a line at the byte limit is kept, and one over it is cut" do
    line = String.duplicate("x", Diff.line_bytes())

    block = block("", line <> "\n")
    assert [hunk] = block["hunks"]
    assert hunk["lines"] == ["+" <> line]
    refute Map.has_key?(block, "cut")

    longer = String.duplicate("x", Diff.line_bytes() + 1)
    block = block("", longer <> "\n")
    assert [hunk] = block["hunks"]
    assert hunk["lines"] == ["+" <> line <> " …"]
    assert block["cut"] == true
  end

  test "a cut inside a multibyte character stays valid UTF-8" do
    text = String.duplicate("x", Diff.line_bytes() - 1) <> "é" <> String.duplicate("y", 10)
    assert [hunk] = block("", text <> "\n")["hunks"]
    assert [line] = hunk["lines"]
    assert line == "+" <> String.duplicate("x", Diff.line_bytes() - 1) <> " …"
    assert String.valid?(line)
  end

  test "the budget keeps the lines that fit and counts every line" do
    line = String.duplicate("x", Diff.line_bytes())
    each = byte_size(line) + 2
    count = div(Diff.budget_bytes(), each)
    rest = Diff.budget_bytes() - count * each

    fits =
      Enum.map_join(1..count, fn _ -> line <> "\n" end) <> String.duplicate("r", rest - 2) <> "\n"

    block = block("", fits)
    assert block["added"] == count + 1
    assert hd(block["hunks"])["new_lines"] == count + 1
    refute Map.has_key?(block, "cut")

    block = block("", fits <> "q\n")
    assert block["added"] == count + 2
    assert hd(block["hunks"])["new_lines"] == count + 1
    assert block["cut"] == true
  end

  test "a large text with one changed line gives the file lines of the change" do
    count = 3 * Diff.max_diff_lines()
    old = Enum.map_join(1..count, "\n", &"l#{&1}") <> "\n"
    line = 2 * Diff.max_diff_lines()

    block = block(old, replaced(old, line, "changed"))
    assert block["added"] == 1
    assert block["removed"] == 1
    refute Map.has_key?(block, "cut")

    assert [hunk] = block["hunks"]
    assert hunk["old_start"] == line - Diff.context_lines()

    assert hunk["lines"] == [
             " l#{line - 3}",
             " l#{line - 2}",
             " l#{line - 1}",
             "-l#{line}",
             "+changed",
             " l#{line + 1}",
             " l#{line + 2}",
             " l#{line + 3}"
           ]
  end

  test "a middle at the line bound gives hunks, and one over it gives the not-shown block" do
    at = Diff.max_diff_lines()
    old = Enum.map_join(1..at, "\n", &"l#{&1}") <> "\n"
    block = block(old, changed_ends(at))
    assert [_, _] = block["hunks"]
    refute Map.has_key?(block, "cut")

    over = Enum.map_join(1..(at + 1), "\n", &"l#{&1}") <> "\n"
    block = block(over, changed_ends(at + 1))
    assert block["hunks"] == []
    assert block["cut"] == true
    assert block["added"] == at + 1
    assert block["removed"] == at + 1

    assert block["text"] ==
             "a.txt: #{at + 1} lines written, the diff is not shown over #{at} lines"
  end

  test "a text over the split bound is not split" do
    block = block("", String.duplicate("x", Helyx.Text.max_file_bytes() + 1))
    assert block["hunks"] == []
    assert block["cut"] == true
    assert block["added"] == 1
    assert block["removed"] == 0
  end

  test "two equal texts give no hunk" do
    block = block(@lines, @lines)
    assert block["added"] == 0
    assert block["removed"] == 0
    assert block["hunks"] == []
    assert block["text"] == "--- a/a.txt\n+++ b/a.txt\n"
    refute Map.has_key?(block, "cut")
  end

  test "a block at the budget passes the UI block check with escaped characters" do
    line =
      String.duplicate("x", 970) <>
        String.duplicate("\"", 10) <>
        String.duplicate("\t", 10) <> String.duplicate("\u0001", 10)

    block = block("", Enum.map_join(1..24, fn _ -> line <> "\n" end))

    assert Helyx.UIBlock.check(block) == {:ok, block}

    at_line_limit =
      block("", String.duplicate(String.duplicate("x", Diff.line_bytes()) <> "\n", 24))

    assert Helyx.UIBlock.check(at_line_limit) == {:ok, at_line_limit}
  end
end
