# ex_ratatui is an optional dependency (ADR 0005): without it
# Helyx.TUI.Composer does not exist.
defmodule Helyx.TUI.Composer.Available do
  @moduledoc false
  # The recompile hook of ADR 0005. Mix reaches a stale source only through a
  # module the source defines, so each guarded file has its own.

  @available Code.ensure_loaded?(ExRatatui.App)

  @spec available?() :: boolean()
  def available?, do: @available

  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?, do: Code.ensure_loaded?(ExRatatui.App) != @available
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

    alias ExRatatui.Style
    alias ExRatatui.Widgets.{Block, Textarea}
    alias Helyx.TUI.Wrap

    # The composer shows at most this many lines inside its two borders.
    @composer_lines 8

    # A paste of more lines than this shows as one marker.
    @paste_lines 5

    # The last character of a marker, a control character. A paste drops it.
    # A key code with it goes nowhere. ExRatatui does not draw it. So only a
    # marker that the composer made ends with it, and text that looks like a
    # marker is sent as typed.
    @marker_end "\u0001"

    # `pastes` maps marker text to the full paste it stands for. It is
    # emptied with the composer, so a marker id is the map size plus one.
    @enforce_keys [:input]
    defstruct [:input, pastes: %{}]

    @type t :: %__MODULE__{input: reference(), pastes: %{String.t() => String.t()}}

    @doc "An empty composer."
    @spec new() :: t()
    def new, do: %__MODULE__{input: ExRatatui.textarea_new()}

    @doc """
    Applies event text: `:insert` inserts it, `:key` sends a key code to
    the widget, and `:paste` inserts a paste.

    The only path by which event text reaches the widget. The widget raises
    `ArgumentError` on text that is not valid UTF-8, so such text returns
    `{:error, :invalid_utf8}` and the composer does not change. Reject, do
    not repair: a silent replacement would send text the user did not type.
    """
    @spec edit(t(), :insert | :key | :paste, term()) :: {:ok, t()} | {:error, :invalid_utf8}
    def edit(%__MODULE__{} = composer, op, text) do
      if is_binary(text) and String.valid?(text),
        do: {:ok, apply_edit(op, composer, text)},
        else: {:error, :invalid_utf8}
    end

    defp apply_edit(:insert, composer, text), do: insert(composer, text)
    defp apply_edit(:key, composer, code), do: widget_key(composer, code)
    defp apply_edit(:paste, composer, content), do: paste(composer, content)

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

    @doc "Empties the composer and forgets its pastes."
    @spec clear(t()) :: t()
    def clear(%__MODULE__{} = composer) do
      ExRatatui.textarea_set_value(composer.input, "")
      %{composer | pastes: %{}}
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

    @doc "The widget that draws the composer."
    @spec widget(t()) :: Textarea.t()
    def widget(%__MODULE__{input: input}) do
      %Textarea{
        state: input,
        cursor_style: %Style{modifiers: [:reversed]},
        block: %Block{borders: [:all], title: "prompt"}
      }
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
          cut(composer, value, start, stop)

        {value, {_start, stop}} when code == "right" ->
          cut(composer, value, stop, stop)

        {value, {start, _stop}} ->
          cut(composer, value, start, start)
      end
    end

    # A key code with a control character could forge the end of a marker.
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

    # A terminal can send a pasted new line as CR. Control characters other
    # than tab and new line drop, as in the transcript.
    defp paste(composer, content) do
      text = content |> String.replace(["\r\n", "\r"], "\n") |> Wrap.drop_controls()

      case line_count(text) do
        lines when lines > @paste_lines ->
          marker =
            "[Pasted text ##{map_size(composer.pastes) + 1}, #{lines} lines]" <> @marker_end

          insert(%{composer | pastes: Map.put(composer.pastes, marker, text)}, marker)

        _lines ->
          insert(composer, text)
      end
    end

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
      case Regex.run(~r/\A[\s\p{C}]*\/model([\s\p{C}]*)/u, text, return: :index) do
        nil -> {:message, text}
        [{0, head}, {_, 0}] when head < byte_size(text) -> {:model, ""}
        [{0, head}, _] -> {:model, String.trim(binary_part(text, head, byte_size(text) - head))}
      end
    end
  end
end
