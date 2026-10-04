defmodule Helyx.Provider.ClaudeCode.Mcp do
  @moduledoc false
  # The SDK MCP server of the Helyx tools of `Helyx.Provider.ClaudeCode`
  # (research note, "The SDK MCP server shapes"). It takes the provider
  # state, writes its answers, and keeps `calls`: the open `tools/call`
  # requests by call id, `{control request_id, JSON-RPC id}`.

  alias Helyx.HarnessIO
  alias Helyx.Provider.ClaudeCode.Replay

  import Helyx.Provider.ClaudeCode.Turn, only: [started?: 1]

  # The user's own MCP servers stay: the Helyx tools add to the harness
  # tools. With `alwaysLoad`, the model called a Helyx tool without a
  # harness tool search (research note, "`alwaysLoad` on the SDK MCP
  # server").
  @config ~s({"mcpServers":{"helyx":{"type":"sdk","name":"helyx","alwaysLoad":true}}})

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

  # A call with a tool use id in a started Helyx turn: a program turn can
  # run before `started` of the turn's line. The session owns the call ids
  # of the turn (#369).
  def message(%{"method" => "tools/call", "id" => id} = message, request_id, state) do
    params = message["params"]

    if helyx_call?(params, state.turn) do
      %{"_meta" => %{"claudecode/toolUseId" => call_id}, "name" => name} = params
      calls = Map.put(state.calls, call_id, {request_id, id})
      event = {:tool_request, call_id, name, Map.get(params, "arguments", %{})}
      {[{:event, state.turn.id, event}], %{state | calls: calls}}
    else
      tool_answer(state, request_id, id, :error, "the call does not map to a tool use")
    end
  end

  def message(
        %{"method" => "notifications/cancelled", "params" => %{"requestId" => rpc_id}},
        request_id,
        state
      ) do
    answer(state, request_id, %{result: %{}})

    case Enum.find(state.calls, fn {_call_id, {_request_id, id}} -> id == rpc_id end) do
      nil ->
        {[], state}

      {call_id, _ids} ->
        {[{:cancel_tool, call_id}], %{state | calls: Map.delete(state.calls, call_id)}}
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
      {{request_id, rpc_id}, calls} ->
        tool_answer(state, request_id, rpc_id, status, text)
        %{state | calls: calls}

      {nil, _calls} ->
        state
    end
  end

  defp helyx_call?(
         %{"_meta" => %{"claudecode/toolUseId" => call_id}, "name" => name} = params,
         turn
       )
       when is_binary(call_id) and is_binary(name) and started?(turn),
       do: is_map(Map.get(params, "arguments", %{}))

  defp helyx_call?(_params, _turn), do: false

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
