defmodule Helyx.TUI.CallLine do
  @moduledoc """
  The one line of a tool call in a tool cell of `Helyx.TUI.ViewModel`,
  made once with the cell.
  """

  alias Helyx.Message

  # The cut of a tool call line (`cut_line/1`).
  @render_max_bytes 8_192

  @doc """
  The line of a tool call: its name, then each argument as `key=value`,
  with the key raw and the value through `inspect/1`, cut at
  #{@render_max_bytes} bytes. The name and each key are cut before they join
  the line, the walk over the arguments stops once the line is over the cut,
  and the line is cut before its newlines become "␤". The fold makes the line
  with the tool cell, and not on each frame. A call of the agent tool with a
  string `description` is `⚙ agent <child id>: <description>`, with the
  same cuts; the child id comes from the id of the session and of the call
  (`Helyx.Sessions.child_id/2`, `docs/features/agent-tool.md`), and with
  no session id the line has none. A call of the skill tool with a string
  `name` is `⚙ skill: <name>`, with the same cuts (`docs/features/skills.md`).
  """
  @spec line(Message.ToolCall.t(), String.t() | nil) :: String.t()
  def line(call, session_id \\ nil)

  def line(%Message.ToolCall{name: "agent", arguments: %{"description" => text}} = call, id)
      when is_binary(text),
      do: one_line("⚙ agent#{child(id, call.id)}: " <> text)

  def line(%Message.ToolCall{name: "skill", arguments: %{"name" => name}}, _session_id)
      when is_binary(name),
      do: one_line("⚙ skill: " <> name)

  def line(%Message.ToolCall{name: name, arguments: arguments}, _session_id) do
    ("⚙ " <> cut_line(name))
    |> join_arguments(arguments |> :maps.iterator() |> :maps.next())
    |> one_line()
  end

  defp child(nil, _call_id), do: ""
  defp child(session_id, call_id), do: " " <> Helyx.Sessions.child_id(session_id, call_id)

  defp one_line(line), do: line |> cut_line() |> String.replace("\n", "␤") |> cut_line()

  # `:maps.next/1` walks the map lazily, so a call of many keys costs no
  # more than the keys up to the cut.
  defp join_arguments(line, :none), do: line
  defp join_arguments(line, _next) when byte_size(line) > @render_max_bytes, do: line

  defp join_arguments(line, {key, value, iterator}),
    do: join_arguments("#{line} #{cut_line("#{key}")}=#{inspect(value)}", :maps.next(iterator))

  # A tool call line holds model text, and `inspect/1` escapes a character
  # to up to four times its bytes (a control or invalid byte renders as
  # `\x01`), so the line is cut at `@render_max_bytes`; a character cut in
  # half is dropped (`Helyx.Text.cap/3`).
  defp cut_line(text), do: Helyx.Text.cap(text, @render_max_bytes, :head)
end
