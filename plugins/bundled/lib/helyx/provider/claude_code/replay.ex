defmodule Helyx.Provider.ClaudeCode.Replay do
  @moduledoc false
  # The user lines of `Helyx.Provider.ClaudeCode` and the replay of the
  # transcript to a fresh harness session.

  alias Helyx.HarnessIO
  alias Helyx.Message

  # One line per assistant message, and one `shouldQuery: false` user line
  # for each run of user messages and tool results between them. An entry
  # is {line or false, messages, start?}: the replay may start at an entry
  # whose line has no tool result, because the call of every kept result is
  # then kept too. The kept lines and `last` go out in chunks, each
  # ending at a user line; the last chunk ends with `last`. Gives the
  # chunks, the number of messages left out, and whether any line is kept.
  def chunks(history, last) do
    tagged =
      history
      |> Enum.chunk_by(&(&1.role == :assistant))
      |> Enum.flat_map(fn
        [%Message{role: :assistant} | _] = messages ->
          Enum.map(messages, &{:assistant, assistant_entry(&1)})

        messages ->
          [{:user, user_entry(messages)}]
      end)

    {lines, cut} = HarnessIO.cap_replay(Enum.map(tagged, &elem(&1, 1)), length(history))

    # `cap_replay` keeps a suffix of the lines that are not `false`.
    kinds = for {kind, {line, _n, _start?}} <- tagged, line, do: kind

    chunks =
      kinds
      |> Enum.take(-length(lines))
      |> Enum.zip(lines)
      |> Enum.chunk_while(
        [],
        fn
          {:user, line}, acc -> {:cont, Enum.reverse(acc, [line]), []}
          {:assistant, line}, acc -> {:cont, [line | acc]}
        end,
        &{:cont, Enum.reverse(&1, [last]), []}
      )

    {chunks, cut, lines != []}
  end

  defp assistant_entry(%Message{content: blocks}) do
    content =
      for block <- blocks, json = assistant_block(block), do: json

    {content != [] && line(%{type: "assistant", message: %{role: "assistant", content: content}}),
     1, true}
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

  defp user_entry(messages) do
    content = Enum.flat_map(messages, &user_content/1)
    start? = not Enum.any?(messages, &(&1.role == :tool_result))
    message = %{role: "user", content: content}

    {content != [] && line(%{type: "user", shouldQuery: false, message: message}),
     length(messages), start?}
  end

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

  defp line(map), do: [JSON.encode!(map), "\n"]

  def user_line(uuid, content),
    do: line(%{type: "user", uuid: uuid, message: %{role: "user", content: content}})
end
