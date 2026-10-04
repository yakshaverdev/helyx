# ex_ratatui is an optional dependency (ADR 0005): without it
# Helyx.TUI.Selection does not exist.
defmodule Helyx.TUI.Selection.Available do
  @moduledoc false
  use Helyx.TUI.Guard
end

if Helyx.TUI.Selection.Available.available?() do
  defmodule Helyx.TUI.Selection do
    @moduledoc """
    The mouse of the TUI: the wheel, the selection of transcript text, and
    its copy to the clipboard. `Helyx.TUI` hands each mouse event to
    `handle/3` and returns its answer. A mouse event never reaches
    `Helyx.TUI.Quit`, so it neither arms nor disarms the quit.

    A wheel step scrolls the transcript three rows. A press of any button
    clears the reason of the last reject, as a key press does. A left press
    in the transcript starts a selection, a drag moves its end, and the
    release copies the text with OSC 52. The ends are transcript addresses
    with a column, so a scroll keeps the selected text, and a selection can
    reach into the scrollback that the view passed during the drag. A press
    outside the transcript, or a new size, clears it. The TUI draws it in
    reverse video until the next left press. An event that changes nothing,
    such as a move or a wheel step at an end, draws no frame.

    The copy is one write of the whole escape sequence, never a part of it.
    The text is at most 75,000 bytes, which is 100,000 bytes of base64. A
    longer text is not copied, and the footer says so. The write goes to
    standard output between two frames, in the event handler. A frame that
    the terminal draws at the same moment can show broken cells until the
    next frame. The design is in `docs/features/coding-agent.md`, "TUI".
    """

    alias ExRatatui.Event.Mouse
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Widgets.{Block, Paragraph}
    alias Helyx.TUI.{Transcript, ViewModel}

    @max_bytes 75_000
    @reversed %Style{modifiers: [:reversed]}

    @enforce_keys [:anchor, :head]
    defstruct [:anchor, :head]

    @typedoc "The press end and the drag end: an address and a column."
    @type t :: %__MODULE__{
            anchor: {Transcript.address(), non_neg_integer()},
            head: {Transcript.address(), non_neg_integer()}
          }

    @doc """
    The answer of `Helyx.TUI.handle_event/2` to a mouse event. `state` is the
    TUI state, a map with `:selection`, `:vm`, and `:scroll`; `rects` are the
    transcript, composer, and footer rects of the frame, nil when the
    terminal has no size. A release with text writes the OSC 52 sequence to
    standard output.
    """
    @spec handle(Mouse.t(), map(), [Rect.t()] | nil) ::
            {:noreply, map()} | {:noreply, map(), [render?: false]}
    def handle(mouse, state, rects) do
      case mouse(state, mouse, rects && hd(rects)) do
        ^state -> {:noreply, state, render?: false}
        changed -> {:noreply, changed}
      end
    end

    # The clear compares with the state as it came in, so a press that only
    # clears the reason still draws.
    defp mouse(state, %Mouse{kind: "down"} = mouse, area) do
      state = %{state | vm: ViewModel.clear_reason(state.vm)}
      if mouse.button == "left", do: %{state | selection: press(state, mouse, area)}, else: state
    end

    defp mouse(state, _mouse, nil), do: state

    # A transcript of no rows has nothing to scroll.
    defp mouse(state, %Mouse{kind: kind}, area)
         when kind in ["scroll_up", "scroll_down"] and area.height > 0,
         do: %{
           state
           | scroll: Transcript.page(state.vm, state.scroll, kind, area.width, area.height)
         }

    defp mouse(
           %{selection: %__MODULE__{} = selection} = state,
           %Mouse{kind: "drag", button: "left"} = mouse,
           area
         ) do
      case point(state, mouse.x, mouse.y, area) do
        nil -> state
        point -> %{state | selection: %{selection | head: point}}
      end
    end

    defp mouse(
           %{selection: %__MODULE__{anchor: anchor, head: head}} = state,
           %Mouse{kind: "up", button: "left"},
           area
         )
         when anchor != head do
      {first, last} = ends(anchor, head)

      case state.vm |> Transcript.text(first, last, area.width) |> join_bounded() do
        "" ->
          state

        :too_large ->
          %{state | vm: ViewModel.reject(state.vm, "not copied: over 75 KB")}

        text ->
          IO.write("\e]52;c;" <> Base.encode64(text) <> "\a")
          state
      end
    end

    defp mouse(state, _mouse, _area), do: state

    # A new selection at the press, nil outside the transcript.
    defp press(_state, _mouse, nil), do: nil

    defp press(state, %Mouse{x: x, y: y}, area) do
      inside? =
        x >= area.x and x < area.x + area.width and y >= area.y and y < area.y + area.height

      point = if inside?, do: point(state, x, y, area)
      point && %__MODULE__{anchor: point, head: point}
    end

    # The rows joined by new lines, or :too_large as soon as the text passes
    # the bound, so a long selection is not wrapped to its end.
    defp join_bounded(rows) do
      rows
      |> Enum.reduce_while({[], -1}, fn row, {kept, bytes} ->
        bytes = bytes + 1 + byte_size(row)
        if bytes > @max_bytes, do: {:halt, :too_large}, else: {:cont, {[row | kept], bytes}}
      end)
      |> case do
        :too_large -> :too_large
        {kept, _bytes} -> kept |> Enum.reverse() |> Enum.join("\n")
      end
    end

    # The address and column under the mouse, moved into the drawn rows: a
    # drag past an edge selects to that edge. nil when no row is drawn.
    defp point(state, x, y, area) do
      case Transcript.screen(state.vm, state.scroll, area) do
        [] ->
          nil

        rows ->
          {address, _line} = Enum.at(rows, min(max(y - area.y, 0), length(rows) - 1))
          {address, min(max(x - area.x, 0), area.width - 1)}
      end
    end

    @doc """
    The transcript in `area`, and over it a reverse video block on each
    selected cell of the screen.
    """
    @spec widgets(t() | nil, ViewModel.t(), Transcript.position(), Rect.t()) :: [
            {Paragraph.t() | Block.t(), Rect.t()}
          ]
    def widgets(selection, vm, scroll, area) do
      rows = Transcript.screen(vm, scroll, area)
      [{Transcript.widget(rows), area} | marks(selection, rows, area)]
    end

    # The ends in transcript order: a drag can go up.
    defp ends(anchor, head), do: Enum.min_max([anchor, head])

    defp marks(nil, _rows, _area), do: []
    defp marks(%__MODULE__{anchor: same, head: same}, _rows, _area), do: []

    defp marks(%__MODULE__{anchor: anchor, head: head}, rows, area) do
      {{first, _} = first_point, {last, _} = last_point} = ends(anchor, head)

      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {{address, _line}, y} ->
        # A frame before the check of a new width can be narrower.
        {from, to} = Transcript.columns(address, first_point, last_point, area.width)

        if address >= first and address <= last and to >= from,
          do: [
            {%Block{style: @reversed},
             %Rect{x: area.x + from, y: area.y + y, width: to - from + 1, height: 1}}
          ],
          else: []
      end)
    end
  end
end
