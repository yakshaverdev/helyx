defmodule Helyx.TUI.WrapTest do
  use ExUnit.Case, async: true

  alias Helyx.TUI.Wrap

  describe "rows/2 breaks at spaces" do
    test "a word that does not fit moves to the next row whole" do
      text = "He stood in wet socks, staring at the empty place"

      assert Wrap.rows(text, 20) == ["He stood in wet", "socks, staring at", "the empty place"]
    end

    test "a closing quote stays with its word" do
      assert Wrap.rows("“Very much, fortunately.”", 16) == ["“Very much,", "fortunately.”"]
    end

    test "a word wider than the row breaks inside, and only that word" do
      assert Wrap.rows("ab cdefghijk lm", 5) == ["ab", "cdefg", "hijk", "lm"]
    end

    test "the space at a break drops, and a continuation row starts with no space" do
      assert Wrap.rows("abcd   ef", 4) == ["abcd", "ef"]
      assert Wrap.rows("ab   cdef", 4) == ["ab  ", "cdef"]
    end

    test "the indent of a line stays, and drops when the word does not fit after it" do
      assert Wrap.rows("    indented words", 12) == ["    indented", "words"]
      assert Wrap.rows("  hello", 5) == ["hello"]
      assert Wrap.rows("  hello world", 7) == ["  hello", "world"]
      assert Wrap.rows("  abcdefgh", 5) == ["abcde", "fgh"]
      assert Wrap.rows("      hello", 5) == ["hello"]
      assert Wrap.rows("\t\t\thello", 5) == ["hello"]
    end

    test "a space at the end makes no row, and a line of spaces alone is one row" do
      assert Wrap.rows("hello ", 5) == ["hello"]
      assert Wrap.rows("hello world  ", 11) == ["hello world"]
      assert Wrap.rows(String.duplicate(" ", 12), 5) == [""]
    end

    test "a wide glyph counts two columns when the row looks for a space" do
      assert Wrap.rows("日本 語日本", 5) == ["日本", "語日", "本"]
    end

    test "a line that fits is one row, with its trailing spaces" do
      assert Wrap.rows("a b  ", 5) == ["a b  "]
    end

    test "no row is wider than the width, at every width" do
      text = "a bb ccc dddd eeeee 日本 ffffff g " <> String.duplicate("h", 13)

      for width <- 1..20, row <- Wrap.rows(text, width) do
        # A glyph wider than the whole width has a row of its own.
        assert Wrap.columns(row) <= width or String.length(row) == 1,
               "width #{width}: #{inspect(row)}"
      end

      # No text is lost but the spaces at the breaks.
      for width <- 1..20 do
        assert text |> Wrap.rows(width) |> Enum.join() |> String.replace(" ", "") ==
                 String.replace(text, " ", "")
      end
    end
  end

  test "columns/1 counts the terminal columns of a row" do
    assert Wrap.columns("") == 0
    assert Wrap.columns("ab") == 2
    assert Wrap.columns("a日é") == 4
  end
end
