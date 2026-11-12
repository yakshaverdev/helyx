defmodule Helyx.Transport.WebSocket.PairOps do
  @moduledoc false
  # The pairing operations of the loopback listener in the connection
  # (`docs/features/remote-hands.md`, "Make a link", "Revoke"). The worker
  # runs in its own process, so a Hub call in it does not hold the socket.

  alias Helyx.Transport.WebSocket.{Ops, Outbound, Pairing}

  # The server token, or no authority, and nothing else, may pair a peer.
  def allowed?(%{authority: nil}), do: true
  def allowed?(%{auth: %{token: nil}}), do: true
  def allowed?(_state), do: false

  # The kind client needs an authority that knows a paired peer: the paired
  # handshake asks its `paired/4` for the credential, and a link made without
  # one never works.
  def client?("pair.create", %{"kind" => "client"}, state), do: paired?(state.authority)
  def client?(_op, _params, _state), do: true

  defp paired?({mod, _arg}),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, :paired, 4)

  defp paired?(_authority), do: false

  # Starts the linked worker of one request; the connection records it as a
  # writer.
  def start(out, id, op, params, pairing) do
    spawn_link(worker(out, id, op, params, pairing))
  end

  defp worker(out, id, op, params, pairing) do
    fn ->
      answer =
        case Pairing.request(pairing, op, params) do
          {:ok, result} -> {:ok, result}
          {:error, code} -> Ops.error(op, to_string(code))
        end

      Outbound.reply(out, id, answer)
    end
  end
end
