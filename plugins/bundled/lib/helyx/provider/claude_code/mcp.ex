defmodule Helyx.Provider.ClaudeCode.Mcp do
  @moduledoc false
  # The SDK MCP server of the Helyx tools of `Helyx.Provider.ClaudeCode`
  # (research note, "The SDK MCP server shapes"). It takes the provider
  # state, writes its answers, and keeps `calls`: the open `tools/call`
  # requests by call id, `{turn_id, control request_id, JSON-RPC id}`.

  alias Helyx.HarnessIO
  alias Helyx.Provider.ClaudeCode.Turn

  require Turn

  # The user's own MCP servers stay: the Helyx tools add to the harness
  # tools.
  @config ~s({"mcpServers":{"helyx":{"type":"sdk","name":"helyx"}}})

  def config, do: @config

  # A request has an `id`; a notification has none and gets the ack of the
  # SDK, which the program waits for (research note). `initialize` can come
  # again on one program, so it keeps no state.
  def message(%{"method" => "initialize", "id" => id} = message, request_id, state) do
    version =
      case message["params"] do
        %{"protocolVersion" => version} when is_binary(version) -> version
        _other -> "2025-11-25"
      end

    result = %{
      protocolVersion: version,
      capabilities: %{tools: %{}},
      serverInfo: %{name: "helyx", version: "0.1.0"}
    }

    answer(state, request_id, %{id: id, result: result})
  end

  def message(%{"method" => "tools/list", "id" => id}, request_id, state) do
    tools =
      for tool <- state.tools,
          do: %{name: tool.name, description: tool.description, inputSchema: tool.parameters}

    answer(state, request_id, %{id: id, result: %{tools: tools}})
  end

  # A call id of the turn is recorded in `used` before any check that
  # answers it, so an id that got any answer never runs later in the turn:
  # the provider's own errors do not reach the loop, which records the rest.
  def message(%{"method" => "tools/call", "id" => id} = message, request_id, state) do
    params = message["params"]

    case {state.turn, tool_use_id(params)} do
      # A program turn can run before `started` of the turn's line.
      {turn, _call_id} when turn == nil or not Turn.started?(turn) ->
        tool_answer(state, request_id, id, :error, "no Helyx turn is running")

      {_turn, nil} ->
        tool_answer(state, request_id, id, :error, "the call does not map to a tool use")

      {%Turn{id: turn_id, used: used}, call_id} ->
        state = put_in(state.turn.used, MapSet.put(used, call_id))

        with false <- MapSet.member?(used, call_id),
             %{"name" => name} when is_binary(name) <- params,
             args when is_map(args) <- Map.get(params, "arguments", %{}) do
          calls = Map.put(state.calls, call_id, {turn_id, request_id, id})
          {[{:event, turn_id, {:tool_request, call_id, name, args}}], %{state | calls: calls}}
        else
          true ->
            tool_answer(state, request_id, id, :error, "the call id was used before in this turn")

          _unmapped ->
            tool_answer(state, request_id, id, :error, "the call does not map to a tool use")
        end
    end
  end

  def message(
        %{"method" => "notifications/cancelled", "params" => %{"requestId" => rpc_id}},
        request_id,
        state
      ) do
    answer(state, request_id, %{result: %{}})
    cancel_call(state, fn {_turn_id, _request_id, id} -> id == rpc_id end)
  end

  def message(%{"id" => id}, request_id, state) do
    error = %{code: -32_601, message: "method not found"}
    answer(state, request_id, %{id: id, error: error})
  end

  def message(_notification, request_id, state),
    do: answer(state, request_id, %{result: %{}})

  # The result of a Helyx tool call. A call that the program withdrew has
  # no open request, and its result is not written.
  def result(state, call_id, status, text) do
    case Map.pop(state.calls, call_id) do
      {{_turn_id, request_id, rpc_id}, calls} ->
        tool_answer(state, request_id, rpc_id, status, text)
        %{state | calls: calls}

      {nil, _calls} ->
        state
    end
  end

  # The program withdrew a control request; it waits for no answer
  # (source only).
  def cancel_request(state, request_id),
    do: cancel_call(state, fn {_turn_id, id, _rpc_id} -> id == request_id end)

  defp tool_use_id(%{"_meta" => %{"claudecode/toolUseId" => call_id}}) when is_binary(call_id),
    do: call_id

  defp tool_use_id(_params), do: nil

  defp tool_answer(state, request_id, rpc_id, status, text) do
    result = %{content: [%{type: "text", text: text}], isError: status == :error}
    answer(state, request_id, %{id: rpc_id, result: result})
  end

  # Withdraws the open call that `match?` finds by its `{turn_id,
  # request_id, rpc_id}`, if any.
  defp cancel_call(state, match?) do
    case Enum.find(state.calls, fn {_call_id, call} -> match?.(call) end) do
      nil ->
        {[], state}

      {call_id, {turn_id, _request_id, _rpc_id}} ->
        {[{:cancel_tool, turn_id, call_id}], %{state | calls: Map.delete(state.calls, call_id)}}
    end
  end

  defp answer(state, request_id, message) do
    message = Map.put(message, :jsonrpc, "2.0")
    response = %{subtype: "success", request_id: request_id, response: %{mcp_response: message}}
    HarnessIO.write(state, [JSON.encode!(%{type: "control_response", response: response}), "\n"])
    {[], state}
  end
end
