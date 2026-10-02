defmodule Helyx.Session.File.Codec do
  @moduledoc false
  # The message format of the session file. `encode/1` turns a `Message` into
  # an entry map; `decode/1` turns an entry map into a `Message`. A bad
  # required field raises; the caller rescues it.

  alias Helyx.Message

  def encode(%Message{role: role} = message) do
    encoded =
      %{
        "type" => "message",
        "role" => Atom.to_string(role),
        "content" => Enum.map(message.content, &encode_block/1),
        "model" => message.model,
        "stop_reason" => encode_stop_reason(message.stop_reason),
        "tool_call_id" => message.tool_call_id,
        "tool_name" => message.tool_name,
        "usage" => map_size(message.usage) > 0 && message.usage
      }
      |> Map.reject(fn {_key, value} -> value in [nil, false] end)

    if role == :tool_result, do: Map.put(encoded, "is_error", message.is_error), else: encoded
  end

  defp encode_block(%Message.Text{text: text}), do: %{"type" => "text", "text" => text}

  defp encode_block(%Message.Thinking{thinking: thinking, signature: nil}),
    do: %{"type" => "thinking", "thinking" => thinking}

  defp encode_block(%Message.Thinking{thinking: thinking, signature: signature}),
    do: %{"type" => "thinking", "thinking" => thinking, "signature" => signature}

  defp encode_block(%Message.ToolCall{id: id, name: name, arguments: arguments}) do
    %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => arguments}
  end

  defp encode_block(%Message.Image{mime_type: mime_type, data: data}) do
    %{"type" => "image", "mime_type" => mime_type, "data" => data}
  end

  # A bad value of a field that core needs (role, content, tool_call_id,
  # tool_name, is_error) misses its decode clause; the rescue in `load/3`
  # of `Helyx.Session.File` turns that into a rejected file. The model, the
  # stop reason, and the usage are optional: a bad one decodes as a missing
  # one, so it does not lose the chat.
  def decode(entry) do
    %Message{
      role: decode_role(entry["role"]),
      content: Enum.map(entry["content"], &decode_block/1),
      model: decode_model(entry["model"]),
      stop_reason: decode_stop_reason(entry["stop_reason"]),
      tool_call_id: optional_string(entry["tool_call_id"]),
      tool_name: optional_string(entry["tool_name"]),
      is_error: decode_is_error(entry["is_error"]),
      usage: decode_usage(entry["usage"])
    }
  end

  defp decode_role("user"), do: :user
  defp decode_role("assistant"), do: :assistant
  defp decode_role("tool_result"), do: :tool_result

  # The clauses are built at compile time from `Message.stop_reasons/0`, so
  # the atoms are interned in this module: a fresh VM that has loaded no
  # provider still decodes a saved file. A stop reason outside the set has
  # no encode clause, so the writer raises an error instead of appending an
  # entry that a later resume would read as no stop reason. On decode, any
  # value outside the set, false too, is no stop reason.
  defp encode_stop_reason(nil), do: nil

  for reason <- Message.stop_reasons() do
    defp decode_stop_reason(unquote(Atom.to_string(reason))), do: unquote(reason)
    defp encode_stop_reason(unquote(reason)), do: unquote(Atom.to_string(reason))
  end

  defp decode_stop_reason(_value), do: nil

  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value

  defp decode_is_error(nil), do: false
  defp decode_is_error(value) when is_boolean(value), do: value

  defp decode_model(value) when is_binary(value), do: value
  defp decode_model(_value), do: nil

  defp decode_usage(value) when is_map(value), do: Message.cap_integers(value)
  defp decode_usage(_value), do: %{}

  defp decode_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: %Message.Text{text: text}

  defp decode_block(%{"type" => "thinking", "thinking" => thinking, "signature" => signature})
       when is_binary(thinking) and is_binary(signature),
       do: %Message.Thinking{thinking: thinking, signature: signature}

  defp decode_block(%{"type" => "thinking", "thinking" => thinking} = block)
       when is_binary(thinking) and not is_map_key(block, "signature"),
       do: %Message.Thinking{thinking: thinking}

  defp decode_block(%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args})
       when is_binary(id) and is_binary(name) and is_map(args) do
    # A file from before #79, or a file that a person changed, can hold an
    # integer over the digit limit. Each later provider request would pay the
    # quadratic JSON encode for it.
    %Message.ToolCall{id: id, name: name, arguments: Message.cap_integers(args)}
  end

  defp decode_block(%{"type" => "image", "mime_type" => mime_type, "data" => data})
       when is_binary(mime_type) and is_binary(data) do
    %Message.Image{mime_type: mime_type, data: data}
  end
end
