defmodule Helyx.Session.Hands.Outcome do
  @moduledoc false
  # The message to the session for the end of a Task of
  # `Helyx.Session.Hands`: a tool result, the end of a background run, the
  # answer of a `before_settle` chain, or the end of the provider process.
  # Every result and background end leaves the hands through here, so text
  # is made valid and cut to the limit once.

  alias Helyx.Session.Background

  def of(_turn_id, :provider, pid, result), do: {:provider_down, pid, down_reason(result)}

  def of(_turn_id, {:background, id}, _pid, result),
    do: {:background_end, Background.end_message(id, checked(result))}

  # The answer of a `before_settle` chain, to the request `ref` of the
  # session (`Helyx.Session.Hands.Settle`).
  def of(_turn_id, {:settle, ref}, _pid, answer), do: {:settle_answer, ref, answer}

  def of(turn_id, id, _pid, result), do: of(turn_id, id, result)

  def of(turn_id, call_id, result), do: {:tool_result, turn_id, call_id, checked(result)}

  # The handles went to the log when they became unconfirmed.
  def refusal, do: unreleased() <> "; the call was not run"

  def unreleased, do: "a resource from an earlier call could not be released"

  # The reason of a provider process's end. `Helyx.Reason` caps its
  # integers when it makes the text. A kill is the armed
  # kill of a request that got no answer in time. The loop ends with
  # `{:shutdown, reason}` (L1). An unconfirmed handle joins `unconfirmed`,
  # which refuses the next start.
  defp down_reason({:exit, :killed}), do: :provider_timeout
  defp down_reason({:exit, {:shutdown, reason}}), do: reason
  defp down_reason({:exit, reason}), do: {:task_exit, reason}
  defp down_reason({:error, _text} = error), do: error

  # A crash of the Task: the log gets the kind of its reason, the result its text.
  defp checked({:exit, reason}) do
    Helyx.Reason.log("tool crashed", reason)
    checked({:error, "tool crashed: " <> Helyx.Reason.text(reason)})
  end

  # The start answer of a background run, with the status that the
  # `after_tool` hooks left (docs/features/hooks.md).
  defp checked({:started, result, pid}), do: {:started, checked(result), pid}

  # The ok, error, crash, refusal, and catch paths alike.
  defp checked({status, text}), do: {status, Helyx.Message.cut_result(text)}
end
