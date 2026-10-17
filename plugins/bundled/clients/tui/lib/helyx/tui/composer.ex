defmodule Helyx.TUI.Composer do
  @moduledoc """
  The composer of the TUI: the input widget and the paste markers that
  stand for long pastes. A marker is one unit for every key. The rules
  and their bounds are in `docs/features/multiline-composer.md`.

  The input widget is a mutable `ExRatatui` resource: a composer that a
  function returns shares it with the one it got.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph, Textarea}
  alias Helyx.Event
  alias Helyx.TUI.{Command, ViewModel, Wrap}
  alias Helyx.TUI.Composer.Paste

  # The composer shows at most this many lines inside its two borders.
  @composer_lines 8

  # The column of the first character of the composer text: after the
  # border, a space, the `›` mark, and a space.
  @text_column 4

  @word_moves %{
    {"b", ["alt"]} => :back,
    {"left", ["ctrl"]} => :back,
    {"f", ["alt"]} => :forward,
    {"right", ["ctrl"]} => :forward
  }

  # `pastes` maps the text of each live marker to the full paste it
  # stands for. `count` is the id of the last marker. Both are emptied
  # with the composer, so a marker id is not used twice before then.
  # `recall` is nil while the user edits the draft. While an earlier
  # prompt shows, it holds the position of that prompt's cell, the text
  # that shows for it, so an edit is seen, and the draft with its pastes,
  # so Down or a send can bring the draft back.
  @enforce_keys [:input]
  defstruct [:input, pastes: %{}, count: 0, recall: nil]

  @type t :: %__MODULE__{
          input: reference(),
          pastes: %{String.t() => String.t()},
          count: non_neg_integer(),
          recall: {non_neg_integer(), String.t(), String.t(), %{String.t() => String.t()}} | nil
        }

  @doc "An empty composer."
  @spec new() :: t()
  def new, do: %__MODULE__{input: ExRatatui.textarea_new()}

  @doc """
  Applies event text: `:insert` inserts it, `:key` sends a key code to
  the widget, and `:paste` inserts a paste. ExRatatui gives event text as
  a Rust `String`, so it is valid UTF-8.
  """
  @spec edit(t(), :insert | :key | :paste, String.t()) :: t()
  def edit(%__MODULE__{} = composer, :insert, text), do: insert(composer, text)
  def edit(%__MODULE__{} = composer, :key, code), do: widget_key(composer, code)
  def edit(%__MODULE__{} = composer, :paste, content), do: paste(composer, content)

  @doc """
  Applies a key press or repeat: Ctrl+A and Ctrl+E as Home and End, Alt+B
  or Ctrl+Left one word back, and Alt+F or Ctrl+Right one word forward. A
  key with no modifier but Shift goes to the widget; any other does nothing.
  """
  @spec press(t(), String.t(), [String.t()]) :: t()
  def press(composer, "a", ["ctrl"]), do: widget_key(composer, "home")
  def press(composer, "e", ["ctrl"]), do: widget_key(composer, "end")

  # A marker is one word: a word move from inside a marker, or one that ends
  # inside it (the widget moves in the `case`), stops at the first end it passes.
  def press(composer, code, mods) when is_map_key(@word_moves, {code, mods}) do
    from = ExRatatui.textarea_cursor(composer.input)

    case marker_at(composer, :inside) || composer |> key(code, mods) |> marker_at(:inside) do
      nil ->
        composer

      {value, span} ->
        at = word_end(@word_moves[{code, mods}], offset(value, from), span)
        cut(composer, value, at, at)
    end
  end

  def press(composer, code, mods) when mods in [[], ["shift"]], do: widget_key(composer, code)
  def press(composer, _code, _mods), do: composer

  @doc """
  What Enter sends: `:empty`, a slash command (`Helyx.TUI.Command`), or
  the message, with its paste markers expanded. The composer does not
  change.
  """
  @spec submit(t()) :: :empty | Command.t() | {:message, String.t()}
  def submit(%__MODULE__{} = composer) do
    case ExRatatui.textarea_get_value(composer.input) do
      "" -> :empty
      value -> value |> Paste.expand(composer.pastes) |> Command.parse()
    end
  end

  @doc "True when the composer holds no text."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{input: input}), do: ExRatatui.textarea_get_value(input) == ""

  @doc "True when `clear/1` drops nothing: no text, and no draft that Down brings back."
  @spec nothing_to_clear?(t()) :: boolean()
  def nothing_to_clear?(%__MODULE__{recall: {_at, _shown, draft, _pastes}}) when draft != "",
    do: false

  def nothing_to_clear?(composer), do: empty?(composer)

  @doc "Empties the composer and forgets its pastes."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = composer), do: %{show(composer, "up", "", %{}, nil) | count: 0}

  @doc "Ends a recall: the waiting draft comes back, or the composer empties."
  @spec restore(t()) :: t()
  def restore(%__MODULE__{recall: {_at, _shown, draft, pastes}} = composer) when draft != "",
    do: show(composer, "down", draft, pastes, nil)

  def restore(composer), do: clear(composer)

  @doc """
  Up or Down: recalls an earlier prompt of the session, the user messages
  in `vm`, when the cursor is on the first row (Up) or the last row (Down).
  Down past the newest prompt brings back the draft. Otherwise the key
  moves the cursor. Up leaves the cursor at the start, Down at the end, so
  the next Up or Down goes on through the prompts.

  A key that leaves an edited recalled prompt, to another prompt or Down
  past the newest, first makes it the draft: the draft that waits, then
  the edit, one per new line, with the pastes of both and the cursor on
  the same character. Then the key acts on that draft. Any other key only
  moves the cursor, and the recall stays.
  """
  @spec recall(t(), ViewModel.t(), String.t()) :: t()
  def recall(%__MODULE__{} = composer, vm, code) when code in ["up", "down"] do
    composer = if leaves?(composer, vm, code), do: keep_edit(composer), else: composer
    position = with {at, _shown, _draft, _pastes} <- composer.recall, do: at

    case edge?(composer, code) && ViewModel.prompt(vm, position, direction(code)) do
      {at, text} ->
        text = Paste.clean(text)
        show(composer, code, text, %{}, recalled(composer, at, text))

      nil when code == "down" and position != nil ->
        restore(composer)

      _no_prompt ->
        widget_key(composer, code)
    end
  end

  @doc """
  Applies a session event. Only `:queue_dropped` changes the composer:
  the texts that an abort or a failed turn gave back, in their order,
  then the draft, then a recalled prompt that shows, edited or not, one
  per new line, with the cursor at the end. Both keep their pastes. The
  paste rule cleans each text, so a text cannot forge a marker.
  """
  @spec apply(t(), Event.t()) :: t()
  def apply(%__MODULE__{} = composer, %Event{type: :queue_dropped, data: %{texts: texts}}),
    do: join_draft(composer, Enum.map(texts, &Paste.clean/1))

  def apply(%__MODULE__{} = composer, %Event{}), do: composer

  @doc """
  Ends a recall and keeps what the user has: the draft that waits, then the
  recalled prompt that shows, edited or not, one per new line, with the
  cursor at the end. With no recall the composer does not change.
  """
  @spec end_recall(t()) :: t()
  def end_recall(%__MODULE__{recall: nil} = composer), do: composer
  def end_recall(%__MODULE__{} = composer), do: join_draft(composer, [])

  defp join_draft(composer, texts) do
    {parts, pastes} = draft_parts(composer, ExRatatui.textarea_get_value(composer.input))
    show(composer, "down", Enum.join(texts ++ parts, "\n"), pastes, nil)
  end

  @doc "The rows of the composer with its two borders: 3 to 10."
  @spec rows(t()) :: pos_integer()
  def rows(%__MODULE__{input: input}),
    do: min(ExRatatui.textarea_line_count(input), @composer_lines) + 2

  @doc """
  The rows of the composer in `room` rows that it shares with the
  transcript. The composer shrinks, down to one line, before the
  transcript loses its last row. So the drawn screen is the scroll screen
  at 4 rows of room or more.
  """
  @spec rows(t(), integer()) :: pos_integer()
  def rows(composer, room), do: fit(rows(composer), room)

  @doc "The rule of `rows/2` for any box of `rows` rows, such as the `/resume` list."
  @spec fit(pos_integer(), integer()) :: pos_integer()
  def fit(rows, room), do: min(rows, max(room - 1, 3))

  @doc """
  The widgets that draw the composer in `area`: a box with rounded corners
  and no title, and a `›` mark before the first line.
  """
  @spec widgets(t(), Rect.t()) :: [{Textarea.t() | Paragraph.t(), Rect.t()}]
  def widgets(%__MODULE__{input: input}, %Rect{} = area) do
    box = %Block{
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: :dark_gray},
      padding: {@text_column - 1, 0, 0, 0}
    }

    mark = %Paragraph{text: %Line{spans: [%Span{content: "›", style: %Style{fg: :blue}}]}}

    textarea = %Textarea{state: input, cursor_style: %Style{modifiers: [:reversed]}, block: box}

    # The mark is drawn only inside a whole box, never on its border.
    marks =
      if area.width >= @text_column and area.height >= 3,
        do: [{mark, %Rect{x: area.x + @text_column - 2, y: area.y + 1, width: 1, height: 1}}],
        else: []

    [{textarea, area} | marks]
  end

  defp edge?(composer, "up"), do: elem(ExRatatui.textarea_cursor(composer.input), 0) == 0

  defp edge?(composer, "down"),
    do:
      elem(ExRatatui.textarea_cursor(composer.input), 0) ==
        ExRatatui.textarea_line_count(composer.input) - 1

  defp direction("up"), do: :older
  defp direction("down"), do: :newer

  # The draft stays the same while the prompts change.
  defp recalled(%{recall: {_at, _shown, draft, pastes}}, at, text),
    do: {at, text, draft, pastes}

  defp recalled(composer, at, text),
    do: {at, text, ExRatatui.textarea_get_value(composer.input), composer.pastes}

  # A recalled prompt that differs from the text that showed for it is an
  # edit, and it becomes the draft. The cursor stays on the same character
  # of the edit, which comes after the waiting draft and its new line.
  defp keep_edit(%{recall: {_at, shown, _draft, _pastes}} = composer) do
    value = ExRatatui.textarea_get_value(composer.input)

    if value == shown do
      composer
    else
      {parts, pastes} = draft_parts(composer, value)
      text = Enum.join(parts, "\n")
      before_edit = byte_size(text) - byte_size(value)
      cursor = before_edit + offset(value, ExRatatui.textarea_cursor(composer.input))
      cut(%{composer | pastes: pastes, recall: nil}, text, cursor, cursor)
    end
  end

  # The key leaves the recalled prompt: Down at the edge goes to a newer
  # prompt or past the newest, and Up at the edge leaves only when an
  # older prompt exists.
  defp leaves?(%{recall: {at, _shown, _draft, _pastes}} = composer, vm, code),
    do: edge?(composer, code) and (code == "down" or ViewModel.prompt(vm, at, :older) != nil)

  defp leaves?(_composer, _vm, _code), do: false

  # What the user typed, in order: the draft that waits behind a recalled
  # prompt, then `value`, the composer text, which is the draft or the
  # recalled prompt. Empty texts drop, so a join adds one new line between
  # two texts and no other bytes. The pastes of both merge: their marker
  # ids differ, because `count` grows until the composer empties.
  defp draft_parts(composer, value) do
    {_at, _shown, waiting, pastes} = composer.recall || {nil, nil, "", %{}}
    {Enum.reject([waiting, value], &(&1 == "")), Map.merge(pastes, composer.pastes)}
  end

  # `textarea_set_value/2` leaves the cursor at the start; `cut/4` of
  # nothing at the end leaves it at the end.
  defp show(composer, code, text, pastes, recall) do
    if code == "up",
      do: ExRatatui.textarea_set_value(composer.input, text),
      else: cut(composer, text, byte_size(text), byte_size(text))

    %{composer | pastes: pastes, recall: recall}
  end

  # Text never goes inside a marker: it goes after it.
  defp insert(composer, text) do
    composer = out_of_marker(composer)
    ExRatatui.textarea_insert_str(composer.input, text)
    composer
  end

  # A marker is one unit for every key. Backspace in a marker or right
  # after it, and Delete at a marker or in it, remove the whole marker.
  # Left and Right pass over it in one step. Any other key with the cursor
  # inside a marker acts at its end.
  defp widget_key(composer, code) when code in ["backspace", "delete", "left", "right"] do
    case marker_at(composer, code) do
      nil ->
        key(composer, code)

      {value, {start, stop}} when code in ["backspace", "delete"] ->
        pastes = Map.delete(composer.pastes, binary_part(value, start, stop - start))
        cut(%{composer | pastes: pastes}, value, start, stop)

      {value, {_start, stop}} when code == "right" ->
        cut(composer, value, stop, stop)

      {value, {start, _stop}} ->
        cut(composer, value, start, start)
    end
  end

  # A key code with a control character could forge the end of a marker
  # (`Composer.Paste`): the kitty keyboard sequence `ESC [ 1 u` reaches here as the key code
  # U+0001 with no modifier.
  defp widget_key(composer, code) do
    if Wrap.drop_controls(code) == code,
      do: composer |> out_of_marker() |> key(code),
      else: composer
  end

  defp hit?(code, cursor, {start, stop}) when code in ["backspace", "left"],
    do: start < cursor and cursor <= stop

  defp hit?(code, cursor, {start, stop}) when code in ["delete", "right"],
    do: start <= cursor and cursor < stop

  defp hit?(:inside, cursor, {start, stop}), do: start < cursor and cursor < stop

  defp out_of_marker(composer) do
    case marker_at(composer, :inside) do
      nil -> composer
      {value, {_start, stop}} -> cut(composer, value, stop, stop)
    end
  end

  defp word_end(:back, from, {_start, stop}) when from > stop, do: stop
  defp word_end(:back, _from, {start, _stop}), do: start
  defp word_end(:forward, from, {start, _stop}) when from < start, do: start
  defp word_end(:forward, _from, {_start, stop}), do: stop

  defp key(composer, code, modifiers \\ []) do
    ExRatatui.textarea_handle_key(composer.input, code, modifiers)
    composer
  end

  # The composer becomes `value` without the bytes from `from` to `to`,
  # with the cursor at `from`. ExRatatui has no call to set the cursor or to
  # delete a range, and its Right key stops short of zero-width characters
  # at the end of a line. `textarea_insert_str/2` leaves the cursor exactly
  # at the end of the text it inserts, so `cut/4` sets the text after the
  # cursor and inserts the text before it. Linear in the composer text.
  defp cut(composer, value, from, to) do
    ExRatatui.textarea_set_value(composer.input, binary_part(value, to, byte_size(value) - to))
    ExRatatui.textarea_insert_str(composer.input, binary_part(value, 0, from))
    composer
  end

  # The composer text and the byte span of the live marker that `hit?/3` finds
  # for the cursor, or nil: one read and one search, linear in the text.
  defp marker_at(%{pastes: pastes}, _code) when map_size(pastes) == 0, do: nil

  defp marker_at(composer, code) do
    value = ExRatatui.textarea_get_value(composer.input)
    cursor = offset(value, ExRatatui.textarea_cursor(composer.input))

    spans =
      for {at, size} <- :binary.matches(value, Map.keys(composer.pastes)), do: {at, at + size}

    case Enum.find(spans, &hit?(code, cursor, &1)) do
      nil -> nil
      span -> {value, span}
    end
  end

  # The byte offset in `value`, the composer text, of a cursor: one walk of
  # the cursor line turns its column, which counts code points, into bytes.
  defp offset(value, {row, column}) do
    {above, [line | _]} = value |> String.split("\n", parts: row + 2) |> Enum.split(row)
    line_start = Enum.reduce(above, 0, &(byte_size(&1) + 1 + &2))
    column_bytes = line |> String.to_charlist() |> Enum.take(column) |> List.to_string()
    line_start + byte_size(column_bytes)
  end

  defp paste(composer, content) do
    case Paste.marker(content, composer.count + 1) do
      {nil, text} ->
        insert(composer, text)

      {marker, text} ->
        pastes = Map.put(composer.pastes, marker, text)
        insert(%{composer | pastes: pastes, count: composer.count + 1}, marker)
    end
  end
end
