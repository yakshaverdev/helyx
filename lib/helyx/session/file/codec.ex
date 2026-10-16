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
        "usage" => message.usage && encode_usage(message.usage)
      }
      |> Map.reject(fn {_key, value} -> value in [nil, false] end)

    if role == :tool_result, do: Map.put(encoded, "is_error", message.is_error), else: encoded
  end

  defp encode_block(%Message.Text{text: text}), do: %{"type" => "text", "text" => text}

  defp encode_block(%Message.Thinking{thinking: thinking}),
    do: %{"type" => "thinking", "thinking" => thinking}

  defp encode_block(%Message.ToolCall{id: id, name: name, arguments: arguments}) do
    %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => arguments}
  end

  # A bad value of a field that core needs (role, content, tool_call_id,
  # tool_name, is_error) misses its decode clause; the rescue in `load/3`
  # of `Helyx.Session.File` turns that into a rejected file. The model, the
  # stop reason, and the usage are optional: a bad model or stop reason
  # decodes as a missing one, and a bad usage as the unknown usage, so it
  # does not lose the chat.
  def decode(entry) do
    role = decode_role(entry["role"])

    %Message{
      role: role,
      content: Enum.map(entry["content"], &(&1 |> decode_block() |> cut_text(role))),
      model: decode_model(entry["model"]),
      stop_reason: decode_stop_reason(entry["stop_reason"]),
      tool_call_id: optional_string(entry["tool_call_id"]),
      tool_name: optional_string(entry["tool_name"]),
      is_error: decode_is_error(entry["is_error"]),
      usage: decode_usage(Map.fetch(entry, "usage"))
    }
  end

  # A tool result text from the disk gets the cut of a live one, so every
  # tool result in the transcript keeps the bound after a resume.
  defp cut_text(%Message.Text{text: text}, :tool_result),
    do: %Message.Text{text: Message.cut_result(text)}

  defp cut_text(block, _role), do: block

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

  # The usage object has string keys, no nil field, and the kind as a
  # string. The reader takes only the known keys and checks the struct
  # with `Helyx.Usage.valid?/1`, as `Helyx.Session.Stream.check/1` does: a
  # usage that fails, such as the provider's own keys of a file from
  # before #557, is the unknown usage, and the message stays. Only a
  # message with no usage key has no usage.
  @usage_keys Map.keys(%Helyx.Usage{}) -- [:__struct__]

  defp encode_usage(usage) do
    for {key, value} <- Map.from_struct(usage), value != nil, into: %{} do
      {Atom.to_string(key), value}
    end
  end

  defp decode_usage(:error), do: nil

  defp decode_usage({:ok, %{} = object}) do
    fields = for key <- @usage_keys, do: {key, object[Atom.to_string(key)]}

    with true <- map_size(object) == Enum.count(fields, fn {_key, value} -> value != nil end),
         {:ok, kind} <- decode_kind(object["cost_kind"]),
         usage = struct!(Helyx.Usage, Keyword.put(fields, :cost_kind, kind)),
         true <- Helyx.Usage.valid?(usage) do
      usage
    else
      _ -> %Helyx.Usage{}
    end
  end

  defp decode_usage({:ok, _value}), do: %Helyx.Usage{}

  defp decode_kind(nil), do: {:ok, nil}
  defp decode_kind("list"), do: {:ok, :list}
  defp decode_kind("billed"), do: {:ok, :billed}
  defp decode_kind(_value), do: :error

  defp decode_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: %Message.Text{text: text}

  # A block this module no longer writes, an image or a thinking signature,
  # misses its clause, so the file is rejected and nothing is dropped.
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
end
