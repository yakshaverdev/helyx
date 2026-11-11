defmodule Helyx.Session.Hands.Term.Data do
  @moduledoc false
  # The data that the hands terms carry, with its checks and its JSON maps:
  # ids, texts, JSON values, provider options, tool calls, specs, the call
  # context, messages, usages, UI blocks, the settle input, the asker, and the
  # hook record. The term modules call these, so a shape has one owner.

  alias Helyx.{Message, UIBlock, Usage}
  alias Helyx.Message.ToolCall
  alias Helyx.Session.{Ask, File, Input}

  # A protocol id: the instance, the session, a turn, a task, a provider
  # process, the from of a request, and the id of a settle request
  # (`Helyx.Session.Id.new/0` makes 12 bytes).
  @max_id_bytes 64
  def max_id_bytes, do: @max_id_bytes

  # A registration id that is a module name crosses as text; its bound is the
  # origin id bound of `Helyx.Message`.
  def max_plugin_bytes, do: Message.max_origin_id_bytes()

  # The integer bound of one term (`docs/features/wire-protocol.md`, "Bounds").
  @max_integer_chars 1_024
  def max_integer_chars, do: @max_integer_chars

  # A read of the folder: at most this many paths, each at most this many bytes
  # (`docs/adr/0012-remote-hands.md`, "The protocol", the read of the folder).
  @max_paths 256
  def max_paths, do: @max_paths

  @max_path_bytes 4_096
  def max_path_bytes, do: @max_path_bytes

  @integer_limit 10 ** @max_integer_chars
  # A negative integer has one character more: the minus sign. The most
  # negative value of 1,024 characters is -(10^1023 - 1).
  @integer_floor -(10 ** (@max_integer_chars - 1))

  # The decode helper: the values of `keys` when `map` holds exactly them.
  @spec fields(map(), [String.t()]) :: {:ok, [term()]} | :error
  def fields(map, keys) do
    case values(map, ["t" | keys]) do
      {:ok, [_t | values]} -> {:ok, values}
      :error -> :error
    end
  end

  @doc false
  # The values of `keys` when `map` holds exactly them; `:error` for another
  # map. For a map that has no `t`.
  @spec values(map(), [String.t()]) :: {:ok, [term()]} | :error
  def values(map, keys) do
    if is_map(map) and map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1)),
      do: {:ok, Enum.map(keys, &Map.fetch!(map, &1))},
      else: :error
  end

  @spec id?(term()) :: boolean()
  def id?(value),
    do: is_binary(value) and byte_size(value) in 1..@max_id_bytes and String.valid?(value)

  @spec plugin?(term()) :: boolean()
  def plugin?(value), do: Message.origin?(%{kind: :hook, id: value})

  @spec text?(term()) :: boolean()
  def text?(value), do: is_binary(value) and String.valid?(value)

  @doc false
  # A reason crosses as the text of `Helyx.Reason.text/1`, so its check is the
  # text check; the term limit bounds it.
  def reason?(value), do: text?(value)

  @doc false
  # An atom that names a module, which no term carries.
  def module_atom?(value),
    do: is_atom(value) and String.starts_with?(Atom.to_string(value), "Elixir.")

  @doc false
  # A value that JSON carries with no loss: no atom but nil and the booleans,
  # no struct, no tuple, no pid, no reference, no function, string keys, valid
  # UTF-8, and integers within the term limit.
  @spec json?(term()) :: boolean()
  def json?(nil), do: true
  def json?(value) when is_boolean(value), do: true
  def json?(value) when is_integer(value), do: value < @integer_limit and value > @integer_floor
  def json?(value) when is_float(value), do: true
  def json?(value) when is_binary(value), do: String.valid?(value)

  def json?(value) when is_list(value),
    do: not List.improper?(value) and Enum.all?(value, &json?/1)

  def json?(value) when is_map(value) do
    not is_struct(value) and
      Enum.all?(value, fn {key, item} -> is_binary(key) and String.valid?(key) and json?(item) end)
  end

  def json?(_value), do: false

  @doc false
  # A keyword list of JSON values. The list crosses as pairs, so the order and
  # a repeated key stay. A key that names a module is refused.
  @spec provider_opts?(term()) :: boolean()
  def provider_opts?(value) do
    is_list(value) and not List.improper?(value) and
      Enum.all?(value, fn
        {key, item} when is_atom(key) -> not module_atom?(key) and json?(item)
        _other -> false
      end)
  end

  @spec provider_opts_to_map(keyword()) :: [list()]
  def provider_opts_to_map(opts),
    do: for({key, value} <- opts, do: [Atom.to_string(key), value])

  @spec to_provider_opts(term()) :: {:ok, keyword()} | :error
  def to_provider_opts(pairs) when is_list(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn
      [key, value], {:ok, acc} when is_binary(key) ->
        with {:ok, atom} <- existing_atom(key),
             false <- module_atom?(atom),
             true <- json?(value) do
          {:cont, {:ok, [{atom, value} | acc]}}
        else
          _ -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, opts} -> {:ok, Enum.reverse(opts)}
      :error -> :error
    end
  end

  def to_provider_opts(_pairs), do: :error

  defp existing_atom(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end

  @doc false
  # A positive integer within the term integer bound. A duration or a byte
  # count that has no bound of its own uses this.
  @spec integer?(term()) :: boolean()
  def integer?(value), do: is_integer(value) and value > 0 and value < @integer_limit

  @doc false
  # The bound of `:max_output_tokens` that `Helyx.Session.Input` checks.
  def max_output_tokens, do: Input.max_output_tokens()

  @doc false
  # A turn id is the session's (1 to 64 bytes) or the provider's id of a turn
  # that it started, which has the bound of a resume id (1 to 256 bytes).
  def turn_id?(value), do: Message.resume_id?(value)

  @doc false
  # A tool call id is the provider's, not one the session makes; its bound is
  # the call id bound of `Helyx.Message` (1 to 256 bytes). An approval id and a
  # resume id have their own checks.
  def call_id?(value), do: Message.approval_id?(value)

  @spec call?(term()) :: boolean()
  def call?(%ToolCall{id: id, name: name, arguments: arguments} = call) do
    map_size(call) == 4 and call_id?(id) and text?(name) and object?(arguments) and
      not Message.big_integer?(arguments)
  end

  def call?(_call), do: false

  # The arguments of a tool call are a JSON object, not any JSON value.
  defp object?(value), do: is_map(value) and not is_struct(value) and json?(value)

  @spec call_to_map(ToolCall.t()) :: map()
  def call_to_map(%ToolCall{id: id, name: name, arguments: arguments}),
    do: %{"id" => id, "name" => name, "arguments" => arguments}

  @spec to_call(term()) :: {:ok, ToolCall.t()} | :error
  def to_call(%{"id" => id, "name" => name, "arguments" => arguments} = map) do
    if map_size(map) == 3 do
      call = %ToolCall{id: id, name: name, arguments: arguments}

      if call?(call), do: {:ok, call}, else: :error
    else
      :error
    end
  end

  def to_call(_map), do: :error

  @doc false
  # A tool spec: the shape that `Helyx.Tool.specs/2` returns.
  @spec spec?(term()) :: boolean()
  def spec?(%{name: name, description: description, parameters: parameters} = spec) do
    map_size(spec) == 3 and Helyx.Tool.name?(name) and text?(description) and
      json?(parameters) and not Message.big_integer?(parameters)
  end

  def spec?(_spec), do: false

  @spec spec_to_map(Helyx.Tool.spec()) :: map()
  def spec_to_map(%{name: name, description: description, parameters: parameters}),
    do: %{"name" => name, "description" => description, "parameters" => parameters}

  @spec to_spec(term()) :: {:ok, Helyx.Tool.spec()} | :error
  def to_spec(%{"name" => name, "description" => description, "parameters" => parameters} = map) do
    if map_size(map) == 3 do
      spec = %{name: name, description: description, parameters: parameters}

      if spec?(spec), do: {:ok, spec}, else: :error
    else
      :error
    end
  end

  def to_spec(_map), do: :error

  @doc false
  # The context of a call on the session side: `Helyx.Session.Server.State.tool_context/2`
  # without a module or a pid. `model_context` crosses as its registration id.
  @spec context?(term()) :: boolean()
  def context?(%{session_id: id, model: model, provider_opts: opts, model_context: plugin} = c) do
    map_size(c) == 4 and id?(id) and text?(model) and byte_size(model) > 0 and
      provider_opts?(opts) and (is_nil(plugin) or plugin?(plugin))
  end

  def context?(_context), do: false

  @spec context_to_map(map()) :: map()
  def context_to_map(%{session_id: id, model: model, provider_opts: opts, model_context: plugin}) do
    %{
      "session_id" => id,
      "model" => model,
      "provider_opts" => provider_opts_to_map(opts),
      "model_context" => plugin
    }
  end

  @spec to_context(term()) :: {:ok, map()} | :error
  def to_context(
        %{
          "session_id" => id,
          "model" => model,
          "provider_opts" => pairs,
          "model_context" => plugin
        } = map
      ) do
    with 4 <- map_size(map),
         {:ok, opts} <- to_provider_opts(pairs),
         context = %{session_id: id, model: model, provider_opts: opts, model_context: plugin},
         true <- context?(context) do
      {:ok, context}
    else
      _ -> :error
    end
  end

  def to_context(_map), do: :error

  @doc false
  @spec usage?(term()) :: boolean()
  def usage?(nil), do: true
  def usage?(%Usage{} = usage), do: Usage.valid?(usage)
  def usage?(_usage), do: false

  @spec usage_to_map(Usage.t()) :: map()
  def usage_to_map(%Usage{} = usage), do: Message.JSON.usage_to_map(usage)

  @spec to_usage(term()) :: {:ok, Usage.t() | nil} | :error
  def to_usage(value), do: Message.JSON.from_usage(value)

  @doc false
  # A message of a session (a transcript answer or a background end) crosses
  # with the session file codec (`Helyx.Session.File.Codec`), which cuts a tool
  # result text and requires an id. A message of a provider context is read in
  # `context_message/1`: it has no id and its user message has no origin.
  @spec message?(term()) :: boolean()
  def message?(message), do: match?({:ok, _}, message(message))

  @spec message(term()) :: {:ok, Message.t()} | :error
  def message(%Message{id: id} = message) when is_binary(id) do
    with true <- id?(id),
         true <- session_message?(message),
         map = File.Codec.encode(message),
         {:ok, _size} <- Message.encoded_size(map) do
      to_message(map)
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def message(%{} = map) when not is_struct(map), do: to_message(map)
  def message(_message), do: :error

  @spec message_to_map(Message.t()) :: map()
  def message_to_map(%Message{} = message), do: File.Codec.encode(message)

  @spec to_message(term()) :: {:ok, Message.t()} | :error
  def to_message(%{} = map) when not is_struct(map) do
    message = File.Codec.decode(map)

    with true <- session_message?(message),
         {:ok, _size} <- Message.encoded_size(File.Codec.encode(message)) do
      {:ok, message}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def to_message(_map), do: :error

  # A file message always has an id and an origin on a user message; its other
  # roles have neither. `is_error` and the UI blocks are of a tool result.
  defp session_message?(%Message{id: id, role: role, origin: origin} = message) do
    id?(id) and
      if(role == :user,
        do: Message.origin?(origin),
        else: is_nil(origin)
      ) and
      (role == :tool_result or (message.is_error == false and message.ui_blocks == []))
  end

  @doc false
  # A message of the wire shape, used by the context of a provider request: a
  # missing id and a missing origin are allowed.
  @spec context_message?(term()) :: boolean()
  def context_message?(message), do: match?({:ok, _}, context_message(message))

  @spec context_message(term()) :: {:ok, Message.t()} | :error
  def context_message(%Message{role: role, is_error: is_error, ui_blocks: blocks} = message) do
    with true <- role in [:user, :assistant, :tool_result],
         true <- role == :tool_result or (is_error == false and blocks == []),
         map = Message.JSON.to_map(message),
         {:ok, _size} <- Message.encoded_size(map) do
      to_context_message(map)
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def context_message(%{} = map) when not is_struct(map), do: to_context_message(map)
  def context_message(_message), do: :error

  @spec context_message_to_map(Message.t()) :: map()
  def context_message_to_map(%Message{} = message), do: Message.JSON.to_map(message)

  @spec to_context_message(term()) :: {:ok, Message.t()} | :error
  def to_context_message(map), do: Message.JSON.from_map(map)

  @doc false
  # The UI blocks of a result: checked with `Helyx.UIBlock.check_list/1`, which
  # cuts a block over its bound.
  @spec blocks(term()) :: {:ok, [UIBlock.t()]} | :error
  def blocks(value), do: UIBlock.check_list(value)

  @spec blocks?(term()) :: boolean()
  def blocks?(value), do: match?({:ok, _}, UIBlock.check_list(value))

  @doc false
  # A proper list whose items pass `check?`.
  @spec list?(term(), (term() -> boolean())) :: boolean()
  def list?(list, check?),
    do: is_list(list) and not List.improper?(list) and Enum.all?(list, check?)

  @doc false
  # The values of the fields of `keys` when `map` holds exactly them, given to
  # `fun`; `:error` for another map and for the result of `fun`.
  @spec decode_fields(map(), [String.t()], ([term()] -> result)) :: result | :error
        when result: term()
  def decode_fields(map, keys, fun) do
    case fields(map, keys) do
      {:ok, values} -> fun.(values)
      :error -> :error
    end
  end

  @doc false
  # The values of `keys` when `map` holds exactly them, given to `fun`; `:error`
  # for another map and for the result of `fun`. For a map that has no `t`.
  @spec pairs(map(), [String.t()], ([term()] -> result)) :: result | :error
        when result: term()
  def pairs(map, keys, fun) do
    case values(map, keys) do
      {:ok, values} -> fun.(values)
      :error -> :error
    end
  end

  @doc false
  def reversed({:ok, list}), do: {:ok, Enum.reverse(list)}
  def reversed(:error), do: :error

  @doc false
  # The request of `Helyx.Tool.ask/1`: a JSON object within
  # `Helyx.Session.Ask.max_request_bytes/0`, and a UI block when it has a kind.
  @spec ask_request?(term()) :: boolean()
  def ask_request?(request) do
    Input.json_object(request, Ask.max_request_bytes()) == :ok and
      (not is_map_key(request, "kind") or UIBlock.envelope?(request))
  end

  @doc false
  # The input of a `before_settle` chain (`Helyx.Hook.settle/0`). The reason is
  # the one of a done turn.
  @spec settle_input?(term()) :: boolean()
  def settle_input?(%{session_id: id, turn_id: turn, stop_reason: reason, cwd: cwd} = input) do
    map_size(input) == 4 and id?(id) and turn_id?(turn) and
      reason in (Message.stop_reasons() -- [:aborted, :error]) and cwd?(cwd)
  end

  def settle_input?(_input), do: false

  @spec settle_input_to_map(map()) :: map()
  def settle_input_to_map(%{session_id: id, turn_id: turn, stop_reason: reason, cwd: cwd}),
    do: %{
      "session_id" => id,
      "turn_id" => turn,
      "stop_reason" => Atom.to_string(reason),
      "cwd" => cwd
    }

  @spec to_settle_input(term()) :: {:ok, map()} | :error
  def to_settle_input(
        %{"session_id" => id, "turn_id" => turn, "stop_reason" => reason, "cwd" => cwd} = map
      ) do
    with 4 <- map_size(map),
         {:ok, reason} <- reason(reason),
         input = %{session_id: id, turn_id: turn, stop_reason: reason, cwd: cwd},
         true <- settle_input?(input) do
      {:ok, input}
    else
      _ -> :error
    end
  end

  def to_settle_input(_map), do: :error

  for reason <- Message.stop_reasons() do
    defp reason(unquote(Atom.to_string(reason))), do: {:ok, unquote(reason)}
  end

  defp reason(_reason), do: :error

  @doc false
  # The kind of the Task of a call or hook, which an asker names:
  # `{:tool, call_id}` for a call, `{:hook, call_id}` for a hook of a call,
  # and `{:settle, id}` for a hook of a `before_settle` chain. `{:settle, id}`
  # is `{:hook, {:settle, id}}` in the hands.
  @spec asker?(term()) :: boolean()
  def asker?({kind, id}) when kind in [:tool, :hook], do: call_id?(id)
  def asker?({:settle, id}), do: id?(id)
  def asker?(_asker), do: false

  @spec asker_to_map(tuple()) :: map()
  def asker_to_map({kind, id}), do: %{"kind" => Atom.to_string(kind), "id" => id}

  @spec to_asker(term()) :: {:ok, tuple()} | :error
  def to_asker(%{"kind" => kind, "id" => id} = map) when map_size(map) == 2 do
    with {:ok, kind} <- asker_kind(kind),
         asker = {kind, id},
         true <- asker?(asker) do
      {:ok, asker}
    else
      _ -> :error
    end
  end

  def to_asker(_map), do: :error

  defp asker_kind("tool"), do: {:ok, :tool}
  defp asker_kind("hook"), do: {:ok, :hook}
  defp asker_kind("settle"), do: {:ok, :settle}
  defp asker_kind(_kind), do: :error

  @doc false
  # A path of a read of the folder: valid UTF-8 within `max_path_bytes/0`.
  @spec path?(term()) :: boolean()
  def path?(value),
    do: is_binary(value) and byte_size(value) in 1..@max_path_bytes and String.valid?(value)

  @doc false
  # A cwd goes into the session file as JSON and into the system prompt.
  def cwd?(value), do: Input.cwd(value) == {:ok, value}
end
