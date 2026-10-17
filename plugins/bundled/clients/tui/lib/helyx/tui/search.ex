defmodule Helyx.TUI.Search do
  @moduledoc false
  # Find text in the loaded transcript (#668, docs/features/tui-search.md).
  # Ctrl+F opens the search line in the place of the composer. `handle/3`
  # takes its keys and pastes and moves the view to a match; `marks/3`
  # marks the match on the screen. One match cursor: the item index of the
  # current match.

  alias ExRatatui.Event.{Key, Paste}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias Helyx.TUI.{Transcript, Wrap}

  @max_bytes 256

  @dim %Style{modifiers: [:dim]}
  @cursor %Style{modifiers: [:reversed]}
  @mark %Style{fg: :black, bg: :yellow}

  # `regex` is nil for an empty query; `match` is nil with no match; `note`
  # is a fixed text of the last search, or nil.
  defstruct query: "", regex: nil, match: nil, note: nil

  @type t :: %__MODULE__{
          query: String.t(),
          regex: Regex.t() | nil,
          match: non_neg_integer() | nil,
          note: String.t() | nil
        }

  # Ctrl+F, or a key or a paste while the search is open. `Helyx.TUI` gives
  # Ctrl+C, PgUp, PgDn, and Ctrl+O their usual rule before this check.
  defguard handles?(search, event)
           when (is_struct(event, Key) and event.code == "f" and event.modifiers == ["ctrl"]) or
                  (search != nil and is_struct(event, Key)) or
                  (search != nil and is_struct(event, Paste))

  # The answer of `Helyx.TUI.handle_event/2` to an event that `handles?/2`
  # accepts. `state` is the TUI state; `rects` are the transcript,
  # composer, and footer rects, nil when the terminal has no size. With no
  # size there is no screen to move to, so only Escape acts.
  @spec handle(struct(), map(), [Rect.t()] | nil) :: {:noreply, map()}
  def handle(event, state, rects), do: answer(event, state, rects && hd(rects))

  defp answer(%Key{code: "f", modifiers: ["ctrl"], kind: "press"}, %{search: nil} = state, _area),
    do: {:noreply, %{state | search: %__MODULE__{}}}

  defp answer(%Key{code: "esc", kind: "press"}, state, _area),
    do: {:noreply, %{state | search: nil}}

  defp answer(%Key{kind: kind} = key, %{search: %__MODULE__{}} = state, %Rect{} = area)
       when kind in ["press", "repeat"],
       do: {:noreply, key(state, key, area)}

  # The query is one line: a new line of a paste is a space, and the rest
  # is cleaned as the transcript draws it (`Wrap.sanitize/1`: a tab is two
  # spaces). The cut comes first, so a long paste costs no more than the
  # bound.
  defp answer(%Paste{content: content}, %{search: %__MODULE__{}} = state, %Rect{} = area) do
    text =
      content |> Helyx.Text.cap(@max_bytes, :head) |> String.replace(["\r\n", "\r", "\n"], " ")

    {:noreply, edit(state, state.search.query <> Wrap.sanitize(text), area)}
  end

  defp answer(_event, state, _area), do: {:noreply, state}

  # A key with Ctrl or Alt does nothing.
  defp key(state, %Key{modifiers: modifiers}, _area) when modifiers not in [[], ["shift"]],
    do: state

  defp key(state, %Key{code: code}, area) when code in ["enter", "up"],
    do: move(state, :older, area)

  defp key(state, %Key{code: "down"}, area), do: move(state, :newer, area)

  defp key(state, %Key{code: "backspace"}, area),
    do: edit(state, String.slice(state.search.query, 0..-2//1), area)

  # A named key, such as "tab" or "f1", has more than one code point. The
  # control rule is the one of the composer.
  defp key(state, %Key{code: code}, area) do
    if String.length(code) == 1 and Wrap.drop_controls(code) == code,
      do: edit(state, state.search.query <> code, area),
      else: state
  end

  # A new query looks for the nearest match at or before the cursor, and
  # else for the nearest match after it, so a longer query stays near the
  # match the user reads. The cut drops a character that would pass the
  # bound.
  defp edit(state, text, area) do
    text = Helyx.Text.cap(text, @max_bytes, :head)
    regex = if text != "", do: Regex.compile!(Regex.escape(text), "iu")
    %{match: match} = search = %{state.search | query: text, regex: regex, note: nil}
    state = %{state | search: search}

    cond do
      regex == nil -> %{state | search: %{search | match: nil}}
      found = find(state, match && match + 1, :older, area) -> show(state, found, area)
      found = match && find(state, match, :newer, area) -> show(state, found, area)
      true -> %{state | search: %{search | match: nil, note: "no match"}}
    end
  end

  # From no match, Enter and Up look from the newest item: the session can
  # have added one since the query changed.
  defp move(%{search: %{regex: nil}} = state, _direction, _area), do: state
  defp move(%{search: %{match: nil}} = state, :newer, _area), do: state

  defp move(state, direction, area) do
    case find(state, state.search.match, direction, area) do
      nil -> %{state | search: %{state.search | note: end_note(direction)}}
      found -> show(state, found, area)
    end
  end

  defp end_note(:older), do: "no older match"
  defp end_note(:newer), do: "no newer match"

  defp find(state, from, direction, area),
    do: Transcript.find(state.vm, state.search.regex, from, direction, area.width)

  # The view starts at the row of the match, held by `Transcript.hold/4`,
  # so a match near the end shows in the follow view.
  defp show(state, {index, row}, area) do
    %{
      state
      | scroll: Transcript.hold(state.vm, {index, row}, area.width, max(area.height, 1)),
        search: %{state.search | match: index, note: nil}
    }
  end

  # The search line in `area`, the rect of the composer, so an open or a
  # close does not change the transcript height: the query, a
  # reversed space as the cursor. The notes are the title of the box, on
  # its border, so a long query cannot push them past the edge. `marks` are
  # those of the frame: a match with none on the screen says so, also after
  # an end note. A row does not wrap, so a long query is cut at the edge.
  @spec widgets(t(), [{Block.t(), Rect.t()}], Rect.t()) :: [{Paragraph.t(), Rect.t()}]
  def widgets(%__MODULE__{} = search, marks, area) do
    shown = if search.match && marks == [], do: "match not shown"

    title =
      case Enum.reject([search.note, shown], &is_nil/1) do
        [] -> nil
        notes -> %Span{content: " " <> Enum.join(notes, ", ") <> " ", style: @dim}
      end

    spans = [
      %Span{content: "find: ", style: @dim},
      %Span{content: search.query},
      %Span{content: " ", style: @cursor}
    ]

    box = %Block{
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: :dark_gray},
      padding: {1, 0, 0, 0},
      title: title
    }

    [{%Paragraph{text: %Line{spans: spans}, block: box}, area}]
  end

  # A yellow mark over each place of the query in the drawn rows of the
  # matched item. Only the rows on the screen are scanned. The columns
  # follow the width rule of `Helyx.TUI.Wrap`, as the selection does.
  @spec marks(t() | nil, [{Transcript.address(), Line.t()}], Rect.t()) :: [
          {Block.t(), Rect.t()}
        ]
  def marks(%__MODULE__{regex: %Regex{} = regex, match: index}, rows, area)
      when is_integer(index) do
    for {{{^index, _row}, line}, y} <- Enum.with_index(rows),
        text = Transcript.line_text(line),
        [{at, size}] <- Regex.scan(regex, text, return: :index),
        from = Wrap.columns(binary_part(text, 0, at)),
        width = min(Wrap.columns(binary_part(text, at, size)), area.width - from),
        width > 0,
        do:
          {%Block{style: @mark}, %Rect{x: area.x + from, y: area.y + y, width: width, height: 1}}
  end

  def marks(_search, _rows, _area), do: []
end
