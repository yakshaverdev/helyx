defmodule Helyx.Provider.Codex.Approvals do
  @moduledoc false
  # The server requests of the program (ADR 0013 §4,
  # `docs/research/codex-app-server.md`, "An `apply_patch` approval under
  # `untrusted` and `read-only`"). An approval request of the provider's
  # thread and its current turn, for an open item of the type that its
  # method names, goes to Core as `{:approval, approval_id, item_id}`, and
  # Core's answer goes back as `accept` or `decline`. Any other approval
  # request with an integer or string id, such as one of a child thread,
  # of an earlier turn, outside a Helyx turn, or for another item, is
  # declined at once, with no chain: its `itemId` could name another call
  # of the current turn, whose hooks would then decide another item. Any
  # other server request gets the JSON-RPC error -32601, which the program
  # took as the decline of an approval.

  import Helyx.Provider.Codex.Wire

  @types %{
    "item/commandExecution/requestApproval" => "commandExecution",
    "item/fileChange/requestApproval" => "fileChange"
  }

  # The approval id is the JSON of the JSON-RPC id, so an integer id and a
  # string id never give one approval id. One over 256 bytes fails the
  # stream check of Core, and the provider process stops.
  def dispatch(%{"id" => rpc_id, "method" => method} = request, state)
      when is_map_key(@types, method) and (is_integer(rpc_id) or is_binary(rpc_id)) do
    case request["params"] do
      %{"threadId" => thread, "turnId" => turn, "itemId" => item}
      when thread == state.thread and turn == state.turn and is_binary(turn) and
             :erlang.map_get(method, @types) == :erlang.map_get(item, state.items.open) and
             state.turn_id != nil ->
        approval_id = JSON.encode!(rpc_id)
        {[{:approval, approval_id, item}], put_in(state.approvals[approval_id], rpc_id)}

      _other ->
        send_line(state, %{id: rpc_id, result: %{decision: "decline"}})
        {[], state}
    end
  end

  def dispatch(%{"id" => id}, state) do
    send_line(state, %{id: id, error: %{code: -32_601, message: "not supported by Helyx"}})
    {[], state}
  end

  # Core's answer to the request `approval_id`. Core answers each request
  # once.
  def answer(state, approval_id, decision) do
    {rpc_id, approvals} = Map.pop!(state.approvals, approval_id)
    send_line(state, %{id: rpc_id, result: %{decision: decision(decision)}})
    %{state | approvals: approvals}
  end

  # A decline carries no reason: the program has no field for one.
  defp decision(:allow), do: "accept"
  defp decision({:deny, _reason}), do: "decline"
end
