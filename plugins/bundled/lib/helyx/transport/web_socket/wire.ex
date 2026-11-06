defmodule Helyx.Transport.WebSocket.Wire do
  @moduledoc false
  # Core values as the JSON values of the wire schema
  # (`docs/features/wire-protocol.md`, "Codec").

  alias Helyx.Message

  def event(%Helyx.Event{} = event) do
    %{
      "type" => Atom.to_string(event.type),
      "session_id" => event.session_id,
      "instance_id" => event.instance_id,
      "turn_id" => event.turn_id,
      "seq" => event.seq,
      "data" => data(event.type, event.data)
    }
  end

  # The wire leaves out the texts of these two events: the messages carry them.
  defp data(:queue_dropped, data), do: value(Map.delete(data, :texts))
  defp data(:steer_unconfirmed, data), do: value(Map.delete(data, :text))

  defp data(:message_end, %{error: :aborted} = data),
    do: value(%{data | error: %{kind: :aborted}})

  defp data(:message_end, %{error: text} = data) when is_binary(text),
    do: value(%{data | error: %{kind: :failed, text: text}})

  defp data(:ui_block, data), do: ui_block(data)
  defp data(_type, data), do: value(data)

  def snapshot(%Helyx.Session.Snapshot{ui_blocks: blocks} = snapshot) do
    snapshot
    |> Map.from_struct()
    |> Map.delete(:ui_blocks)
    |> value()
    |> Map.put("ui_blocks", Enum.map(blocks, &ui_block/1))
  end

  # A UI block is a JSON object with string keys already (`Helyx.UIBlock`):
  # it goes as it is.
  defp ui_block(%{call_id: call_id, key: key, block: block}),
    do: %{"call_id" => call_id, "key" => key, "block" => block}

  # The shape of a message entry of the session file without its `type`: a
  # nil or false field is left out, but `is_error` of a tool result, and
  # `ui_blocks` of a tool result when it has any, each block as it is.
  def value(%Message{} = message) do
    encoded =
      %{
        "id" => message.id,
        "role" => Atom.to_string(message.role),
        "origin" => message.origin && value(message.origin),
        "content" => Enum.map(message.content, &value/1),
        "model" => message.model,
        "stop_reason" => message.stop_reason && Atom.to_string(message.stop_reason),
        "tool_call_id" => message.tool_call_id,
        "tool_name" => message.tool_name,
        "usage" => message.usage && value(message.usage)
      }
      |> Map.reject(fn {_key, value} -> value in [nil, false] end)

    if message.role == :tool_result, do: result(encoded, message), else: encoded
  end

  def value(%Message.Text{text: text}), do: %{"type" => "text", "text" => text}

  def value(%Message.Thinking{thinking: thinking}),
    do: %{"type" => "thinking", "thinking" => thinking}

  # The arguments are a JSON object already.
  def value(%Message.ToolCall{} = call),
    do: %{
      "type" => "tool_call",
      "id" => call.id,
      "name" => call.name,
      "arguments" => call.arguments
    }

  def value(%Helyx.Usage{} = usage) do
    for {key, value} <- Map.from_struct(usage),
        value != nil,
        into: %{},
        do: {Atom.to_string(key), value(value)}
  end

  def value(%_{} = struct), do: value(Map.from_struct(struct))
  def value(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value(value)} end)
  def value(list) when is_list(list), do: Enum.map(list, &value/1)
  def value(atom) when atom in [nil, true, false], do: atom
  def value(atom) when is_atom(atom), do: Atom.to_string(atom)
  def value(other), do: other

  defp result(encoded, %Message{ui_blocks: []} = message),
    do: Map.put(encoded, "is_error", message.is_error)

  defp result(encoded, message),
    do: Map.merge(encoded, %{"is_error" => message.is_error, "ui_blocks" => message.ui_blocks})
end
