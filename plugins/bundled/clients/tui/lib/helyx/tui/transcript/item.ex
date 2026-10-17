defmodule Helyx.TUI.Transcript.Item do
  @moduledoc false
  # One item of `Helyx.TUI.Transcript`: a cell, such as a run of
  # information lines `{:infos, texts}`, or a tool cell with `true` at its
  # end when the Ctrl+O toggle is on. It owns the look of the rows of an item, the
  # search text of each row, the signs of the row left out
  # (`docs/features/tui-search.md`, "The search rows"), and the text of a
  # drawn row for a selection, the bar left out.

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias Helyx.Message
  alias Helyx.TUI.{Markdown, Wrap}

  @dim %Style{modifiers: [:dim]}
  @tool %Style{fg: :cyan}
  @bad %Style{fg: :red}
  # Palette colors, so the look follows the terminal theme. White on black
  # reads in light and dark themes alike.
  @user %Style{fg: :white, bg: :black}
  @bar %Style{fg: :blue, bg: :black}
  @code :yellow

  @type t :: Message.t() | tuple()
  @typedoc "The search text of a row: its column and its text."
  @type search :: {non_neg_integer(), String.t()}

  # Each drawn row of `item` at `width` with its search text: a column
  # and the text there. The last row is empty.
  @spec rows(t(), integer()) :: [{Line.t(), search()}]
  def rows(item, width), do: cell_rows(item, width) ++ [{%Line{}, {0, ""}}]

  # The text that the search matches in the whole item, cleaned by the
  # caller: also the result lines that the short form hides, and no sign.
  @spec search_text(t()) :: String.t()
  def search_text(%Message{role: :assistant, content: blocks}) do
    Enum.map_join(blocks, "\n", fn
      %Message.Text{text: text} -> text
      %Message.Thinking{thinking: text} -> text
      _block -> ""
    end)
  end

  def search_text(%Message{} = message), do: shown_text(message)
  def search_text({:tool, _call, line, nil}), do: line
  def search_text({:tool, _call, line, result}), do: line <> "\n" <> shown_text(result)

  def search_text({:tool, call, line, result, true}),
    do: search_text({:tool, call, line, result})

  def search_text({:notice, text}), do: text
  def search_text({:stop, reason}), do: stop_text(reason)
  def search_text({:infos, texts}), do: infos_text(texts)

  # The graphemes of a drawn row with a column in `from..to`, by the width
  # rule, the bar left out: the text of a selection.
  @spec cut(Line.t(), integer(), integer()) :: String.t()
  def cut(%Line{spans: spans}, from, to) do
    {kept, _column} =
      Enum.reduce(spans, {[], 0}, fn %Span{content: content, style: style}, acc ->
        content
        |> String.graphemes()
        |> Enum.reduce(acc, fn grapheme, {kept, column} ->
          # A zero-width grapheme takes no column, as ExRatatui draws it,
          # and is in the text when its column is.
          next = column + Wrap.columns(grapheme)
          keep? = style != @bar and column <= to and max(next, column + 1) > from
          {if(keep?, do: [grapheme | kept], else: kept), next}
        end)
      end)

    kept |> Enum.reverse() |> Enum.join()
  end

  # A bar and a tint on every row. A row that the text width cannot hold,
  # a glyph wider than it, has no bar, so the row stays within the width
  # when the glyph does. Every row gets a fill of the whole width, which
  # ExRatatui cuts at the edge: the rule can count a glyph wider than
  # ExRatatui draws it, so a fill counted by the rule can stop short. The
  # fill is a span of its own, so that a last character such as U+0600
  # cannot join a space into one grapheme that ExRatatui cuts whole.
  defp cell_rows(%Message{role: :user} = message, width) do
    text_width = width - 2
    fill = String.duplicate(" ", max(width, 0))

    # No code point has more columns than bytes, so a short row needs no count.
    for row <- Wrap.rows(shown_text(message), text_width) do
      {bar, column} =
        if byte_size(row) <= text_width or Wrap.columns(row) <= text_width,
          do: {[%Span{content: "▌ ", style: @bar}], 2},
          else: {[], 0}

      spans = bar ++ [%Span{content: row, style: @user}, %Span{content: fill, style: @user}]
      {%Line{spans: spans}, {column, row}}
    end
  end

  defp cell_rows(%Message{role: :assistant} = message, width) do
    block_rows(message.content, width)
  end

  defp cell_rows({:tool, call, line, result}, width),
    do: cell_rows({:tool, call, line, result, false}, width)

  defp cell_rows({:tool, _call, line, result, expanded?}, width) do
    styled_rows(line, width, @tool) ++ result_rows(result, expanded?, width)
  end

  defp cell_rows({:notice, text}, width), do: signed("✕ ", text, width, @bad)
  defp cell_rows({:stop, reason}, width), do: cell_rows({:notice, stop_text(reason)}, width)

  defp cell_rows({:infos, texts}, width), do: styled_rows(infos_text(texts), width, @dim)

  defp infos_text(texts), do: Enum.map_join(texts, " ", &("· " <> &1))

  defp stop_text(:max_tokens), do: "the answer stopped at the token limit"
  defp stop_text(:refused), do: "the answer stopped: the provider refused or filtered it"

  defp block_rows(blocks, width) do
    Enum.flat_map(blocks, fn
      %Message.Text{text: text} -> markdown_rows(text, width)
      %Message.Thinking{thinking: text} -> styled_rows(text, width, @dim)
      %Message.ToolCall{} -> []
      # A kind that this client does not know. Its placeholder is a sign.
      block -> block |> placeholder() |> styled_rows(width, @dim) |> sign_rows()
    end)
  end

  # The text of a user message or a tool result, with a placeholder in
  # place of each block that is not text.
  defp shown_text(%Message{content: content}) do
    Enum.map_join(content, fn
      %Message.Text{text: text} -> text
      block -> placeholder(block)
    end)
  end

  # A block that is not a struct is a bug in Core and crashes.
  # `Helyx.Message.Thinking` is "thinking".
  defp placeholder(%kind{}),
    do: "[unsupported block: #{kind |> Module.split() |> List.last() |> Macro.underscore()}]"

  defp result_rows(nil, _expanded?, width),
    do: "… awaiting result" |> styled_rows(width, @dim) |> sign_rows()

  # The short form keeps long tool output from filling the transcript.
  # Ctrl+O shows all lines.
  defp result_rows(%Message{} = result, expanded?, width) do
    style = if result.is_error, do: @bad, else: @dim
    lines = result |> shown_text() |> String.trim_trailing("\n") |> String.split("\n")
    kept = if expanded?, do: lines, else: Enum.take(lines, 4)
    shown = Enum.flat_map(kept, &signed("  ", &1, width, style))

    case length(lines) - length(kept) do
      hidden when hidden > 0 ->
        plural = if hidden == 1, do: "line", else: "lines"
        hint = styled_rows("  … #{hidden} more #{plural} (ctrl+o to expand)", width, @dim)
        shown ++ sign_rows(hint)

      _ ->
        shown
    end
  end

  defp markdown_rows(text, width),
    do:
      for(
        row <- Markdown.rows(text, width),
        do: segment_row(row, Enum.map(row, &markdown_span/1))
      )

  # A row of segments, drawn as `spans`, starts with its signs, such as the
  # prefix of an item.
  defp segment_row(row, spans) do
    {signs, rest} = Enum.split_while(row, fn {_text, tags} -> :sign in tags end)
    column = Wrap.columns(Enum.map_join(signs, &elem(&1, 0)))
    {%Line{spans: spans}, {column, Enum.map_join(rest, &elem(&1, 0))}}
  end

  defp markdown_span({content, tags}) do
    fg = if :code in tags, do: @code
    %Span{content: content, style: %Style{fg: fg, modifiers: tags -- [:code, :sign]}}
  end

  # One styled Line per screen row, all of it search text.
  defp styled_rows(text, width, style) do
    for row <- Wrap.rows(text, width),
        do: {%Line{spans: [%Span{content: row, style: style}]}, {0, row}}
  end

  # The rows of `sign` and the `text` after it, wrapped as segments, so
  # the sign is not search text on any row: the wrap can cut it, drop its
  # space, or join its space and a mark of the text into one grapheme.
  defp signed(sign, text, width, style) do
    [first | rest] = text |> Wrap.sanitize() |> String.split("\n")

    [[{sign, [:sign]}, {first, []}] | Enum.map(rest, &[{&1, []}])]
    |> Enum.flat_map(&Markdown.segment_rows(&1, width))
    |> Enum.map(fn row ->
      segment_row(row, [%Span{content: Enum.map_join(row, &elem(&1, 0)), style: style}])
    end)
  end

  defp sign_rows(rows), do: for({line, _search} <- rows, do: {line, {0, ""}})
end
