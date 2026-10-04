defmodule Helyx.TUI.MarkdownTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Helyx.TUI.{Markdown, Wrap}

  defp rows(text, width \\ 80), do: Markdown.rows(text, width)

  # The text of each row.
  defp texts(text, width), do: for(row <- rows(text, width), do: Enum.map_join(row, &elem(&1, 0)))

  describe "rows/2 inline" do
    test "bold, italic, and inline code lose their signs and get a style" do
      assert rows("a **b** *c* _d_ `e`") == [
               [
                 {"a ", []},
                 {"b", [:bold]},
                 {" ", []},
                 {"c", [:italic]},
                 {" ", []},
                 {"d", [:italic]},
                 {" ", []},
                 {"e", [:code]}
               ]
             ]
    end

    test "styles nest, and a code span inside bold keeps the bold" do
      assert rows("***x*** **a `b`**") == [
               [
                 {"x", [:bold, :italic]},
                 {" ", []},
                 {"a ", [:bold]},
                 {"b", [:bold, :code]}
               ]
             ]
    end

    test "a sign with no partner, a sign before a space, and a sign inside a word stay text" do
      assert texts("**open 2 * 3 snake_case_name a*b", 80) == [
               "**open 2 * 3 snake_case_name a*b"
             ]

      assert [[{"`no close", []}]] = rows("`no close")
    end

    test "a code span takes its content as it is, signs included" do
      assert rows("``a ` *b*``") == [[{"a ` *b*", [:code]}]]
    end

    test "a backslash escape keeps the sign, but not inside a code span" do
      assert texts("\\*not\\* \\`x\\`", 80) == ["*not* `x`"]

      assert rows("`C:\\` and `D:\\`") == [
               [{"C:\\", [:code]}, {" and ", []}, {"D:\\", [:code]}]
             ]

      assert rows("\\\\`a`") == [[{"\\", []}, {"a", [:code]}]]
    end

    test "a grapheme keeps one style, so a mark after a sign stays with its letter" do
      assert rows("**e**\u0301x") == [[{"e\u0301", [:bold]}, {"x", []}]]
      # The wrap drops the space before a space with a mark; the mark keeps its space.
      assert rows("ab  \u0301cd", 3) == [[{"ab", []}], [{" \u0301", []}, {"cd", []}]]
      assert [[{"\u2022 \u0301", []}, {"x", [:bold]}]] = rows("- **\u0301x**")
    end

    test "a link whose text is its address shows it once" do
      assert rows("[https://x.io](https://x.io)") == [[{"https://x.io", [:underlined]}]]
    end

    test "a link shows its text underlined and its address" do
      assert rows("see [docs](https://x.io) now") == [
               [
                 {"see ", []},
                 {"docs", [:underlined]},
                 {" (https://x.io) now", []}
               ]
             ]
    end
  end

  describe "rows/2 blocks" do
    test "a heading is bold without its signs" do
      assert rows("## Title *x*") == [[{"Title ", [:bold]}, {"x", [:bold, :italic]}]]
    end

    test "a bullet item gets a dot, and its rows hang under the text" do
      assert texts("- one two three", 10) == ["• one two", "  three"]
      assert texts("  * a", 10) == ["  • a"]
      assert texts("12. ab cd", 6) == ["12. ab", "    cd"]
    end

    test "a closed fence shows its lines as code, indented, without the fences" do
      assert rows("```elixir\n*x*  y\n```\nafter") == [
               [{"  ", []}, {"*x*  y", [:code]}],
               [{"after", []}]
             ]
    end

    test "a fence that is not closed shows as plain text from its opening line" do
      assert rows("**a**\n```\n# b *c*") == [
               [{"a", [:bold]}],
               [{"```", []}],
               [{"# b *c*", []}]
             ]
    end

    test "the sizes that make a block: up to 3 spaces, up to 6 #, up to 9 digits" do
      assert [[{"x", [:bold]}]] = rows("   ###### x")
      assert texts("####### x\n    # x\n#x", 80) == ["####### x", "    # x", "#x"]
      assert texts("123456789. a\n1234567890. a", 80) == ["123456789. a", "1234567890. a"]
    end

    test "a fence closes with its own sign and at least its own size" do
      assert [[_, {"a", [:code]}], [{"b", []}]] = rows("~~~\na\n~~~\nb")
      assert [[_, {"a", [:code]}]] = rows("```\na\n`````")
      assert texts("````\na\n```\n~~~~", 80) == ["````", "a", "```", "~~~~"]
      # A backtick in the info text makes no fence; the last line opens one.
      assert texts("```a`b\nc\n```", 80) == ["```a`b", "c", "```"]
    end

    test "a run of four signs or more stays text" do
      assert texts("****a****", 80) == ["****a****"]
    end

    test "a row that does not fit with its prefix has none" do
      # U+FE0F joins the space of the prefix into one grapheme of 2 columns.
      assert texts("- ️abc", 5) == ["️abc"]
      assert texts("- ️abc", 6) == ["• ️abc"]
    end

    test "an empty line stays an empty row" do
      assert texts("a\n\nb", 80) == ["a", "", "b"]
    end
  end

  describe "rows/2 width" do
    test "styled text wraps at spaces with its styles kept" do
      assert rows("aa **bb cc** dd", 7) == [
               [{"aa ", []}, {"bb", [:bold]}],
               [{"cc", [:bold]}, {" dd", []}]
             ]
    end

    property "no text crashes, and no row is wider than the width but for one glyph" do
      alphabet = ~w(* ** _ ` [ ] ( \) \\ # - 1. a b é 語 ́ \t) ++ [" ", "  ", "\n", "```"]

      check all(
              parts <- list_of(member_of(alphabet), max_length: 40),
              width <- integer(0..12)
            ) do
        text = Enum.join(parts)

        for row <- rows(text, width) do
          shown = Enum.map_join(row, &elem(&1, 0))
          # Each grapheme has one style: no segment starts inside one.
          assert Enum.flat_map(row, &String.graphemes(elem(&1, 0))) == String.graphemes(shown)
          assert Wrap.columns(shown) <= max(width, 1) or Wrap.rows(shown, 1) == [shown]
        end
      end
    end
  end
end
