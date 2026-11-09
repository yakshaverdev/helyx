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

  # The shape of a message entry of the session file without its `type`.
  # `Helyx.Message.JSON.to_map/1` owns it. A `message_update` event carries a
  # bare block, so the block clauses stay.
  def value(%Message{} = message), do: Message.JSON.to_map(message)

  def value(%Message.Text{} = block), do: Message.JSON.block_to_map(block)
  def value(%Message.Thinking{} = block), do: Message.JSON.block_to_map(block)
  def value(%Message.ToolCall{} = block), do: Message.JSON.block_to_map(block)

  def value(%Helyx.Usage{} = usage), do: Message.JSON.usage_to_map(usage)

  def value(%_{} = struct), do: value(Map.from_struct(struct))
  def value(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value(value)} end)
  def value(list) when is_list(list), do: Enum.map(list, &value/1)
  def value(atom) when atom in [nil, true, false], do: atom
  def value(atom) when is_atom(atom), do: Atom.to_string(atom)
  def value(other), do: other
end
