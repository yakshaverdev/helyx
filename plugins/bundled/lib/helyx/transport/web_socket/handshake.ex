defmodule Helyx.Transport.WebSocket.Handshake do
  @moduledoc false
  # The `hello` of the public listener (`docs/features/remote-hands.md`,
  # "Pairing and the public listener"). The pairing proves the link or the
  # key of a peer; a paired client gets the credential of the default owner
  # from the authority.

  alias Helyx.Transport.WebSocket.{Authorize, Pairing}

  @spec public(map(), map()) ::
          {:ok, term(), String.t(), String.t() | nil} | {:close, 4401 | 4503}
  def public(state, hello) do
    case Pairing.hello(state.pairing, state.nonce, hello, self()) do
      {:ok, "hands", name} ->
        {:ok, nil, "hands", name}

      {:ok, "client", name} ->
        case Authorize.paired(state.authority, "client", name) do
          {:ok, auth} -> {:ok, auth, "client", nil}
          {:close, code} -> {:close, code}
        end

      {:close, code} ->
        {:close, code}
    end
  end
end
