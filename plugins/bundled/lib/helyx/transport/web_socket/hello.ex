defmodule Helyx.Transport.WebSocket.Hello do
  @moduledoc false
  # The handshake of a connection, as the `hello` gives it
  # (`docs/features/wire-protocol.md`, "The handshake";
  # `docs/features/remote-hands.md`, "Pairing and the public listener"): the
  # protocol number, the credential, the role, and the runner. The functions
  # read only the fields of the connection that they name: the listener, the
  # pairing, the nonce, the authority, and the key of the server token.

  alias Helyx.Transport.WebSocket.{Authorize, Frame, Pairing}

  # The protocol number first: a client of another protocol learns that it
  # must update, whatever its proof.
  def frame(state, %{"protocol" => protocol} = hello) do
    server = Helyx.Transport.WebSocket.protocol()

    if protocol != server do
      refused = %{"type" => "refused", "code" => "protocol", "server_protocol" => server}
      {:stop, {:shutdown, :closed}, 4426, texts(refused), state}
    else
      fields = Map.take(state, [:listener, :pairing, :nonce, :authority, :key])

      case authenticate(fields, hello) do
        {:ok, auth, role, runner} ->
          welcome = texts(%{"type" => "welcome", "protocol" => server})
          state = %{state | phase: :open, auth: auth, role: role, runner: runner}
          {:push, welcome, state}

        {:close, code} ->
          close(code, state)
      end
    end
  end

  # The public listener takes no server token: only a pairing link or the key
  # of a paired runner (`docs/features/remote-hands.md`, "Pairing and the
  # public listener"). The pairing validates every field of the `hello`
  # before it reads any: a client role, a runner that is not a name, and a
  # handshake of the wrong type or size close this connection with `4401`.
  def authenticate(%{listener: :public} = state, hello) do
    case Pairing.hello(state.pairing, state.nonce, hello, self()) do
      {:ok, "hands", name} -> {:ok, nil, "hands", name}
      {:close, code} -> {:close, code}
    end
  end

  # A pairing attempt on the loopback listener is not a handshake there.
  def authenticate(%{listener: :loopback} = state, hello) do
    with nil <- hello["pair"],
         nil <- hello["signature"],
         {:ok, role} <- role(hello),
         :ok <- runner(role, hello["runner"]),
         {:ok, auth} <- loopback_auth(state, hello) do
      {:ok, auth, role, hello["runner"]}
    else
      {:close, code} -> {:close, code}
      _other -> {:close, 4400}
    end
  end

  # With an authority, the authority decides the credential of the
  # connection; with none, the proof of the server token.
  defp loopback_auth(%{authority: nil} = state, hello) do
    if Authorize.proof?(state.key, state.nonce, hello["proof"]),
      do: {:ok, nil},
      else: {:close, 4401}
  end

  defp loopback_auth(state, hello), do: Authorize.hello(state.authority, state.nonce, hello)

  defp role(%{"role" => "hands"}), do: {:ok, "hands"}
  defp role(%{"role" => "client"}), do: {:ok, "client"}
  defp role(%{"role" => _other}), do: :error
  defp role(_hello), do: {:ok, "client"}

  # A hands role names its runner: the one name rule of `Pairing.name?/1`.
  defp runner("hands", name), do: if(Pairing.name?(name), do: :ok, else: :error)

  defp runner("client", _name), do: :ok
  defp runner(_role, _name), do: :error

  defp texts(frame), do: Enum.map(Frame.encode(frame), &{:text, &1})

  defp close(code, state), do: {:stop, {:shutdown, :closed}, code, state}
end
