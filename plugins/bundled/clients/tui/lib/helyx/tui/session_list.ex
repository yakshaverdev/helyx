defmodule Helyx.TUI.SessionList do
  @moduledoc false
  # The list of `/resume` (docs/features/tui-session-switch.md): the
  # other sessions of the folder, its keys, and its widget. It owns the
  # line of a session, which `helyx --list` prints too
  # (docs/features/session-list.md).

  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias ExRatatui.Widgets.List, as: Rows
  alias Helyx.Session.File.Scan
  alias Helyx.TUI.Composer

  # The widths of the file text on a line, in code points.
  @prompt_width 60
  @model_width 40
  @folder_width 80

  @empty "no other session in this folder"

  @enforce_keys [:items]
  defstruct [:items, selected: 0]

  @type t :: %__MODULE__{items: [{String.t(), String.t()}], selected: non_neg_integer()}

  # Without a sessions directory nothing is saved, so no session is listed.
  @spec new(Path.t() | nil, Path.t(), String.t()) :: t()
  def new(nil, _cwd, _current), do: %__MODULE__{items: []}

  def new(dir, cwd, current) do
    items = for s <- Scan.list(dir, cwd), s.id != current, do: {s.id, line(s, false)}
    %__MODULE__{items: items}
  end

  # A key of the open list: Up and Down move the selection, Enter picks,
  # Escape closes; any other key does nothing.
  @spec key(t(), String.t()) :: {:move, t()} | {:pick, String.t()} | :close | :none
  def key(%__MODULE__{selected: at} = list, "up"), do: {:move, %{list | selected: max(at - 1, 0)}}

  def key(%__MODULE__{items: items, selected: at} = list, "down"),
    do: {:move, %{list | selected: min(at + 1, max(length(items) - 1, 0))}}

  def key(%__MODULE__{items: []}, "enter"), do: :close

  def key(%__MODULE__{items: items, selected: at}, "enter"),
    do: {:pick, elem(Enum.at(items, at), 0)}

  def key(_list, "esc"), do: :close
  def key(_list, _code), do: :none

  # The rows in `room` rows that the list shares with the transcript, with
  # the two borders, by the rule of the composer.
  @spec rows(t(), integer()) :: pos_integer()
  def rows(%__MODULE__{items: items}, room), do: Composer.fit(max(length(items), 1) + 2, room)

  @spec widget(t()) :: Rows.t() | Paragraph.t()
  def widget(%__MODULE__{items: []}), do: %Paragraph{text: @empty, block: box()}

  def widget(%__MODULE__{items: items, selected: at}) do
    %Rows{
      items: Enum.map(items, &elem(&1, 1)),
      selected: at,
      highlight_style: %Style{modifiers: [:reversed]},
      block: box()
    }
  end

  defp box,
    do: %Block{borders: [:all], border_type: :rounded, border_style: %Style{fg: :dark_gray}}

  @doc """
  The line of a session: the id, the time of the last activity, the folder
  with `all?`, the model, and the first prompt. The folder, the model, and
  the prompt come from the file, so each gets the clean pass before it
  reaches the terminal, then its width.
  """
  @spec line(Scan.Summary.t(), boolean()) :: String.t()
  def line(summary, all?) do
    folder = if all?, do: [folder(summary.cwd)], else: []
    model = summary.model |> one_line() |> take(@model_width)
    prompt = summary.prompt |> one_line() |> take(@prompt_width)
    Enum.join([summary.id, time(summary.mtime)] ++ folder ++ [model, prompt], "  ")
  end

  @doc "A folder from a file, cleaned, as its last #{@folder_width} code points: the end tells folders apart."
  @spec folder(String.t()) :: String.t()
  def folder(cwd), do: cwd |> one_line() |> take(-@folder_width)

  @doc """
  The clean pass of a text for the terminal: a whitespace run becomes one
  space, whitespace at the ends goes, and a control or format character or
  a byte that is not UTF-8 becomes `?`. The result has no length bound.
  """
  @spec one_line(String.t()) :: String.t()
  def one_line(text) do
    text
    |> String.replace_invalid("?")
    |> String.split()
    |> Enum.join(" ")
    |> String.replace(~r/\p{C}/u, "?")
  end

  # A width counts code points, not graphemes: one grapheme can hold any
  # number of combining marks. A negative count takes the end.
  defp take(text, count), do: text |> String.to_charlist() |> Enum.take(count) |> List.to_string()

  defp time(mtime) do
    mtime
    |> :calendar.system_time_to_local_time(:second)
    |> NaiveDateTime.from_erl!()
    |> NaiveDateTime.to_string()
  end
end
