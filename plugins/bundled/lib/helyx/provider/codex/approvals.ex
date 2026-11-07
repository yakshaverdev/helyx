defmodule Helyx.Provider.Codex.Approvals do
  @moduledoc false
  # The server requests of the program (ADR 0013 §4,
  # `docs/research/codex-app-server.md`, "An `apply_patch` approval under
  # `untrusted` and `read-only`"). An approval request for an item of the
  # program's own tools, in a Helyx turn, goes to Core as `{:approval,
  # approval_id, item_id}`, and Core's answer goes back as `accept` or
  # `decline`. Any other server request gets the JSON-RPC error -32601,
  # which the program took as the decline of an approval.

  import Helyx.Provider.Codex.Wire

  @methods ~w(item/commandExecution/requestApproval item/fileChange/requestApproval)

  # The approval id is the JSON of the JSON-RPC id, so an integer id and a
  # string id never give one approval id. A request of a child thread goes
  # to Core too: its item is no open call of the turn, and Core denies it.
  def dispatch(%{"id" => rpc_id, "method" => method, "params" => %{"itemId" => item}}, state)
      when method in @methods and is_binary(item) and (is_integer(rpc_id) or is_binary(rpc_id)) and
             state.turn_id != nil do
    approval_id = JSON.encode!(rpc_id)

    {[{:approval, approval_id, item}],
     %{state | approvals: Map.put(state.approvals, approval_id, rpc_id)}}
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
