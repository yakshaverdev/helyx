defmodule Helyx.Transport.WebSocket.Runner.Handshake do
  @moduledoc false
  # The hello of a pairing and of a paired peer
  # (`docs/features/remote-hands.md`, "The pairing handshake" and "The
  # handshake of a paired peer"). Both sign the same bytes; the private key
  # is called from its closure and never held here.

  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.Pairing
  alias Helyx.Transport.WebSocket.Runner.Prepared

  @doc "The hello of `prepared`, after the nonce of the challenge."
  @spec hello(Prepared.t()) :: (binary() -> map())
  def hello(prepared) do
    fn nonce ->
      signature = Base.encode64(prepared.sign.(signature_text(prepared, nonce)))

      hello = %{
        "type" => "hello",
        "protocol" => WebSocket.protocol(),
        "role" => "hands",
        "runner" => prepared.name
      }

      case prepared.mode do
        :pair ->
          Map.put(hello, "pair", %{
            "proof" => proof(prepared.token.(), nonce),
            "public_key" => Base.encode64(prepared.public_key),
            "signature" => signature
          })

        :name ->
          Map.put(hello, "signature", signature)
      end
    end
  end

  @doc "The bytes that both handshakes sign."
  @spec signature_text(Prepared.t(), binary()) :: binary()
  def signature_text(prepared, nonce),
    do: Pairing.signature_text(prepared.pin, "hands", prepared.name, nonce)

  @doc "The proof of the bootstrap token of the link, as the wire has it."
  @spec proof(binary(), binary()) :: String.t()
  def proof(token, nonce),
    do: Base.encode64(:crypto.mac(:hmac, :sha256, :crypto.hash(:sha256, token), nonce))
end
