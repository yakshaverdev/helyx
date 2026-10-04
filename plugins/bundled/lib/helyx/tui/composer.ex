# ex_ratatui is an optional dependency (ADR 0005): without it
# Helyx.TUI.Composer does not exist.
defmodule Helyx.TUI.Composer.Available do
  @moduledoc false
  use Helyx.TUI.Guard
end

if Helyx.TUI.Composer.Available.available?() do
  defmodule Helyx.TUI.Composer do
    @moduledoc """
    The composer of the TUI: the input widget and the paste markers that
    stand for long pastes. A marker is one unit for every key. The rules
    and their bounds are in `docs/features/multiline-composer.md`.

    The input widget is a mutable `ExRatatui` resource: a composer that
    `edit/3` or `clear/1` returns shares it with the one they got.
    """

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias ExRatatui.Widgets.{Block, Paragraph, Textarea}
    alias Helyx.TUI.{ViewModel, Wrap}

    # The composer shows at most this many lines inside its two borders.
    @composer_lines 8

    # The column of the first character of the composer text: after the
    # border, a space, the `›` mark, and a space.
    @text_column 4

    # A paste of more lines than this shows as one marker.
    @paste_lines 5

    # The last character of a marker, a control character. A paste drops it.
    # A key code with it goes nowhere. ExRatatui does not draw it. So only a
    # marker that the composer made ends with it, and text that looks like a
    # marker is sent as typed.
    @marker_end "\u0001"

    # `pastes` maps the text of each live marker to the full paste it
    # stands for. `count` is the id of the last marker. Both are emptied
    # with the composer, so a marker id is not used twice before then.
    # `recall` is nil while the user edits the draft. While an earlier
    # prompt shows, it holds the position of that prompt's cell and the draft
    # with its pastes, so Down can bring the draft back.
    @enforce_keys [:input]
    defstruct [:input, pastes: %{}, count: 0, recall: nil]

    @type t :: %__MODULE__{
            input: reference(),
            pastes: %{String.t() => String.t()},
            count: non_neg_integer(),
            recall: {non_neg_integer(), String.t(), %{String.t() => String.t()}} | nil
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
    What Enter sends: `:empty`, a `/model` switch with its ref, or the
    message with its paste markers expanded. The composer does not change.
    """
    @spec submit(t()) :: :empty | {:model, String.t()} | {:message, String.t()}
    def submit(%__MODULE__{} = composer) do
      case ExRatatui.textarea_get_value(composer.input) do
        "" -> :empty
        value -> value |> expand(composer.pastes) |> command()
      end
    end

    @doc "True when the composer holds no text."
    @spec empty?(t()) :: boolean()
    def empty?(%__MODULE__{input: input}), do: ExRatatui.textarea_get_value(input) == ""

    @doc "Empties the composer and forgets its pastes."
    @spec clear(t()) :: t()
    def clear(%__MODULE__{} = composer) do
      ExRatatui.textarea_set_value(composer.input, "")
      %{composer | pastes: %{}, count: 0, recall: nil}
    end

    @doc """
    Up or Down: recalls an earlier prompt of the session, the user messages
    in `vm`, when the cursor is on the first row (Up) or the last row (Down).
    Down past the newest prompt brings back the draft. Otherwise the key
    moves the cursor. Up leaves the cursor at the start, Down at the end, so
    the next Up or Down goes on through the prompts.
    """
    @spec recall(t(), ViewModel.t(), String.t()) :: t()
    def recall(%__MODULE__{} = composer, vm, code) when code in ["up", "down"] do
      position = with {at, _value, _pastes} <- composer.recall, do: at

      case edge?(composer, code) && ViewModel.prompt(vm, position, direction(code)) do
        {at, text} -> show(composer, code, clean(text), %{}, recalled(composer, at))
        nil when code == "down" and position != nil -> restore(composer)
        _no_prompt -> widget_key(composer, code)
      end
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
    def rows(composer, room), do: min(rows(composer), max(room - 1, 3))

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
    defp recalled(%{recall: {_at, value, pastes}}, at), do: {at, value, pastes}

    defp recalled(composer, at),
      do: {at, ExRatatui.textarea_get_value(composer.input), composer.pastes}

    defp restore(%{recall: {_at, value, pastes}} = composer),
      do: show(composer, "down", value, pastes, nil)

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

    # A key code with a control character could forge the end of a marker:
    # the kitty keyboard sequence `ESC [ 1 u` reaches here as the key code
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

    defp key(composer, code) do
      ExRatatui.textarea_handle_key(composer.input, code, [])
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

    # The composer text and the byte span of the live marker that `hit?/3`
    # finds for the cursor, or nil. The cursor column counts code points, so
    # one walk of the cursor line turns it into a byte offset. One read of
    # the composer and one search for all markers: linear in the composer
    # text.
    defp marker_at(%{pastes: pastes}, _code) when map_size(pastes) == 0, do: nil

    defp marker_at(composer, code) do
      {row, column} = ExRatatui.textarea_cursor(composer.input)
      value = ExRatatui.textarea_get_value(composer.input)
      {above, [line | _]} = value |> String.split("\n", parts: row + 2) |> Enum.split(row)
      line_start = Enum.reduce(above, 0, &(byte_size(&1) + 1 + &2))

      cursor =
        line |> String.to_charlist() |> Enum.take(column) |> List.to_string() |> byte_size()

      spans =
        for {at, size} <- :binary.matches(value, Map.keys(composer.pastes)), do: {at, at + size}

      case Enum.find(spans, &hit?(code, line_start + cursor, &1)) do
        nil -> nil
        span -> {value, span}
      end
    end

    defp paste(composer, content) do
      text = clean(content)

      case line_count(text) do
        lines when lines > @paste_lines ->
          count = composer.count + 1
          marker = "[Pasted text ##{count}, #{lines} lines]" <> @marker_end
          pastes = Map.put(composer.pastes, marker, text)
          insert(%{composer | pastes: pastes, count: count}, marker)

        _lines ->
          insert(composer, text)
      end
    end

    # A terminal can send a pasted new line as CR. Control characters other
    # than tab and new line drop, as in the transcript, so no text but a
    # marker ends with `@marker_end`.
    defp clean(text), do: text |> String.replace(["\r\n", "\r"], "\n") |> Wrap.drop_controls()

    # A final new line does not start a line.
    defp line_count(text) do
      newlines = length(:binary.matches(text, "\n"))
      if String.ends_with?(text, "\n"), do: newlines, else: newlines + 1
    end

    # One pass, so a marker inside a paste is not expanded.
    defp expand(value, pastes) when map_size(pastes) == 0, do: value

    defp expand(value, pastes),
      do: String.replace(value, Map.keys(pastes), &Map.fetch!(pastes, &1))

    # `/model` is the only command. The rule is on bytes, not on looks; the
    # feature doc's bounds table holds the rule and its limit. A paste keeps
    # tabs and new lines, so `/model<tab>a/b` has a separator. The text is
    # the composer with its paste markers expanded. The ref goes to
    # `Helyx.ModelRef` unsplit, which owns its bounds. The widget holds only
    # valid UTF-8; the `u` flag raises on anything else.
    defp command(text) do
      case Regex.run(~r/\A\s*\/model([\s\p{C}]*)/u, text, return: :index) do
        nil -> {:message, text}
        [{0, head}, {_, 0}] when head < byte_size(text) -> {:model, ""}
        [{0, head}, _] -> {:model, String.trim(binary_part(text, head, byte_size(text) - head))}
      end
    end
  end
end
