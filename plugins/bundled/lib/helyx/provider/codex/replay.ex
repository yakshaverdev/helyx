defmodule Helyx.Provider.Codex.Replay do
  @moduledoc false
  # The replay items of `thread/inject_items`: the transcript as Responses
  # API items, each encoded once.

  alias Helyx.HarnessIO
  alias Helyx.Message

  # One entry per message, with its Responses API items: an assistant
  # message gives a message item per text and a `function_call` per tool
  # call (thinking is not replayed), a user message a message item, and a
  # tool result a `function_call_output`. The replay may start at any
  # message but a tool result, so every kept result keeps its call.
  def items(history) do
    entries = for message <- history, do: {message, 1, message.role != :tool_result}

    {kept, cut} =
      HarnessIO.cap_replay(entries, length(history), fn message ->
        items = message_items(message)
        items != [] && items
      end)

    {for({_message, items} <- kept, item <- items, do: item), cut}
  end

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

  # The model API takes a tool name of `[a-zA-Z0-9_-]` only; the cut at 64
  # is the function name limit of the Chat Completions API, not verified for
  # `thread/inject_items` (see the research note).
  defp tool_name(name) do
    case String.replace(name, ~r/[^a-zA-Z0-9_-]/u, "_") do
      "" -> "_"
      name -> binary_part(name, 0, min(byte_size(name), 64))
    end
  end
end
