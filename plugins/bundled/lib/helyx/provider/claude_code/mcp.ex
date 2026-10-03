defmodule Helyx.Provider.ClaudeCode.Mcp do
  @moduledoc false
  # The SDK MCP server of the Helyx tools of `Helyx.Provider.ClaudeCode`
  # (research note, "The SDK MCP server shapes"). It takes the provider
  # state, writes its answers, and keeps `calls`: the open `tools/call`
  # requests by call id, `{turn_id, control request_id, JSON-RPC id}`.

  alias Helyx.HarnessIO
  alias Helyx.Provider.ClaudeCode.{Replay, Turn}

  # The user's own MCP servers stay: the Helyx tools add to the harness
  # tools.
  @config ~s({"mcpServers":{"helyx":{"type":"sdk","name":"helyx"}}})

  def config, do: @config

  # A request has an `id`; a notification has none and gets the ack of the
  # SDK, which the program waits for (research note). `initialize` can come
  # again on one program, so it keeps no state. The answer echoes the asked
  # version (research note).
  def message(
        %{"method" => "initialize", "id" => id, "params" => %{"protocolVersion" => version}},
        request_id,
        state
      ) do
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

  # The admission (`Turn.admit/3`) records the call id first: the
  # provider's own errors do not reach the session, which records the rest.
  def message(%{"method" => "tools/call", "id" => id} = message, request_id, state) do
    params = message["params"]
    call_id = tool_use_id(params)
    {answer, turn} = Turn.admit(state.turn, call_id, fn -> mapped?(params) end)
    state = %{state | turn: turn}

    case answer do
      :ok ->
        args = Map.get(params, "arguments", %{})
        calls = Map.put(state.calls, call_id, {turn.id, request_id, id})

        {[{:event, turn.id, {:tool_request, call_id, params["name"], args}}],
         %{state | calls: calls}}

      {:error, text} ->
        tool_answer(state, request_id, id, :error, text)
    end
  end

  def message(
        %{"method" => "notifications/cancelled", "params" => %{"requestId" => rpc_id}},
        request_id,
        state
      ) do
    answer(state, request_id, %{result: %{}})

    case Enum.find(state.calls, fn {_call_id, {_turn_id, _request_id, id}} -> id == rpc_id end) do
      nil ->
        {[], state}

      {call_id, {turn_id, _request_id, _rpc_id}} ->
        {[{:cancel_tool, turn_id, call_id}], %{state | calls: Map.delete(state.calls, call_id)}}
    end
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

  defp tool_use_id(%{"_meta" => %{"claudecode/toolUseId" => call_id}}) when is_binary(call_id),
    do: call_id

  defp tool_use_id(_params), do: nil

  # The admission calls it only with a call id, so `params` is a map.
  defp mapped?(%{"name" => name} = params) when is_binary(name),
    do: is_map(Map.get(params, "arguments", %{}))

  defp mapped?(_params), do: false

  defp tool_answer(state, request_id, rpc_id, status, text) do
    result = %{content: [%{type: "text", text: text}], isError: status == :error}
    answer(state, request_id, %{id: rpc_id, result: result})
  end

  defp answer(state, request_id, message) do
    message = Map.put(message, :jsonrpc, "2.0")
    response = %{subtype: "success", request_id: request_id, response: %{mcp_response: message}}
    HarnessIO.write(state, Replay.line(%{type: "control_response", response: response}))
    {[], state}
  end
end
