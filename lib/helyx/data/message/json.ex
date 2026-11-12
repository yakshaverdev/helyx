defmodule Helyx.Message.JSON do
  @moduledoc false
  # The JSON map of a message: the session file entry without its `type`, and
  # the wire message (`docs/features/wire-protocol.md`, "Codec"). One owner
  # for the shape, so a new field reaches both. `from_map/1` reads the wire
  # shape, which a context of a provider request uses: it allows a message
  # with no id and a user message with no origin.

  alias Helyx.{Message, UIBlock, Usage}

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
  # The message of the wire shape. A missing `id` and a missing `origin` are
  # nil: a context message that a plugin built has neither. A key that the
  # shape does not know is ignored; a known key with a bad value is `:error`.
  @spec from_map(term()) :: {:ok, Message.t()} | :error
  def from_map(%{"role" => role, "content" => content} = map)
      when is_binary(role) and is_list(content) do
    with {:ok, role} <- role(role),
         {:ok, blocks} <- blocks(content),
         {:ok, origin} <- origin(role, map["origin"]),
         {:ok, usage} <- from_usage(map["usage"]),
         {:ok, ui_blocks} <- ui_blocks(role, map["ui_blocks"]),
         :ok <- optional_text(map["id"]),
         :ok <- optional_text(map["model"]),
         :ok <- optional_text(map["tool_call_id"]),
         :ok <- optional_text(map["tool_name"]),
         {:ok, stop_reason} <- stop_reason(map["stop_reason"]),
         {:ok, is_error} <- error_flag(role, map["is_error"]) do
      {:ok,
       %Message{
         role: role,
         id: map["id"],
         origin: origin,
         content: blocks,
         model: map["model"],
         stop_reason: stop_reason,
         tool_call_id: map["tool_call_id"],
         tool_name: map["tool_name"],
         is_error: is_error,
         usage: usage,
         ui_blocks: ui_blocks
       }}
    end
  end

  def from_map(_map), do: :error

  @doc false
  # The JSON map of a usage: string keys, no nil field, and `cost_kind` as its
  # name, so the map is JSON data as it is.
  @spec usage_to_map(Usage.t()) :: map()
  def usage_to_map(%Usage{} = usage) do
    for {key, value} <- Map.from_struct(usage), value != nil, into: %{} do
      value = if key == :cost_kind and is_atom(value), do: Atom.to_string(value), else: value
      {Atom.to_string(key), value}
    end
  end

  @doc false
  # The usage of its JSON map, or nil. A field that is missing is nil; the
  # struct bound is `Helyx.Usage.valid?/1`.
  @spec from_usage(term()) :: {:ok, Usage.t() | nil} | :error
  def from_usage(nil), do: {:ok, nil}

  def from_usage(%{} = map) when not is_struct(map) do
    keys = Map.keys(%Usage{}) -- [:__struct__]
    fields = for key <- keys, do: {key, map[Atom.to_string(key)]}

    with true <- map_size(map) == Enum.count(fields, fn {_key, value} -> value != nil end),
         {:ok, kind} <- usage_kind(map["cost_kind"]),
         usage = struct!(Usage, Keyword.put(fields, :cost_kind, kind)),
         true <- Usage.valid?(usage) do
      {:ok, usage}
    else
      _ -> :error
    end
  end

  def from_usage(_map), do: :error

  defp usage_kind(nil), do: {:ok, nil}
  defp usage_kind("list"), do: {:ok, :list}
  defp usage_kind("billed"), do: {:ok, :billed}
  defp usage_kind(_kind), do: :error

  defp role("user"), do: {:ok, :user}
  defp role("assistant"), do: {:ok, :assistant}
  defp role("tool_result"), do: {:ok, :tool_result}
  defp role(_role), do: :error

  defp blocks(content) do
    if List.improper?(content) or length(content) > Helyx.Session.Turn.max_message_blocks(),
      do: :error,
      else: blocks(content, [])
  end

  defp blocks([], acc), do: {:ok, Enum.reverse(acc)}

  defp blocks([block | rest], acc) do
    with {:ok, block} <- block(block), do: blocks(rest, [block | acc])
  end

  defp block(%{"type" => "text", "text" => text} = map)
       when map_size(map) == 2 and is_binary(text) do
    if String.valid?(text), do: {:ok, %Message.Text{text: text}}, else: :error
  end

  defp block(%{"type" => "thinking", "thinking" => thinking} = map)
       when map_size(map) == 2 and is_binary(thinking) do
    if String.valid?(thinking), do: {:ok, %Message.Thinking{thinking: thinking}}, else: :error
  end

  defp block(%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => arguments} = map)
       when map_size(map) == 4 and is_binary(id) and is_binary(name) and is_map(arguments) do
    if String.valid?(id) and String.valid?(name) and not is_struct(arguments) and
         not Message.big_integer?(arguments) do
      {:ok, %Message.ToolCall{id: id, name: name, arguments: arguments}}
    else
      :error
    end
  end

  defp block(_block), do: :error

  defp origin(:user, %{"kind" => kind, "id" => id} = map) when map_size(map) == 2 do
    with {:ok, kind} <- origin_kind(kind),
         origin = %{kind: kind, id: id},
         true <- Message.origin?(origin) do
      {:ok, origin}
    end
  end

  defp origin(_role, nil), do: {:ok, nil}
  defp origin(_role, _origin), do: :error

  defp origin_kind("user"), do: {:ok, :user}
  defp origin_kind("background"), do: {:ok, :background}
  defp origin_kind("product"), do: {:ok, :product}
  defp origin_kind("hook"), do: {:ok, :hook}
  defp origin_kind(_kind), do: :error

  defp ui_blocks(_role, nil), do: {:ok, []}
  defp ui_blocks(:tool_result, blocks), do: UIBlock.check_list(blocks)
  defp ui_blocks(_role, []), do: {:ok, []}
  defp ui_blocks(_role, _blocks), do: :error

  defp optional_text(nil), do: :ok

  defp optional_text(value),
    do: if(is_binary(value) and String.valid?(value), do: :ok, else: :error)

  defp error_flag(:tool_result, value) when is_boolean(value), do: {:ok, value}
  defp error_flag(_role, nil), do: {:ok, false}
  defp error_flag(_role, false), do: {:ok, false}
  defp error_flag(_role, _value), do: :error

  defp stop_reason(nil), do: {:ok, nil}

  for reason <- Message.stop_reasons() do
    defp stop_reason(unquote(Atom.to_string(reason))), do: {:ok, unquote(reason)}
  end

  defp stop_reason(_stop_reason), do: :error

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
