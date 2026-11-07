defmodule Helyx.Session.HookEntry do
  @moduledoc false
  # The `hook` entry of the session file (docs/features/hooks.md, "The
  # `hook` entry of the session file"): its encode for the writer and its
  # shape check for the reader. A resume reads nothing from it.

  @points ~w(before_tool after_tool before_settle)
  @answers ~w(allow deny replace continue failed)
  # The most bytes of a reason and of the JSON of the arguments.
  @max_bytes 4_096

  # The answer and the reason of an outcome of a hook, the reason cut.
  defp answer({:answer, :allow}), do: {"allow", nil}
  defp answer({:answer, {:allow, reason}}), do: {"allow", cut_text(reason)}
  defp answer({:answer, {:deny, reason}}), do: {"deny", cut_text(reason)}
  defp answer({:answer, {:replace, _result}}), do: {"replace", nil}
  defp answer({:answer, {:continue, _text}}), do: {"continue", nil}
  defp answer({:failed, how}), do: {"failed", cut_text(how)}

  defp cut_text(text), do: text |> cut() |> elem(0)

  # A valid text cut to at most #{@max_bytes} bytes at a character
  # boundary, and whether it was cut.
  def cut(text) when byte_size(text) <= @max_bytes, do: {text, false}
  def cut(text), do: {text |> binary_part(0, @max_bytes) |> String.replace_invalid(""), true}

  def entry(turn_id, record) do
    {answer, reason} = answer(record.outcome)

    entry = %{
      "type" => "hook",
      "point" => Atom.to_string(record.point),
      "turn_id" => turn_id,
      "call_id" => record.call_id,
      "hook" => inspect(record.hook),
      "answer" => answer,
      "reason" => reason
    }

    case record.call do
      nil ->
        entry

      call ->
        Map.merge(entry, %{
          "tool" => call.tool,
          "arguments" => call.arguments,
          "arguments_cut" => call.arguments_cut
        })
    end
  end

  # The shape that `entry/2` writes; the reader drops any other.
  def valid?(%{"point" => point, "answer" => answer, "hook" => hook} = entry)
      when point in @points and answer in @answers and is_binary(hook) do
    is_binary(entry["turn_id"]) and optional_text?(entry["call_id"]) and
      optional_text?(entry["reason"]) and bounded?(entry["reason"]) and call?(entry)
  end

  def valid?(_entry), do: false

  defp call?(%{"tool" => tool, "arguments" => arguments, "arguments_cut" => cut}),
    do: is_binary(tool) and is_binary(arguments) and bounded?(arguments) and is_boolean(cut)

  defp call?(entry), do: not Enum.any?(~w(tool arguments arguments_cut), &is_map_key(entry, &1))

  defp optional_text?(value), do: is_nil(value) or is_binary(value)
  defp bounded?(value), do: is_nil(value) or byte_size(value) <= @max_bytes
end
