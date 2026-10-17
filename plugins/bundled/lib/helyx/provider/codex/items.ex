defmodule Helyx.Provider.Codex.Items do
  @moduledoc false
  # The item translation of `Helyx.Provider.Codex` for the running turn.
  #
  # `open` maps the open tool items to their types, and `streamed` holds
  # the ids of the messages whose text came as deltas. `usage` is the sum
  # of the thread's model calls since the last `done`, nil before the
  # first (`docs/features/usage-and-limits.md`, "Per provider"): it
  # outlives a turn that ends with no `done`, and a compaction turn
  # (`compact?`): no message holds the usage of a compaction, so it goes
  # into the next `done` (docs/features/harness-compaction.md). `lost?` is
  # the flag: a call since the last `done` may be in no sum, so the cost of
  # the next `done` is nil. `info` is the config window and prices
  # (`Helyx.ModelInfo`).
  defstruct open: %{},
            streamed: MapSet.new(),
            usage: nil,
            compact?: false,
            lost?: false,
            info: %Helyx.ModelInfo{}

  import Helyx.Usage, only: [wire_tokens?: 1, wire_window?: 1]

  alias Helyx.{HarnessIO, Message, ModelInfo}
  alias Helyx.Provider.Codex

  # Item types that run something (see the research note).
  @tool_item_types ~w(commandExecution fileChange mcpToolCall dynamicToolCall collabAgentToolCall
            webSearch imageView imageGeneration)

  @counts ~w(inputTokens cachedInputTokens cacheWriteInputTokens outputTokens)
  # A missing cache count is 0; a missing input or output count is a bad
  # shape.
  @cache_counts %{"cachedInputTokens" => 0, "cacheWriteInputTokens" => 0}

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

  def notification(_method, _params, items), do: {[], items}

  # Every `thread/tokenUsage/updated` line, one after each model call. The
  # good shape: a map `params` with a nonempty string `threadId` and a map
  # `tokenUsage.last`. A good line of another thread is a child thread's,
  # in no sum (the sub-agent ceiling). A line of the running turn of
  # `thread` is priced alone and added. Any other line, a count outside
  # the wire bound, and a cached count above the input add nothing and set
  # the flag. Whether `inputTokens` holds the cache writes is not seen
  # (research note), so a call with cache writes has no cost.
  def usage(
        %{"params" => %{"threadId" => other, "tokenUsage" => %{"last" => %{}}}},
        thread,
        _,
        items
      )
      when is_binary(other) and other not in ["", thread],
      do: items

  def usage(line, thread, turn, items) do
    with %{"params" => %{"threadId" => ^thread, "turnId" => ^turn} = params} <- line,
         true <- is_binary(turn),
         %{"tokenUsage" => %{"last" => %{} = last} = usage} <- params,
         last = Map.merge(@cache_counts, last),
         [input, cached, write, output] = counts = for(key <- @counts, do: last[key]),
         {total, window} = {last["totalTokens"], usage["modelContextWindow"]},
         true <- Enum.all?(counts, &wire_tokens?/1) and cached <= input,
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

      call = ModelInfo.price(call, items.info)
      call = if write > 0, do: Helyx.Usage.unpriced(call), else: call
      %{items | usage: if(items.usage, do: Helyx.Usage.add(items.usage, call), else: call)}
    else
      _ -> %{items | lost?: true}
    end
  end

  def terminal(%{"status" => "completed"}, %__MODULE__{compact?: true}),
    do: {:done, %{stop_reason: :end_turn, usage: nil}}

  def terminal(%{"status" => "completed"}, items),
    do: {:done, %{stop_reason: :end_turn, usage: usage(items)}}

  def terminal(%{"status" => status} = result, _items),
    do: {:error, HarnessIO.Error.reason(:codex, Codex.id(), status, error_message(result))}

  # The items of the next turn. Only a `done` starts a new usage sum; a
  # turn that ended `interrupted` or `failed` sets the flag.
  def next({:done, _}, %__MODULE__{compact?: false} = items), do: %__MODULE__{info: items.info}

  def next({:done, _}, items),
    do: %__MODULE__{usage: items.usage, lost?: items.lost?, info: items.info}

  def next(_terminal, items), do: %__MODULE__{usage: items.usage, lost?: true, info: items.info}

  # A turn that started a sub-agent: the calls of the child thread are in
  # no usage of this thread (research note), so the flag is set.
  def sub_agent(items), do: %{items | lost?: true}

  defp usage(%{usage: nil}), do: %Helyx.Usage{}
  defp usage(%{usage: usage, lost?: true}), do: Helyx.Usage.unpriced(usage)
  defp usage(%{usage: usage}), do: usage

  def error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  def error_message(_map), do: nil

  # A Helyx tool call has the Helyx name and arguments, as with an API
  # provider (`docs/features/provider-parity.md`).
  defp tool_call(%{"type" => "dynamicToolCall", "id" => id, "tool" => tool, "arguments" => args})
       when is_binary(tool) and is_map(args),
       do: {:tool_call, %Message.ToolCall{id: id, name: tool, arguments: args}}

  defp tool_call(%{"type" => type, "id" => id} = item),
    do: {:tool_call, %Message.ToolCall{id: id, name: type, arguments: arguments(item)}}

  defp arguments(%{"type" => "commandExecution"} = item), do: Map.take(item, ["command", "cwd"])

  defp arguments(item),
    do:
      item
      |> Map.drop(["id", "type", "status"])
      |> Map.reject(fn {_key, value} -> value == nil end)

  # A command gives its output, and a Helyx tool call the content of its
  # answer; any other tool item gives its fields as JSON.
  defp tool_result(item) do
    text =
      case item do
        %{"type" => "commandExecution", "aggregatedOutput" => out} when is_binary(out) ->
          out

        %{"type" => "commandExecution"} ->
          ""

        %{"type" => "dynamicToolCall", "contentItems" => [_ | _] = content} ->
          content_text(content)

        _ ->
          JSON.encode!(Map.drop(item, ["id", "type"]))
      end

    {if(failed?(item), do: :error, else: :ok), Helyx.Text.truncate(text, :tail)}
  end

  defp failed?(item),
    do:
      item["status"] in ["failed", "declined"] or item["error"] != nil or
        item["success"] == false or (is_integer(item["exitCode"]) and item["exitCode"] != 0)

  # Helyx answers with text items only (`Helyx.Provider.Codex`).
  defp content_text(content) do
    texts = for %{"type" => "inputText", "text" => text} when is_binary(text) <- content, do: text
    Enum.join(texts, "\n")
  end
end
