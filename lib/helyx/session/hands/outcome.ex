defmodule Helyx.Session.Hands.Outcome do
  @moduledoc false
  # The message to the session for the end of a Task of `Helyx.Session.Hands`: a
  # tool result, the end of a background run, the answer of a `before_settle`
  # chain, the decision of an approval chain, or the end of the provider
  # process. Every result and background end leaves the hands through here, so
  # text is made valid and cut to the limit once.

  alias Helyx.Session.Background
  alias Helyx.Session.Hands.Entry

  def of(%Entry{kind: {:call, call_id}, turn_id: turn_id}, result),
    do: tool_result(turn_id, call_id, result)

  # The start answer of a background run is the result of its call.
  def of(%Entry{kind: {:placed, call_id, _place}, turn_id: turn_id}, result),
    do: tool_result(turn_id, call_id, result)

  def of(%Entry{kind: {:run, id}}, result),
    do: {:background_end, Background.end_message(id, checked(result))}

  def of(%Entry{kind: {:settle, ref}}, answer), do: {:settle_answer, ref, answer}

  # A deny reason is cut as a result.
  def of(%Entry{kind: {:approval, call_id}, turn_id: turn_id}, result),
    do: {:approval_result, turn_id, call_id, decision(result)}

  def of(%Entry{kind: :provider, task: task}, result),
    do: {:provider_down, task.pid, down_reason(result)}

  # The result of a tool call that started no Task, such as an unknown tool.
  def tool_result(turn_id, call_id, result),
    do: {:tool_result, turn_id, call_id, checked(result)}

  # The handles went to the log when they became unconfirmed.
  def refusal, do: unreleased() <> "; the call was not run"

  def unreleased, do: "a resource from an earlier call could not be released"

  # A kill is the armed kill of a request that got no answer in time. The loop
  # ends with `{:shutdown, reason}` (L1). An unconfirmed handle joins
  # `unconfirmed`, which refuses the next start. `Helyx.Reason` caps the
  # integers of the text.
  defp down_reason({:exit, :killed}), do: :provider_timeout
  defp down_reason({:exit, {:shutdown, reason}}), do: reason
  defp down_reason({:exit, reason}), do: {:task_exit, reason}
  defp down_reason({:error, _text} = error), do: error

  defp decision(:allow), do: :allow
  defp decision({:deny, text}), do: {:deny, Helyx.Message.cut_result(text)}

  defp decision({:exit, reason}) do
    Helyx.Reason.log("approval chain crashed", reason)
    decision({:deny, "the approval chain crashed: " <> Helyx.Reason.text(reason)})
  end

  # A crash of the Task: the log gets the kind of its reason, the result its
  # text.
  defp checked({:exit, reason}) do
    Helyx.Reason.log("tool crashed", reason)
    checked({:error, "tool crashed: " <> Helyx.Reason.text(reason)})
  end

  # The start answer of a background run, with the status that the
  # `after_tool` hooks left (docs/features/hooks.md).
  defp checked({:started, result, pid}), do: {:started, checked(result), pid}

  # The ok, error, crash, refusal, and catch paths alike.
  defp checked({status, text}), do: {status, Helyx.Message.cut_result(text)}

  # A result with the UI blocks of the tool (docs/features/ui-blocks.md).
  defp checked({status, text, blocks}), do: {status, Helyx.Message.cut_result(text), blocks}
end
