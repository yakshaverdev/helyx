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

  defp data(_type, data), do: value(data)

  def snapshot(%Helyx.Session.Snapshot{} = snapshot), do: value(Map.from_struct(snapshot))

  # The shape of a message entry of the session file without its `type`.
  # `Helyx.Message.to_map/1` owns it. A `message_update` event carries a
  # bare block, so the block clauses stay.
  def value(%Message{} = message), do: Message.to_map(message)

  def value(%Message.Text{} = block), do: Message.block_to_map(block)
  def value(%Message.Thinking{} = block), do: Message.block_to_map(block)
  def value(%Message.ToolCall{} = block), do: Message.block_to_map(block)

  def value(%Helyx.Usage{} = usage), do: Message.usage_to_map(usage)

  def value(%_{} = struct), do: value(Map.from_struct(struct))
  def value(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value(value)} end)
  def value(list) when is_list(list), do: Enum.map(list, &value/1)
  def value(atom) when atom in [nil, true, false], do: atom
  def value(atom) when is_atom(atom), do: Atom.to_string(atom)
  def value(other), do: other
end
