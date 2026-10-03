# ex_ratatui is an optional dependency (ADR 0005): without it
# Helyx.TUI.Transcript does not exist.
defmodule Helyx.TUI.Transcript.Available do
  @moduledoc false
  # The recompile hook of ADR 0005. Mix reaches a stale source only through a
  # module the source defines, so each guarded file has its own.

  @available Code.ensure_loaded?(ExRatatui.App)

  @spec available?() :: boolean()
  def available?, do: @available

  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?, do: Code.ensure_loaded?(ExRatatui.App) != @available
end

if Helyx.TUI.Transcript.Available.available?() do
  defmodule Helyx.TUI.Transcript do
    @moduledoc """
    The transcript of the TUI: the cells of a `Helyx.TUI.ViewModel` as
    screen rows, and the rule for the scroll position. A position is nil,
    which follows the newest output, or `{cell, row}`, the first row on the
    screen: a cell index and a row in that cell. The rule, its costs, and
    its exceptions are in `docs/features/coding-agent.md`, "Transcript
    scrollback".
    """

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias ExRatatui.Widgets.Paragraph
    alias Helyx.Message
    alias Helyx.TUI.{ViewModel, Wrap}

    @dim %Style{modifiers: [:dim]}
    @bold %Style{modifiers: [:bold]}
    @tool %Style{fg: :cyan}
    @bad %Style{fg: :red}

    @type position :: {non_neg_integer(), non_neg_integer()} | nil

    # A scrolled view starts at a cell and a row in it. The cells before the
    # open message only grow in number, so new output does not move the view.
    # No line cache: no operation wraps all cells. A frame wraps the cells it
    # shows, and a page or a hold wraps the cells it passes, a small count of
    # screens. The feature doc has the measured costs and the exceptions.

    @doc """
    The transcript in `area` from `position`. With no position the view
    follows the newest output: the first row is one screen above the end.
    """
    @spec widget(ViewModel.t(), position(), Rect.t()) :: Paragraph.t()
    def widget(vm, scroll, %Rect{width: width, height: height}) do
      items = items(vm)
      top = scroll || bottom(items, width, height)
      %Paragraph{text: items |> rows_from(top, width) |> Enum.take(height)}
    end

    defp bottom(items, width, height),
      do: back(Enum.reverse(items), {length(items), 0}, height, width)

    @doc """
    The one rule for a position: its row is in its cell, and the rows from
    it to the end are more than one screen of `height` rows at `width`
    columns. If not, the row moves into the cells that follow, or the result
    is nil. A new cell can take the index of the open message, and a wider
    screen makes a cell shorter. Every position in the TUI state comes from
    here or is nil.
    """
    @spec hold(ViewModel.t(), {non_neg_integer(), non_neg_integer()}, integer(), pos_integer()) ::
            position()
    def hold(%ViewModel{} = vm, position, width, height),
      do: hold_items(items(vm), position, width, height)

    defp hold_items(items, {index, row}, width, height) do
      top = items |> Enum.drop(index) |> forward({index, row}, width)
      if length(items |> rows_from(top, width) |> Enum.take(height + 1)) > height, do: top
    end

    @doc """
    One screen up (`"page_up"`) or down (`"page_down"`) from `position`,
    held by `hold/4`.
    """
    @spec page(ViewModel.t(), position(), String.t(), integer(), pos_integer()) :: position()
    def page(_vm, nil, "page_down", _width, _height), do: nil

    def page(vm, {index, row}, "page_down", width, height),
      do: hold(vm, {index, row + height}, width, height)

    def page(vm, scroll, "page_up", width, height) do
      items = items(vm)
      {index, row} = scroll || bottom(items, width, height)
      top = items |> Enum.take(index) |> Enum.reverse() |> back({index, row}, height, width)
      hold_items(items, top, width, height)
    end

    # `before` is the cells above the position, nearest first.
    defp back(_before, {index, row}, count, _width) when row >= count, do: {index, row - count}
    defp back([], _position, _count, _width), do: {0, 0}

    defp back([item | before], {index, row}, count, width),
      do: back(before, {index - 1, length(item_lines(item, width))}, count - row, width)

    # Moves a row number that is past its cell into the cells that follow.
    defp forward([], {index, _row}, _width), do: {index, 0}

    defp forward([item | rest], {index, row}, width) do
      case length(item_lines(item, width)) do
        rows when row >= rows -> forward(rest, {index + 1, row - rows}, width)
        _rows -> {index, row}
      end
    end

    # The row skip stays in the first cell: a row past that cell shows its last
    # row. A frame can come before the check of a new width, and a skip over
    # all rows would wrap every cell that the old row number passes.
    defp rows_from(items, {index, row}, width) do
      case Enum.drop(items, index) do
        [] ->
          []

        [first | rest] ->
          lines = item_lines(first, width)

          lines
          |> Enum.drop(min(row, length(lines) - 1))
          |> Stream.concat(Stream.flat_map(rest, &item_lines(&1, width)))
      end
    end

    @doc "The whole transcript as `Line` structs of at most `width` columns."
    @spec lines(ViewModel.t(), integer()) :: [Line.t()]
    def lines(%ViewModel{} = vm, width), do: Enum.flat_map(items(vm), &item_lines(&1, width))

    # The cells, and the open assistant message as the last one.
    defp items(%ViewModel{streaming: nil, cells: cells}), do: cells

    # Its calls show as open tool cells after it, as when it ends.
    defp items(%ViewModel{streaming: streaming, cells: cells}) do
      {calls, blocks} =
        streaming |> Enum.reverse() |> Enum.split_with(&match?({:tool, _, _, _}, &1))

      cells ++ [%Message{role: :assistant, content: blocks} | calls]
    end

    defp item_lines(item, width), do: cell_lines(item, width) ++ [%Line{}]

    defp cell_lines(%Message{role: :user} = message, width) do
      styled_lines("› " <> shown_text(message), width, @bold)
    end

    defp cell_lines(%Message{role: :assistant} = message, width) do
      block_lines(message.content, width)
    end

    defp cell_lines({:tool, _call, line, result}, width) do
      styled_lines(line, width, @tool) ++ result_lines(result, width)
    end

    defp cell_lines({:notice, text}, width), do: styled_lines("✕ #{text}", width, @bad)

    defp block_lines(blocks, width) do
      Enum.flat_map(blocks, fn
        %Message.Text{text: text} -> styled_lines(text, width, %Style{})
        %Message.Thinking{thinking: text} -> styled_lines(text, width, @dim)
        %Message.ToolCall{} -> []
        # An image, or a kind that this client does not know.
        block -> styled_lines(placeholder(block), width, @dim)
      end)
    end

    # The text of a user message or a tool result, with a placeholder in
    # place of each block that is not text, such as an image.
    defp shown_text(%Message{content: content}) do
      Enum.map_join(content, fn
        %Message.Text{text: text} -> text
        block -> placeholder(block)
      end)
    end

    # A block that is not a struct is a bug in Core and crashes.
    # `Helyx.Message.Image` is "image".
    defp placeholder(%kind{}),
      do: "[unsupported block: #{kind |> Module.split() |> List.last() |> Macro.underscore()}]"

    defp result_lines(nil, width), do: styled_lines("… awaiting result", width, @dim)

    # Long tool output would drown the transcript; four lines tell the story.
    defp result_lines(%Message{} = result, width) do
      style = if result.is_error, do: @bad, else: @dim
      lines = result |> shown_text() |> String.trim_trailing("\n") |> String.split("\n")

      shown = Enum.flat_map(Enum.take(lines, 4), &styled_lines("  " <> &1, width, style))

      case length(lines) - 4 do
        hidden when hidden > 0 ->
          plural = if hidden == 1, do: "line", else: "lines"
          shown ++ styled_lines("  … #{hidden} more #{plural}", width, @dim)

        _ ->
          shown
      end
    end

    # One styled Line per screen row.
    defp styled_lines(text, width, style) do
      for row <- Wrap.rows(text, width), do: %Line{spans: [%Span{content: row, style: style}]}
    end
  end
end
