defmodule Helyx.Transport.WebSocket.TLSTest do
  # The public listener and its pin (`docs/features/remote-hands.md`,
  # "Pairing and the public listener").
  use ExUnit.Case, async: true

  import Bitwise

  alias Helyx.Hub
  alias Helyx.Provider.Fake
  alias Helyx.Test.TlsClient
  alias Helyx.Test.WireClient
  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.TLS

  @moduletag :tmp_dir

  defp serve(context, opts \\ []) do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake]}, id: :core)
    {:ok, tls} = TLS.ensure(context.tmp_dir)

    hub =
      start_supervised!(
        Supervisor.child_spec(
          {Hub, core: core, default_owner: "owner"},
          id: :hub
        )
      )

    public = [ip: {127, 0, 0, 1}, port: 0, address: "127.0.0.1:0"]

    transport =
      start_supervised!(
        {WebSocket,
         [
           core: core,
           port: 0,
           token: "secret",
           public: public,
           tls: tls,
           pairing: hub
         ] ++ opts}
      )

    Map.merge(context, %{
      core: core,
      hub: hub,
      tls: tls,
      transport: transport,
      port: WebSocket.public_port(transport)
    })
  end

  describe "the certificate" do
    test "the pin is the same across two starts, and the key file has mode 0600", %{tmp_dir: dir} do
      {:ok, first} = TLS.ensure(dir)
      {:ok, second} = TLS.ensure(dir)

      assert first.pin == second.pin
      assert File.read!(first.keyfile) == File.read!(second.keyfile)
      assert File.read!(first.certfile) == File.read!(second.certfile)
      assert band(File.stat!(first.keyfile).mode, 0o777) == 0o600
    end

    test "the pin is the base64url of the SHA-256 of the SubjectPublicKeyInfo", %{tmp_dir: dir} do
      {:ok, tls} = TLS.ensure(dir)
      [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(File.read!(tls.certfile))

      assert tls.pin == TLS.pin(der)
      assert tls.pin == TLS.pin(:public_key.pkix_decode_cert(der, :otp))
      refute tls.pin =~ "="
    end
  end

  describe "the public listener" do
    setup context, do: serve(context)

    test "a client with the pin connects, and one with another pin does not", %{
      port: port,
      tls: tls
    } do
      assert {:ok, socket} = TlsClient.upgrade(port, tls.pin)
      :ssl.close(socket)
      assert {:error, _reason} = TlsClient.upgrade(port, String.duplicate("a", 43))
    end

    test "the server token is refused with 4401", %{port: port, tls: tls} do
      {:ok, socket} = TlsClient.upgrade(port, tls.pin)
      nonce = TlsClient.challenge(socket)

      TlsClient.send_frame(socket, %{
        "type" => "hello",
        "protocol" => WebSocket.protocol(),
        "proof" => WireClient.proof(nonce, "secret")
      })

      assert {:close, 4401} = TlsClient.until_close(socket)
    end

    test "a hello with no pairing proof is refused with 4401", %{port: port, tls: tls} do
      {:ok, socket} = TlsClient.upgrade(port, tls.pin)
      TlsClient.challenge(socket)

      TlsClient.send_frame(socket, %{
        "type" => "hello",
        "protocol" => WebSocket.protocol(),
        "role" => "hands",
        "runner" => "mac"
      })

      assert {:close, 4401} = TlsClient.until_close(socket)
    end

    test "a public listener with no Hub fails the start", %{tmp_dir: dir} do
      core = :"core_#{System.unique_integer([:positive])}"
      start_supervised!({Helyx.Core, name: core, plugins: [Fake]}, id: :pairing_core)
      {:ok, tls} = TLS.ensure(dir)

      assert {:error, :pairing_required} =
               WebSocket.start_link(
                 core: core,
                 port: 0,
                 public: [ip: {127, 0, 0, 1}, port: 0, address: "127.0.0.1:0"],
                 tls: tls
               )
    end
  end
end
