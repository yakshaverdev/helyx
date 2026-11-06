defmodule Helyx.Session.Hands.Run do
  @moduledoc false
  # The run of one tool call in its Task of `Helyx.Session.Hands`: the
  # return of the tool checked against its contract, its UI blocks with
  # `Helyx.UIBlock.check_list/1` (docs/features/ui-blocks.md), and a raise,
  # a throw, or an exit caught as an error result. The log gets the kind of
  # the term.

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

  defp outside(call, other) do
    Helyx.Reason.log("tool #{call.name} returned a value outside its contract", other)
    {:error, "the tool returned a value outside its contract"}
  end

  # A raise is a crash, which gives the message of its exception; a throw
  # or an exit gives its kind and its value.
  defp caught(:error, reason, stacktrace), do: {reason, stacktrace}
  defp caught(kind, reason, _stacktrace), do: {kind, reason}
end
