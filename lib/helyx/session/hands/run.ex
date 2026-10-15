defmodule Helyx.Session.Hands.Run do
  @moduledoc false
  # The run of one tool call in its Task of `Helyx.Session.Hands`: the
  # return of the tool checked against its contract, and a raise, a throw,
  # or an exit caught as an error result. The log gets the term.

  alias Helyx.Message.ToolCall

  @spec tool(module(), ToolCall.t(), String.t()) :: {:ok | :error, String.t()}
  def tool(tool, %ToolCall{} = call, cwd) do
    case tool.run(call.arguments, cwd) do
      {:ok, text} when is_binary(text) ->
        {:ok, text}

      {:error, text} when is_binary(text) ->
        {:error, text}

      other ->
        Helyx.Reason.log("tool #{call.name} returned a value outside its contract", other)
        {:error, "the tool returned a value outside its contract"}
    end
  catch
    kind, reason ->
      # The log keeps the stack of a throw or an exit too.
      Helyx.Reason.log("tool #{call.name} failed", {kind, reason, __STACKTRACE__})
      {:error, Helyx.Reason.text(caught(kind, reason, __STACKTRACE__))}
  end

  # A raise is a crash, which gives the message of its exception; a throw
  # or an exit gives its kind and its value.
  defp caught(:error, reason, stacktrace), do: {reason, stacktrace}
  defp caught(kind, reason, _stacktrace), do: {kind, reason}
end
