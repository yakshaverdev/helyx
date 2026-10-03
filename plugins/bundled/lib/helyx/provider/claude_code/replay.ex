defmodule Helyx.Provider.ClaudeCode.Replay do
  @moduledoc false
  # The stdin lines of `Helyx.Provider.ClaudeCode`: the JSON line, the
  # user lines, and the replay of the transcript to a fresh harness session.

  alias Helyx.HarnessIO
  alias Helyx.Message

  # One line per assistant message, and one `shouldQuery: false` user line
  # for each run of user messages and tool results between them. The
  # replay may start at an assistant line or at a user line with no tool
  # result, because the call of every kept result is then kept too. The
  # kept lines and `last` go out in chunks, each ending at a user line; the
  # last chunk ends with `last`. Gives the chunks, the number of messages
  # left out, and whether any line is kept.
  def chunks(history, last) do
    entries =
      history
      |> Enum.chunk_by(&(&1.role == :assistant))
      |> Enum.flat_map(fn
        [%Message{role: :assistant} | _] = messages ->
          for message <- messages, do: {{:assistant, message}, 1, true}

        messages ->
          start? = not Enum.any?(messages, &(&1.role == :tool_result))
          [{{:user, messages}, length(messages), start?}]
      end)

    {kept, cut} = HarnessIO.cap_replay(entries, length(history), &entry_line/1)

    chunks =
      Enum.chunk_while(
        kept,
        [],
        fn
          {{:user, _}, line}, acc -> {:cont, Enum.reverse(acc, [line]), []}
          {{:assistant, _}, line}, acc -> {:cont, [line | acc]}
        end,
        &{:cont, Enum.reverse(&1, [last]), []}
      )

    {chunks, cut, kept != []}
  end

  defp entry_line({:assistant, %Message{content: blocks}}) do
    content =
      for block <- blocks, json = assistant_block(block), do: json

    content != [] && line(%{type: "assistant", message: %{role: "assistant", content: content}})
  end

  defp entry_line({:user, messages}) do
    content = Enum.flat_map(messages, &user_content/1)

    content != [] &&
      line(%{type: "user", shouldQuery: false, message: %{role: "user", content: content}})
  end

  # Thinking is not replayed: its signature belongs to the model that made it.
  defp assistant_block(%Message.Text{text: text}) when text != "", do: %{type: "text", text: text}

  defp assistant_block(%Message.ToolCall{} = call),
    do: %{
      type: "tool_use",
      id: HarnessIO.wire_id(call.id),
      name: call.name,
      input: call.arguments
    }

  defp assistant_block(_block), do: nil

  def user_content(%Message{role: :tool_result} = message) do
    [
      %{
        type: "tool_result",
        tool_use_id: HarnessIO.wire_id(message.tool_call_id),
        content: Message.text(message),
        is_error: message.is_error
      }
    ]
  end

  def user_content(%Message{content: blocks}) do
    for %Message.Text{text: text} <- blocks, text != "", do: %{type: "text", text: text}
  end

  def line(map), do: [JSON.encode!(map), "\n"]

  def user_line(uuid, content),
    do: line(%{type: "user", uuid: uuid, message: %{role: "user", content: content}})
end
