defmodule Helyx.Session.Hands.Term.Request do
  @moduledoc false
  # The requests to a provider process as the data of a hands term. A request is
  # a tagged map; the check and the tuple of `Helyx.Session.ProviderRequest` use
  # the same kinds.

  alias Helyx.Context
  alias Helyx.Session.Hands.Term.Data
  alias Helyx.Session.Input

  @request_kinds [:turn, :compact, :steer, :interrupt, :tool_result, :context, :approval]
  @reply_kinds @request_kinds ++ [:close, :idle_close]

  @doc false
  def reply_kind?(kind), do: kind in @reply_kinds

  @doc false
  def request?(%{kind: :turn, turn: turn, context: context} = request) do
    map_size(request) == 3 and Data.turn_id?(turn) and turn_context?(context)
  end

  def request?(%{kind: :compact, turn: turn, text: text} = request) do
    map_size(request) == 3 and Data.turn_id?(turn) and is_binary(text) and Input.text(text) == :ok
  end

  def request?(%{kind: :steer, turn: turn, steer: steer, text: text} = request) do
    map_size(request) == 4 and Data.turn_id?(turn) and Data.id?(steer) and is_binary(text) and
      Input.text(text) == :ok
  end

  def request?(%{kind: :interrupt, turn: turn} = request),
    do: map_size(request) == 2 and Data.turn_id?(turn)

  def request?(%{kind: :tool_result, turn: turn, call: call, result: result} = request) do
    map_size(request) == 4 and Data.turn_id?(turn) and Data.call_id?(call) and
      match?({status, text} when status in [:ok, :error] and is_binary(text), result)
  end

  def request?(%{kind: :context, turn: turn, result: {:ok, context}} = request),
    do: map_size(request) == 3 and Data.turn_id?(turn) and turn_context?(context)

  def request?(%{kind: :context, turn: turn, result: {:error, reason}} = request),
    do: map_size(request) == 3 and Data.turn_id?(turn) and Data.reason?(reason)

  def request?(%{kind: :approval, turn: turn, approval: approval, decision: :allow} = request),
    do: map_size(request) == 4 and Data.turn_id?(turn) and Data.call_id?(approval)

  def request?(
        %{kind: :approval, turn: turn, approval: approval, decision: {:deny, reason}} = request
      ),
      do:
        map_size(request) == 4 and Data.turn_id?(turn) and Data.call_id?(approval) and
          Data.reason?(reason)

  def request?(%{kind: kind} = request) when kind in [:close, :idle_close],
    do: map_size(request) == 1

  def request?(_request), do: false

  @doc false
  # The request that `Helyx.Session.ProviderRequest.ask/3` takes, from the
  # shape; the caller sends it to the provider process.
  @spec request_tuple(term()) :: {:ok, term()} | :error
  def request_tuple(%{kind: :turn, turn: turn, context: context}),
    do: {:ok, {:turn, turn, context}}

  def request_tuple(%{kind: :compact, turn: turn, text: text}), do: {:ok, {:compact, turn, text}}

  def request_tuple(%{kind: :steer, turn: turn, steer: steer, text: text}),
    do: {:ok, {:steer, turn, steer, text}}

  def request_tuple(%{kind: :interrupt, turn: turn}), do: {:ok, {:interrupt, turn}}

  def request_tuple(%{kind: :tool_result, turn: turn, call: call, result: {status, text}}),
    do: {:ok, {:tool_result, turn, call, {status, text}}}

  def request_tuple(%{kind: :context, turn: turn, result: {:ok, context}}),
    do: {:ok, {:context, turn, {:ok, context}}}

  def request_tuple(%{kind: :context, turn: turn, result: {:error, reason}}),
    do: {:ok, {:context, turn, {:error, reason}}}

  def request_tuple(%{kind: :approval, turn: turn, approval: approval, decision: decision}),
    do: {:ok, {:approval, turn, approval, decision}}

  def request_tuple(%{kind: :close}), do: {:ok, :close}
  def request_tuple(%{kind: :idle_close}), do: {:ok, :idle_close}
  def request_tuple(_request), do: :error

  @doc false
  @spec request_to_map(term()) :: map()
  def request_to_map(%{kind: :turn, turn: turn, context: context}),
    do: %{"kind" => "turn", "turn" => turn, "context" => turn_context_to_map(context)}

  def request_to_map(%{kind: :compact, turn: turn, text: text}),
    do: %{"kind" => "compact", "turn" => turn, "text" => text}

  def request_to_map(%{kind: :steer, turn: turn, steer: steer, text: text}),
    do: %{"kind" => "steer", "turn" => turn, "steer" => steer, "text" => text}

  def request_to_map(%{kind: :interrupt, turn: turn}),
    do: %{"kind" => "interrupt", "turn" => turn}

  def request_to_map(%{kind: :tool_result, turn: turn, call: call, result: {status, text}}),
    do: %{
      "kind" => "tool_result",
      "turn" => turn,
      "call" => call,
      "status" => Atom.to_string(status),
      "text" => text
    }

  def request_to_map(%{kind: :context, turn: turn, result: {:ok, context}}),
    do: %{"kind" => "context", "turn" => turn, "context" => turn_context_to_map(context)}

  def request_to_map(%{kind: :context, turn: turn, result: {:error, reason}}),
    do: %{"kind" => "context", "turn" => turn, "error" => reason}

  def request_to_map(%{kind: :approval, turn: turn, approval: approval, decision: :allow}),
    do: %{"kind" => "approval", "turn" => turn, "approval" => approval, "decision" => "allow"}

  def request_to_map(%{kind: :approval, turn: turn, approval: approval, decision: {:deny, text}}),
    do: %{
      "kind" => "approval",
      "turn" => turn,
      "approval" => approval,
      "decision" => "deny",
      "text" => text
    }

  def request_to_map(%{kind: :close}), do: %{"kind" => "close"}
  def request_to_map(%{kind: :idle_close}), do: %{"kind" => "idle_close"}

  @doc false
  @spec to_request(term()) :: {:ok, map()} | :error
  def to_request(%{"kind" => "turn"} = map) do
    Data.pairs(map, ~w(kind turn context), fn
      ["turn", turn, context] ->
        with {:ok, context} <- to_turn_context(context) do
          request(%{kind: :turn, turn: turn, context: context})
        end
    end)
  end

  def to_request(%{"kind" => "compact"} = map) do
    Data.pairs(map, ~w(kind turn text), fn ["compact", turn, text] ->
      request(%{kind: :compact, turn: turn, text: text})
    end)
  end

  def to_request(%{"kind" => "steer"} = map) do
    Data.pairs(map, ~w(kind turn steer text), fn ["steer", turn, steer, text] ->
      request(%{kind: :steer, turn: turn, steer: steer, text: text})
    end)
  end

  def to_request(%{"kind" => "interrupt"} = map) do
    Data.pairs(map, ~w(kind turn), fn ["interrupt", turn] ->
      request(%{kind: :interrupt, turn: turn})
    end)
  end

  def to_request(%{"kind" => "tool_result"} = map) do
    Data.pairs(map, ~w(kind turn call status text), fn
      ["tool_result", turn, call, status, text] ->
        with {:ok, status} <- status(status) do
          request(%{kind: :tool_result, turn: turn, call: call, result: {status, text}})
        end
    end)
  end

  def to_request(%{"kind" => "context"} = map) do
    with :error <- context_request(map), do: error_context_request(map)
  end

  def to_request(%{"kind" => "approval"} = map) do
    with :error <-
           Data.pairs(map, ~w(kind turn approval decision), fn
             ["approval", turn, approval, "allow"] ->
               request(%{kind: :approval, turn: turn, approval: approval, decision: :allow})

             _values ->
               :error
           end) do
      Data.pairs(map, ~w(kind turn approval decision text), fn
        ["approval", turn, approval, "deny", text] ->
          request(%{kind: :approval, turn: turn, approval: approval, decision: {:deny, text}})

        _values ->
          :error
      end)
    end
  end

  def to_request(%{"kind" => "close"} = map) when map_size(map) == 1,
    do: {:ok, %{kind: :close}}

  def to_request(%{"kind" => "idle_close"} = map) when map_size(map) == 1,
    do: {:ok, %{kind: :idle_close}}

  def to_request(_map), do: :error

  defp context_request(map) do
    case Data.values(map, ~w(kind turn context)) do
      {:ok, ["context", turn, context]} -> context_request(turn, context)
      _values -> :error
    end
  end

  defp context_request(turn, context) do
    with {:ok, context} <- to_turn_context(context) do
      request(%{kind: :context, turn: turn, result: {:ok, context}})
    end
  end

  defp error_context_request(map) do
    Data.pairs(map, ~w(kind turn error), fn ["context", turn, reason] ->
      request(%{kind: :context, turn: turn, result: {:error, reason}})
    end)
  end

  defp request(request) do
    if request?(request), do: {:ok, request}, else: :error
  end

  defp status("ok"), do: {:ok, :ok}
  defp status("error"), do: {:ok, :error}
  defp status(_status), do: :error

  # --- the context of a turn ---

  defp turn_context?(%Context{system: system, messages: messages, tools: tools} = context) do
    map_size(context) == 4 and (is_nil(system) or Data.text?(system)) and
      Data.list?(messages, &Data.message?/1) and Data.list?(tools, &Data.spec?/1)
  end

  defp turn_context?(_context), do: false

  defp turn_context_to_map(%Context{system: system, messages: messages, tools: tools}),
    do: %{
      "system" => system,
      "messages" => Enum.map(messages, &Data.message_to_map/1),
      "tools" => Enum.map(tools, &Data.spec_to_map/1)
    }

  defp to_turn_context(map) do
    Data.pairs(map, ~w(system messages tools), fn
      [system, messages, tools] when is_list(messages) and is_list(tools) ->
        to_turn_context(system, messages, tools)

      _values ->
        :error
    end)
  end

  defp to_turn_context(system, messages, tools) do
    with {:ok, messages} <- to_messages(messages),
         {:ok, tools} <- to_specs(tools) do
      context = %Context{system: system, messages: messages, tools: tools}

      if turn_context?(context), do: {:ok, context}, else: :error
    end
  end

  defp to_messages(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case Data.to_message(message) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> Data.reversed()
  end

  defp to_specs(tools) do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, acc} ->
      case Data.to_spec(tool) do
        {:ok, tool} -> {:cont, {:ok, [tool | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> Data.reversed()
  end
end
