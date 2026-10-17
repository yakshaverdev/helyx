defmodule Helyx.TUI.Composer.Paste do
  @moduledoc false
  # The paste rule of `Helyx.TUI.Composer`: the text that a paste becomes,
  # the marker that stands for a long paste, and the expansion at a send.
  # The rules are in `docs/features/multiline-composer.md`.

  alias Helyx.TUI.Wrap

  # A paste of more lines than this shows as one marker.
  @paste_lines 5

  # The last character of a marker, a control character. A paste drops it.
  # A key code with it goes nowhere. ExRatatui does not draw it. So only a
  # marker that the composer made ends with it, and text that looks like a
  # marker is sent as typed.
  @marker_end "\u0001"

  @doc "The cleaned paste, and its marker with the id `id`, or nil for a short paste."
  @spec marker(String.t(), pos_integer()) :: {String.t() | nil, String.t()}
  def marker(content, id) do
    text = clean(content)

    case line_count(text) do
      lines when lines > @paste_lines ->
        {"[Pasted text ##{id}, #{lines} lines]" <> @marker_end, text}

      _lines ->
        {nil, text}
    end
  end

  # A terminal can send a pasted new line as CR. Control characters other
  # than tab and new line drop, as in the transcript, so no text but a
  # marker ends with `@marker_end`.
  @doc "The text of a paste: LF for each new line, and no control characters but tab and LF."
  @spec clean(String.t()) :: String.t()
  def clean(text), do: text |> String.replace(["\r\n", "\r"], "\n") |> Wrap.drop_controls()

  # One pass, so a marker inside a paste is not expanded.
  @doc "`value` with each live marker of `pastes` replaced by its paste."
  @spec expand(String.t(), %{String.t() => String.t()}) :: String.t()
  def expand(value, pastes) when map_size(pastes) == 0, do: value

  def expand(value, pastes),
    do: String.replace(value, Map.keys(pastes), &Map.fetch!(pastes, &1))

  # A final new line does not start a line.
  defp line_count(text) do
    newlines = length(:binary.matches(text, "\n"))
    if String.ends_with?(text, "\n"), do: newlines, else: newlines + 1
  end
end
