defmodule Helyx.Provider.Codex.Items do
  @moduledoc false
  # The item translation of `Helyx.Provider.Codex` for the running turn.
  #
  # `open` maps the open tool items to their types, `streamed` holds the
  # ids of the messages whose text came as deltas, and `usage` is the last
  # token usage.
  defstruct open: %{}, streamed: MapSet.new(), usage: %{}

  alias Helyx.HarnessIO
  alias Helyx.Message

  # Item types that run something (see the research note).
  @tool_item_types ~w(commandExecution fileChange mcpToolCall dynamicToolCall collabAgentToolCall
            webSearch imageView imageGeneration)

  def tool_item?(type), do: type in @tool_item_types

  # A notification of the running turn. Gives its events and the items.
  def notification("item/agentMessage/delta", %{"delta" => text, "itemId" => id}, items)
      when is_binary(text) and text != "" do
    {[{:text_delta, text}], %{items | streamed: MapSet.put(items.streamed, id)}}
  end

  def notification(method, %{"delta" => text}, items)
      when method in ["item/reasoning/summaryTextDelta", "item/reasoning/textDelta"] and
             is_binary(text) and text != "",
      do: {[{:thinking_delta, text}], items}

  def notification("item/started", %{"item" => %{"type" => type, "id" => id} = item}, items)
      when type in @tool_item_types do
    {[tool_call(item)], %{items | open: Map.put(items.open, id, type)}}
  end

  # A message whose text came with no delta gives it whole.
  def notification(
        "item/completed",
        %{"item" => %{"type" => "agentMessage", "id" => id, "text" => text}},
        items
      )
      when is_binary(text) and text != "" do
    if MapSet.member?(items.streamed, id),
      do: {[], items},
      else: {[{:text_delta, text}], items}
  end

  # The session closes the assistant message at the first result of one of
  # its calls.
  def notification("item/completed", %{"item" => %{"type" => type, "id" => id} = item}, items)
      when type in @tool_item_types,
      do: {[{:tool_result, id, tool_result(item)}], %{items | open: Map.delete(items.open, id)}}

  def notification("thread/tokenUsage/updated", %{"tokenUsage" => %{"last" => usage}}, items)
      when is_map(usage),
      do: {[], %{items | usage: usage}}

  def notification(_method, _params, items), do: {[], items}

  def terminal(%{"status" => "completed"}, items),
    do: {:done, %{stop_reason: :end_turn, usage: items.usage}}

  def terminal(%{"status" => status} = result, _items),
    do: {:error, {:codex, status, HarnessIO.cap_error(error_message(result))}}

  def error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  def error_message(_map), do: nil

  defp tool_call(%{"type" => type, "id" => id} = item),
    do: {:tool_call, %Message.ToolCall{id: id, name: type, arguments: arguments(item)}}

  defp arguments(%{"type" => "commandExecution"} = item), do: Map.take(item, ["command", "cwd"])

  defp arguments(item),
    do:
      item
      |> Map.drop(["id", "type", "status"])
      |> Map.reject(fn {_key, value} -> value == nil end)

  # A command gives its output; any other tool item gives its fields as
  # JSON.
  defp tool_result(item) do
    text =
      case item do
        %{"type" => "commandExecution", "aggregatedOutput" => out} when is_binary(out) -> out
        %{"type" => "commandExecution"} -> ""
        _ -> JSON.encode!(Map.drop(item, ["id", "type"]))
      end

    failed? =
      item["status"] in ["failed", "declined"] or item["error"] != nil or
        (is_integer(item["exitCode"]) and item["exitCode"] != 0)

    {if(failed?, do: :error, else: :ok), Helyx.Text.truncate(text, :tail)}
  end
end
