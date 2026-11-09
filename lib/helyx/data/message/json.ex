defmodule Helyx.Message.JSON do
  @moduledoc false
  # The JSON map of a message: the session file entry without its `type`, and
  # the wire message (`docs/features/wire-protocol.md`, "Codec"). One owner
  # for the shape, so a new field reaches both.

  alias Helyx.Message

  @doc false
  @spec to_map(Message.t()) :: map()
  def to_map(%Message{role: role, stop_reason: stop_reason} = message) do
    check_stop_reason(stop_reason)

    encoded =
      %{
        "id" => message.id,
        "role" => Atom.to_string(role),
        "origin" => message.origin && origin_to_map(message.origin),
        "content" => Enum.map(message.content, &block_to_map/1),
        "model" => message.model,
        "stop_reason" => stop_reason && Atom.to_string(stop_reason),
        "tool_call_id" => message.tool_call_id,
        "tool_name" => message.tool_name,
        "usage" => message.usage && usage_to_map(message.usage)
      }
      |> Map.reject(fn {_key, value} -> value in [nil, false] end)

    if role == :tool_result, do: result_to_map(encoded, message), else: encoded
  end

  # A tool result has `is_error` always, and `ui_blocks` when it has any.
  defp result_to_map(encoded, %Message{ui_blocks: []} = message),
    do: Map.put(encoded, "is_error", message.is_error)

  defp result_to_map(encoded, message),
    do: Map.merge(encoded, %{"is_error" => message.is_error, "ui_blocks" => message.ui_blocks})

  @doc false
  # The JSON map of a usage: string keys, no nil field. The values keep their
  # type; the JSON encoder writes an atom as its name.
  @spec usage_to_map(Helyx.Usage.t()) :: map()
  def usage_to_map(%Helyx.Usage{} = usage) do
    for {key, value} <- Map.from_struct(usage), value != nil, into: %{} do
      {Atom.to_string(key), value}
    end
  end

  defp origin_to_map(%{kind: kind, id: id}),
    do: %{"kind" => Atom.to_string(kind), "id" => id}

  @doc false
  # The JSON map of one content block. The wire sends a bare block in a
  # `message_update` event, so the shape has one owner here.
  @spec block_to_map(Message.block()) :: map()
  def block_to_map(%Message.Text{text: text}), do: %{"type" => "text", "text" => text}

  def block_to_map(%Message.Thinking{thinking: thinking}),
    do: %{"type" => "thinking", "thinking" => thinking}

  def block_to_map(%Message.ToolCall{id: id, name: name, arguments: arguments}),
    do: %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => arguments}

  # The atoms are interned here, so a fresh VM that has loaded no provider
  # still writes and checks a stop reason. A reason outside the set raises,
  # so the file writer and the wire reject it instead of writing an entry
  # that a later reader would see as no stop reason.
  defp check_stop_reason(nil), do: :ok
  for reason <- Message.stop_reasons(), do: defp(check_stop_reason(unquote(reason)), do: :ok)

  defp check_stop_reason(other) do
    raise ArgumentError, "a stop reason outside the set: #{inspect(other)}"
  end
end
