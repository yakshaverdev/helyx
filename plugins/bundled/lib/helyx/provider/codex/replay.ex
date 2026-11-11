defmodule Helyx.Provider.Codex.Replay do
  @moduledoc false

  alias Helyx.HarnessIO
  alias Helyx.Message

  # The replay may start at any message but a tool result, so every kept
  # result keeps its call. Thinking is not replayed. An open turn that alone
  # passes the replay bound fails (`Helyx.HarnessIO.cap_replay/3`).
  def items(history, provider) do
    entries = for message <- history, do: {message, 1, message.role != :tool_result}

    case HarnessIO.cap_replay(entries, length(history), &encode/1) do
      {:ok, kept, cut} -> {:ok, items(kept), cut}
      {:error, reason} -> {:error, HarnessIO.replay_error(provider, reason)}
    end
  end

  defp encode(message) do
    items = message_items(message)
    items != [] && items
  end

  defp items(kept), do: for({_message, items} <- kept, item <- items, do: item)

  defp message_items(%Message{role: :tool_result} = message) do
    [
      item(%{
        type: "function_call_output",
        call_id: HarnessIO.wire_id(message.tool_call_id),
        output: Message.text(message)
      })
    ]
  end

  defp message_items(%Message{role: role, content: blocks}) do
    for block <- blocks, item = block_item(role, block), do: item(item)
  end

  defp block_item(:user, %Message.Text{text: text}) when text != "",
    do: %{type: "message", role: "user", content: [%{type: "input_text", text: text}]}

  defp block_item(:assistant, %Message.Text{text: text}) when text != "",
    do: %{type: "message", role: "assistant", content: [%{type: "output_text", text: text}]}

  defp block_item(:assistant, %Message.ToolCall{} = call) do
    %{
      type: "function_call",
      call_id: HarnessIO.wire_id(call.id),
      name: tool_name(call.name),
      arguments: JSON.encode!(call.arguments)
    }
  end

  defp block_item(_role, _block), do: nil

  # Each item is encoded once, so the cap counts its bytes.
  defp item(map), do: JSON.encode!(map)

  # The model API takes a tool name of `[a-zA-Z0-9_-]` only (see the
  # research note). The length is kept: no limit is known for
  # `thread/inject_items`, and the replay budget bounds the bytes.
  defp tool_name(name) do
    case String.replace(name, ~r/[^a-zA-Z0-9_-]/u, "_") do
      "" -> "_"
      name -> name
    end
  end
end
