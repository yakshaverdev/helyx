defmodule Helyx.Session.Hands.Term.Record do
  @moduledoc false
  # The record of a hook answer of a hands term (`Helyx.Session.Hands.Hooks`):
  # the point, the call id, the hook's registration id, the outcome, the record
  # of the call (`Helyx.Session.HookEntry`), and the task that ran it. The `pid`
  # of the hands does not cross; the task id does.

  alias Helyx.{Hook, Message}
  alias Helyx.Session.Hands.Term.Data
  alias Helyx.Session.{HookEntry, Input}

  @doc false
  # The record of a hook answer (`Helyx.Session.Hands.Hooks.answer/3`): the
  # point, the call id, the hook's registration id, the outcome, the record of
  # the call (`Helyx.Session.HookEntry`), and the task that ran it. The `pid`
  # of the hands does not cross; the task id does. A reason and a failure text
  # are any valid UTF-8: the session cuts them for the file. A replace text is
  # a tool result text, so the check cuts it.
  @spec check(term()) :: {:ok, map()} | :error
  def check(
        %{point: point, call_id: call_id, hook: hook, outcome: outcome, call: call, task: task} =
          record
      ) do
    with true <- map_size(record) == 6,
         true <- point in Hook.points(),
         true <- hook?(hook, point, call_id),
         {:ok, outcome} <- checked_outcome(point, outcome),
         true <- call_record?(call),
         true <- is_nil(task) or Data.id?(task) do
      {:ok, %{record | outcome: outcome}}
    else
      _ -> :error
    end
  end

  def check(_record), do: :error

  @spec record?(term()) :: boolean()
  def record?(record), do: match?({:ok, _}, check(record))

  defp hook?(hook, point, call_id) do
    Data.plugin?(hook) and
      if(point == :before_settle,
        do: is_nil(call_id),
        else: Data.call_id?(call_id)
      )
  end

  defp checked_outcome(point, {:failed, how}) do
    if point in Hook.points() and Data.text?(how), do: {:ok, {:failed, how}}, else: :error
  end

  defp checked_outcome(:before_tool, {:answer, :allow}), do: {:ok, {:answer, :allow}}

  defp checked_outcome(:before_tool, {:answer, {allow, text}}) when allow in [:allow, :deny] do
    if Data.text?(text), do: {:ok, {:answer, {allow, text}}}, else: :error
  end

  defp checked_outcome(:after_tool, {:answer, {:replace, {status, text}}})
       when status in [:ok, :error] do
    if Data.text?(text),
      do: {:ok, {:answer, {:replace, {status, Message.cut_result(text)}}}},
      else: :error
  end

  defp checked_outcome(:before_settle, {:answer, {:continue, text}}) do
    if is_binary(text) and Input.text(text) == :ok,
      do: {:ok, {:answer, {:continue, text}}},
      else: :error
  end

  defp checked_outcome(_point, _outcome), do: :error

  defp call_record?(nil), do: true

  defp call_record?(%{tool: tool, arguments: arguments, arguments_cut: cut} = call) do
    map_size(call) == 3 and Data.text?(tool) and arguments?(arguments) and is_boolean(cut)
  end

  defp call_record?(_call), do: false

  # The JSON of a hook's arguments is cut with `Helyx.Session.HookEntry.cut/1`
  # when the call Task makes the record, so a text that would be cut is over
  # the bound.
  defp arguments?(text), do: Data.text?(text) and elem(HookEntry.cut(text), 1) == false

  @spec record_to_map(map()) :: map()
  def record_to_map(record) do
    %{
      "point" => Atom.to_string(record.point),
      "call_id" => record.call_id,
      "hook" => record.hook,
      "outcome" => outcome_to_map(record.outcome),
      "call" => call_record_to_map(record.call),
      "task" => record.task
    }
  end

  defp outcome_to_map({:answer, :allow}), do: %{"kind" => "allow"}
  defp outcome_to_map({:answer, {:allow, text}}), do: %{"kind" => "allow", "text" => text}
  defp outcome_to_map({:answer, {:deny, text}}), do: %{"kind" => "deny", "text" => text}

  defp outcome_to_map({:answer, {:replace, {status, text}}}),
    do: %{"kind" => "replace", "status" => Atom.to_string(status), "text" => text}

  defp outcome_to_map({:answer, {:continue, text}}),
    do: %{"kind" => "continue", "text" => text}

  defp outcome_to_map({:failed, how}), do: %{"kind" => "failed", "text" => how}

  defp call_record_to_map(nil), do: nil

  defp call_record_to_map(call),
    do: %{
      "tool" => call.tool,
      "arguments" => call.arguments,
      "arguments_cut" => call.arguments_cut
    }

  @spec to_record(term()) :: {:ok, map()} | :error
  def to_record(
        %{
          "point" => point,
          "call_id" => call_id,
          "hook" => hook,
          "outcome" => outcome,
          "call" => call,
          "task" => task
        } = map
      ) do
    with 6 <- map_size(map),
         {:ok, point} <- point(point),
         {:ok, outcome} <- to_outcome(outcome),
         {:ok, call} <- to_call_record(call),
         {:ok, record} <-
           check(%{
             point: point,
             call_id: call_id,
             hook: hook,
             outcome: outcome,
             call: call,
             task: task
           }) do
      {:ok, record}
    else
      _ -> :error
    end
  end

  def to_record(_map), do: :error

  defp point("before_tool"), do: {:ok, :before_tool}
  defp point("after_tool"), do: {:ok, :after_tool}
  defp point("before_settle"), do: {:ok, :before_settle}
  defp point(_point), do: :error

  defp to_outcome(%{"kind" => "allow"} = map) when map_size(map) == 1,
    do: {:ok, {:answer, :allow}}

  defp to_outcome(%{"kind" => "allow", "text" => text} = map) when map_size(map) == 2,
    do: {:ok, {:answer, {:allow, text}}}

  defp to_outcome(%{"kind" => "deny", "text" => text} = map) when map_size(map) == 2,
    do: {:ok, {:answer, {:deny, text}}}

  defp to_outcome(%{"kind" => "replace", "status" => status, "text" => text} = map)
       when map_size(map) == 3 do
    with {:ok, status} <- status(status), do: {:ok, {:answer, {:replace, {status, text}}}}
  end

  defp to_outcome(%{"kind" => "continue", "text" => text} = map) when map_size(map) == 2,
    do: {:ok, {:answer, {:continue, text}}}

  defp to_outcome(%{"kind" => "failed", "text" => text} = map) when map_size(map) == 2,
    do: {:ok, {:failed, text}}

  defp to_outcome(_outcome), do: :error

  defp status("ok"), do: {:ok, :ok}
  defp status("error"), do: {:ok, :error}
  defp status(_status), do: :error

  defp to_call_record(nil), do: {:ok, nil}

  defp to_call_record(%{"tool" => tool, "arguments" => arguments, "arguments_cut" => cut} = map)
       when map_size(map) == 3,
       do: {:ok, %{tool: tool, arguments: arguments, arguments_cut: cut}}

  defp to_call_record(_call), do: :error
end
