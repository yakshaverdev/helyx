defmodule Helyx.Hook.Command.Answer do
  @moduledoc false
  # The JSON on standard input of `Helyx.Hook.Command`, and the answer of
  # a point from the exit and the output of its command
  # (docs/features/command-hook.md).

  alias Helyx.Hook.Command.{Error, Run}

  @no_reason "the command denied the call"
  @added "\n\nThe hook Helyx.Hook.Command added: "

  def default(:before_tool), do: :allow
  def default(:after_tool), do: :keep

  @spec fail(String.t()) :: no_return()
  def fail(text), do: raise(Error, message: text)

  # The call in the field names of the Claude Code hook format. The result
  # text is cut as the hands cut it, so the command reads what the model
  # reads, and the input has a bound.
  def input(point, input) do
    call = %{
      "hook_event_name" => event(point),
      "session_id" => input.session_id,
      "turn_id" => input.turn_id,
      "cwd" => input.cwd,
      "tool_name" => input.tool,
      "tool_input" => input.arguments,
      "tool_use_id" => input.call_id,
      "provider" => input.provider
    }

    call =
      case input do
        %{result: {status, text}} ->
          Map.put(call, "tool_response", %{
            "status" => Atom.to_string(status),
            "text" => Helyx.Message.cut_result(text)
          })

        _before ->
          call
      end

    JSON.encode_to_iodata!(call)
  end

  defp event(:before_tool), do: "PreToolUse"
  defp event(:after_tool), do: "PostToolUse"

  def of({:not_started, reason}, _point, _input),
    do: fail("the command did not start: " <> reason)

  def of(:unreadable, _point, _input), do: fail("the output of the command could not be read")
  def of({:exit, 0, stdout, cut?, _stderr}, point, input), do: stdout(stdout, cut?, point, input)

  def of({:exit, 2, _stdout, _cut?, stderr}, point, input),
    do: block(point, input, [blocked(stderr)])

  def of({:exit, status, _stdout, _cut?, stderr}, _point, _input) do
    case String.trim(valid(stderr)) do
      "" -> fail("the command exited with status #{status}")
      text -> fail("the command exited with status #{status}: " <> text)
    end
  end

  defp blocked(stderr) do
    text = valid(stderr)
    if String.trim(text) == "", do: "the command exited with status 2", else: text
  end

  defp valid(text), do: if(String.valid?(text), do: text, else: String.replace_invalid(text))

  # A deny with the first text, or the result with each text added.
  defp block(:before_tool, _input, [reason | _]), do: {:deny, reason}
  defp block(:after_tool, _input, []), do: :keep

  defp block(:after_tool, %{result: {status, text}}, texts),
    do: {:replace, {status, IO.iodata_to_binary([valid(text) | Enum.map(texts, &[@added, &1])])}}

  # Standard output at exit 0: only an object, first byte `{` after JSON
  # white space, is an answer. The kept head shows plain text even when
  # the rest was dropped; an object or white space with a dropped rest
  # cannot be read whole.
  defp stdout(stdout, cut?, point, input) do
    case {first(stdout), cut?} do
      {?{, false} ->
        decoded(Helyx.JSON.decode(stdout), point, input)

      {nil, false} ->
        default(point)

      {first, true} when first in [?{, nil] ->
        fail("its standard output was over #{Run.max_output_bytes()} bytes")

      {_text, _cut?} ->
        default(point)
    end
  end

  # The first byte that is not JSON white space, or nil.
  defp first(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n], do: first(rest)
  defp first(<<c, _rest::binary>>), do: c
  defp first(""), do: nil

  defp decoded({:ok, %{} = object}, point, input) do
    case shape(point, object) do
      {:ok, answer} -> answer(point, answer, input)
      {:error, text} -> fail("its standard output is not an answer: " <> text)
    end
  end

  defp decoded(_other, _point, _input), do: fail("its standard output is not a JSON object")

  defp answer(:before_tool, answer, _input), do: answer
  defp answer(:after_tool, texts, input), do: block(:after_tool, input, texts)

  defp shape(:before_tool, object) do
    with {:ok, specific} <- specific(object),
         :ok <- no_stop(object),
         :ok <- absent(specific, "updatedInput"),
         {:ok, decision} <- one_of(specific, "permissionDecision", ["allow", "deny"]),
         {:ok, why} <- text(specific, "permissionDecisionReason"),
         {:ok, old} <- one_of(object, "decision", ["approve", "block"]),
         {:ok, reason} <- text(object, "reason"),
         do: {:ok, permission(decision, why, old, reason)}
  end

  defp shape(:after_tool, object) do
    with {:ok, specific} <- specific(object),
         :ok <- no_stop(object),
         :ok <- absent(specific, "updatedMCPToolOutput"),
         {:ok, decision} <- one_of(object, "decision", ["block"]),
         {:ok, reason} <- text(object, "reason"),
         {:ok, context} <- text(specific, "additionalContext") do
      {:ok, for(text <- [decision && reason, context], is_binary(text), do: text)}
    end
  end

  # A deny in either field wins; an allow takes the reason of its field.
  defp permission("deny", why, _old, _reason), do: {:deny, why || @no_reason}
  defp permission(_decision, _why, "block", reason), do: {:deny, reason || @no_reason}
  defp permission("allow", why, _old, _reason) when why != nil, do: {:allow, why}
  defp permission(_decision, _why, "approve", reason) when reason != nil, do: {:allow, reason}
  defp permission(_decision, _why, _old, _reason), do: :allow

  defp specific(object) do
    case object["hookSpecificOutput"] do
      nil -> {:ok, %{}}
      %{} = specific -> {:ok, specific}
      _other -> {:error, "hookSpecificOutput is not an object"}
    end
  end

  # `continue: false` stops the agent in the Claude Code format; a Helyx
  # hook answers for one call only.
  defp no_stop(object) do
    case object["continue"] do
      value when value in [nil, true] -> :ok
      false -> {:error, "continue false asks to stop the agent, which a hook cannot"}
      _other -> {:error, "continue is not a boolean"}
    end
  end

  defp absent(map, key) do
    if map[key] == nil, do: :ok, else: {:error, key <> " asks for what a Helyx hook does not do"}
  end

  defp one_of(map, key, values) do
    case map[key] do
      nil -> {:ok, nil}
      value -> if value in values, do: {:ok, value}, else: {:error, key <> " has another value"}
    end
  end

  # An empty text counts as missing.
  defp text(map, key) do
    case map[key] do
      value when value in [nil, ""] -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, key <> " is not a string"}
    end
  end
end
