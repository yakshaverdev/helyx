defmodule Helyx.Session.Hands.Run do
  @moduledoc false
  # The run of one tool call or one hook in its Task of
  # `Helyx.Session.Hands`: the return checked against its contract, the UI
  # blocks of a tool's return with `Helyx.UIBlock.check_list/1`
  # (docs/features/ui-blocks.md), and a raise, a throw, or an exit caught.
  # The log gets the kind of the term.

  alias Helyx.Message.ToolCall

  @spec tool(module(), ToolCall.t(), String.t()) ::
          {:ok | :error, String.t()} | {:ok | :error, String.t(), [Helyx.UIBlock.t()]}
  def tool(tool, %ToolCall{} = call, cwd) do
    case tool.run(call.arguments, cwd) do
      {status, text} = result when status in [:ok, :error] and is_binary(text) ->
        result

      {status, text, blocks} = other when status in [:ok, :error] and is_binary(text) ->
        case Helyx.UIBlock.check_list(blocks) do
          {:ok, []} -> {status, text}
          {:ok, blocks} -> {status, text, blocks}
          :error -> outside(call, other)
        end

      other ->
        outside(call, other)
    end
  catch
    kind, reason ->
      caught = caught(kind, reason, __STACKTRACE__)
      Helyx.Reason.log("tool #{call.name} failed", caught)
      {:error, Helyx.Reason.text(caught)}
  end

  # A hook at `point` (docs/features/hooks.md): `{:answer, answer}` for an
  # answer of the point, else `{:failed, how}`.
  @spec hook(module(), Helyx.Hook.point(), map()) :: {:answer, term()} | {:failed, String.t()}
  def hook(module, point, input) do
    answer = apply(module, point, [input])

    if answer?(point, answer) do
      {:answer, answer}
    else
      Helyx.Reason.log("hook #{inspect(module)} returned a value outside its contract", answer)
      {:failed, "it returned a value outside its contract"}
    end
  catch
    kind, reason ->
      caught = caught(kind, reason, __STACKTRACE__)
      Helyx.Reason.log("hook #{inspect(module)} failed", caught)
      {:failed, Helyx.Reason.text(caught)}
  end

  defp answer?(:before_tool, :allow), do: true
  defp answer?(:before_tool, {:allow, reason}), do: text?(reason)
  defp answer?(:before_tool, {:deny, reason}), do: text?(reason)
  defp answer?(:after_tool, :keep), do: true

  defp answer?(:after_tool, {:replace, {status, text}}) when status in [:ok, :error],
    do: text?(text)

  # The text of a continue is a user message: the bound of a client text,
  # checked before its UTF-8.
  defp answer?(:before_settle, :settle), do: true

  defp answer?(:before_settle, {:continue, text}) when is_binary(text),
    do: Helyx.Session.Input.text(text) == :ok

  defp answer?(_point, _answer), do: false

  defp text?(value), do: is_binary(value) and String.valid?(value)

  defp outside(call, other) do
    Helyx.Reason.log("tool #{call.name} returned a value outside its contract", other)
    {:error, "the tool returned a value outside its contract"}
  end

  # A raise is a crash, which gives the message of its exception; a throw
  # or an exit gives its kind and its value.
  defp caught(:error, reason, stacktrace), do: {reason, stacktrace}
  defp caught(kind, reason, _stacktrace), do: {kind, reason}
end
