defmodule Helyx.TUI.Wrap do
  @moduledoc """
  The width rule of the TUI: text to screen rows of at most a given number
  of columns. Pure; it needs nothing from `ex_ratatui` (ADR 0005). The
  bound is in `docs/features/coding-agent.md`, "Transcript row width".
  """

  # East Asian Wide and Fullwidth blocks, the emoji blocks, and other ranges
  # that ExRatatui draws as two columns.
  @wide_ranges [
    0x1100..0x115F,
    0x2329..0x232A,
    0x2630..0x2637,
    0x268A..0x268F,
    0x2E80..0x303E,
    0x3041..0xA4CF,
    0xA960..0xA97F,
    0xAC00..0xD7A3,
    0xF900..0xFAFF,
    0xFE10..0xFE19,
    0xFE30..0xFE6F,
    0xFF01..0xFF60,
    0xFFE0..0xFFE6,
    0x16FE0..0x18DFF,
    0x1AFF0..0x1B2FF,
    0x1D300..0x1D37F,
    0x1F18E..0x1F19A,
    0x1F1E6..0x1F2FF,
    0x1F300..0x1F64F,
    0x1F680..0x1F6FF,
    0x1F7E0..0x1F7F0,
    0x1F900..0x1F9FF,
    0x1FA70..0x1FAFF,
    0x20000..0x3FFFD
  ]

  # The emoji outside the emoji blocks that are two columns with no selector.
  @wide_symbols Enum.concat([
                  [0x231A, 0x231B, 0x23F0, 0x23F3, 0x25FD, 0x25FE, 0x2614, 0x2615],
                  [0x267F, 0x2693, 0x26A1, 0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4],
                  [0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26FA],
                  [0x26FD, 0x2705, 0x270A, 0x270B, 0x2728, 0x274C, 0x274E, 0x2757],
                  [0x27B0, 0x27BF, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55, 0x1F004, 0x1F0CF],
                  0x23E9..0x23EC,
                  0x2648..0x2653,
                  0x2753..0x2755,
                  0x2795..0x2797
                ])

  @doc """
  The screen rows of `text` at `width` columns: control characters drop,
  tabs become two spaces, each new line starts a row, and each line wraps.
  """
  @spec rows(String.t(), integer()) :: [String.t()]
  def rows(text, width) do
    for line <- text |> sanitize() |> String.split("\n"), row <- wrap(line, width), do: row
  end

  # Model text and tool output reach the terminal raw through span content,
  # so an ESC, OSC, or CSI sequence in a file could retitle the terminal or
  # move the cursor. Tabs become spaces; other control characters drop.
  # Core makes the text valid UTF-8 at its boundaries, so the /u regex
  # does not raise, and a CSI can only be U+009B, which drops.
  defp sanitize(text), do: text |> String.replace("\t", "  ") |> drop_controls()

  @doc "Removes all C0 and C1 control characters but tab and new line."
  @spec drop_controls(String.t()) :: String.t()
  def drop_controls(text),
    do: String.replace(text, ~r/[\x00-\x08\x0B-\x1F\x7F\x{80}-\x{9F}]/u, "")

  # The wrap is one pure function from a line and a width to its rows. No
  # row is wider than `width` columns, with one exception: a glyph wider than
  # the whole width gets a row of its own, so that the wrap always ends.
  # Fast path: no code point has more columns than bytes, so a line of
  # `width` bytes or less is one row. This also covers the empty line.
  defp wrap(line, width) when byte_size(line) <= width, do: [line]

  defp wrap(line, width) do
    width = max(width, 1)

    {rows, row, _used} =
      line
      |> String.graphemes()
      |> Enum.reduce({[], [], 0}, fn grapheme, {rows, row, used} ->
        needs = columns(grapheme)

        if used + needs > width and row != [],
          do: {[row | rows], [grapheme], needs},
          else: {rows, [grapheme | row], used + needs}
      end)

    Enum.map(Enum.reverse([row | rows]), &(&1 |> Enum.reverse() |> Enum.join()))
  end

  # ponytail: a short width rule, not the Unicode tables (ticket #90).
  # ExRatatui has no width function in Elixir, and OTP has no
  # `:string.width/1`. The rule must never count less than ExRatatui draws,
  # because ExRatatui cuts a row at the edge. So it has no rule for an emoji
  # sequence: ExRatatui draws an emoji with a skin tone, a joiner sequence, or
  # a flag as two columns, and this rule counts each emoji in it. Such a row
  # is shorter than it could be. Replace this with a width function of
  # ExRatatui when it has one.
  #
  # Fast path: the clause below gives the same result for ASCII.
  defp columns(<<byte>>) when byte < 0x80, do: 1
  defp columns(grapheme), do: sum_columns(grapheme, 0)

  # ExRatatui adds the code points of a grapheme: a Devanagari cluster can be
  # four columns. The emoji selector U+FE0F makes the code point before it
  # two columns.
  defp sum_columns(<<code::utf8, 0xFE0F::utf8, rest::binary>>, sum),
    do: sum_columns(rest, sum + max(code_point_columns(code), 2))

  defp sum_columns(<<code::utf8, rest::binary>>, sum),
    do: sum_columns(rest, sum + code_point_columns(code))

  defp sum_columns(<<>>, sum), do: sum

  # Combining marks, zero-width spaces, joiners and direction marks, variation
  # selectors, emoji tags, and the Hangul vowels and finals that join the
  # syllable before them. Marks of other scripts count as one column.
  defp code_point_columns(code)
       when code in 0x0300..0x036F or code in 0x1160..0x11FF or code in 0x200B..0x200F or
              code in 0x20D0..0x20F0 or code in 0xFE00..0xFE0F or code in 0xFE20..0xFE2F or
              code in 0xE0000..0xE0FFF,
       do: 0

  # Two Khmer code points that ExRatatui draws as the letters they stand for.
  defp code_point_columns(0x17A4), do: 2
  defp code_point_columns(0x17D8), do: 3
  defp code_point_columns(code), do: if(wide?(code), do: 2, else: 1)

  # East Asian Wide and Fullwidth, and the emoji that are wide by default.
  # No code point below U+1100 is wide.
  defp wide?(code) when code < 0x1100, do: false

  # One guard clause for each range: `in` on a range that is not a literal
  # goes through a protocol for each code point.
  for first..last//_ <- @wide_ranges do
    defp wide?(code) when code in unquote(first)..unquote(last), do: true
  end

  defp wide?(code), do: code in @wide_symbols
end
