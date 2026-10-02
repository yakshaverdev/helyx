defmodule Helyx.TUI.WidthScanTest do
  # The width rule can count more columns than ExRatatui draws, never less.
  # Each line is a start, one code point, an end, and twelve "z", at width
  # 12, so the rule fills the first row to the edge with "z". When the rule
  # counts the grapheme too narrow, ExRatatui cuts a "z" from that row. The
  # starts and ends make the code point part of a grapheme of each kind:
  # after a letter, a wide glyph, a Devanagari letter, a modifier base, an
  # emoji that is no modifier base, a flag half, and a joiner, and before a
  # skin tone, a selector, and a joiner sequence. Each context is one
  # parameter, so the contexts run in parallel.
  use ExUnit.Case,
    async: true,
    parameterize:
      [%{first: "", last: ""}] ++
        Enum.map(
          ["a", "日", "क", "👍", "⚡", "🟠", "🇮", "👨\u200D", "\u2620\uFE0F\u200D"],
          &%{first: &1, last: ""}
        ) ++ Enum.map(["🏽", "\uFE0F", "\u200D👧"], &%{first: "", last: &1})

  import Helyx.Test.TUIRender

  # About 1.8 million rows: the draw does not scale over the cores.
  @moduletag :slow

  test "no grapheme is wider on screen than the width rule counts", %{first: first, last: last} do
    # U+20000 to U+3FFFD is one range of the rule: its two ends stand for it.
    # The last range is the emoji tags.
    ranges = [0x20..0x7E, 0xA0..0xD7FF, 0xE000..0x20FFF, 0x3F000..0x3FFFD, 0xE0000..0xE0FFF]

    for chunk <- ranges |> Enum.concat() |> Enum.chunk_every(4096) do
      rows =
        Enum.map(
          chunk,
          &hd(wrapped(<<first::binary, &1::utf8, last::binary, "zzzzzzzzzzzz">>, 12))
        )

      drawn = rows |> draw(12) |> String.split("\n")

      for {code, row, drawn_row} <- Enum.zip([chunk, rows, drawn]) do
        assert count_z(drawn_row) == count_z(row),
               "#{inspect(first)}, U+#{Integer.to_string(code, 16)}, #{inspect(last)}"
      end
    end
  end

  # By code point: a prepended mark joins the next "z" into one grapheme.
  defp count_z(row), do: Enum.count(String.to_charlist(row), &(&1 == ?z))
end
