defmodule Helyx.Provider.Codex.Items do
  @moduledoc false
  # The item translation of `Helyx.Provider.Codex` for the running turn.
  #
  # `open` maps the open tool items to their types, and `streamed` holds
  # the ids of the messages whose text came as deltas. `usage` is the sum
  # of the thread's model calls since the last `done`
  # (`docs/features/usage-and-limits.md`, "Per provider"): it outlives a
  # turn that ends with no `done`, and a compaction turn (`compact?`): no
  # message holds the usage of a compaction, so it goes into the next
  # `done` (docs/features/harness-compaction.md).
  defstruct open: %{}, streamed: MapSet.new(), usage: %Helyx.Usage{}, compact?: false

  import Helyx.Usage, only: [wire_tokens?: 1, wire_window?: 1]

  alias Helyx.HarnessIO
  alias Helyx.Message

  # Item types that run something (see the research note).
  @tool_item_types ~w(commandExecution fileChange mcpToolCall dynamicToolCall collabAgentToolCall
            webSearch imageView imageGeneration)

  @counts ~w(inputTokens cachedInputTokens cacheWriteInputTokens outputTokens)

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

  # The program compacted the thread's history. It gives no token counts.
  def notification("item/completed", %{"item" => %{"type" => "contextCompaction"}}, items),
    do: {[{:compaction, nil, nil}], items}

  # One notification after each model call. A count outside the wire
  # bound, and a cached count above the input, add nothing. The cost stays
  # unknown until a price source exists (#559).
  def notification(
        "thread/tokenUsage/updated",
        %{"tokenUsage" => %{"last" => %{} = last} = usage},
        items
      ) do
    [input, cached, write, output] = counts = for key <- @counts, do: Map.get(last, key, 0)
    {total, window} = {last["totalTokens"], usage["modelContextWindow"]}

    with true <- Enum.all?(counts, &wire_tokens?/1) and cached <= input,
         true <- total == nil or wire_tokens?(total),
         true <- window == nil or wire_window?(window) do
      call = %Helyx.Usage{
        input: input - cached,
        output: output,
        cache_read: cached,
        cache_write: write,
        context_tokens: total,
        context_window: window
      }

      {[], %{items | usage: Helyx.Usage.add(items.usage, call)}}
    else
      _ -> {[], items}
    end
  end

  def notification(_method, _params, items), do: {[], items}

  def terminal(%{"status" => "completed"}, %__MODULE__{compact?: true}),
    do: {:done, %{stop_reason: :end_turn, usage: nil}}

  def terminal(%{"status" => "completed"}, items),
    do: {:done, %{stop_reason: :end_turn, usage: items.usage}}

  def terminal(%{"status" => status} = result, _items),
    do: {:error, {:codex, status, HarnessIO.cap_error(error_message(result))}}

  # The items of the next turn. Only a `done` starts a new usage sum.
  def next({:done, _}, %__MODULE__{compact?: false}), do: %__MODULE__{}
  def next(_terminal, items), do: %__MODULE__{usage: items.usage}

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
