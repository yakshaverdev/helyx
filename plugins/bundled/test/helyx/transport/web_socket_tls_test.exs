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
    test "the pin is the same across two starts, the folder is 0700, and the key file 0600", %{
      tmp_dir: dir
    } do
      {:ok, first} = TLS.ensure(dir)
      {:ok, second} = TLS.ensure(dir)

      assert first.pin == second.pin
      assert File.read!(first.keyfile) == File.read!(second.keyfile)
      assert File.read!(first.certfile) == File.read!(second.certfile)
      assert band(File.stat!(first.keyfile).mode, 0o777) == 0o600
      assert band(File.stat!(Path.dirname(first.keyfile)).mode, 0o777) == 0o700
    end

    test "a loose mode of an existing key file is corrected", %{tmp_dir: dir} do
      {:ok, tls} = TLS.ensure(dir)
      :ok = File.chmod(tls.keyfile, 0o644)

      assert {:ok, again} = TLS.ensure(dir)
      assert again.pin == tls.pin
      assert band(File.stat!(tls.keyfile).mode, 0o777) == 0o600
    end

    test "a cut key is an error that names the key, and makes no new key", %{tmp_dir: dir} do
      {:ok, tls} = TLS.ensure(dir)
      key = File.read!(tls.keyfile)
      cut = binary_part(key, 0, 40)
      :ok = File.write(tls.keyfile, cut)

      assert {:error, {:tls_file, path, :bad_pem}} = TLS.ensure(dir)
      assert path == tls.keyfile
      assert File.read!(tls.keyfile) == cut
    end

    test "a key with no certificate is an error that names the certificate", %{tmp_dir: dir} do
      {:ok, tls} = TLS.ensure(dir)
      key = File.read!(tls.keyfile)
      :ok = File.rm(tls.certfile)

      assert {:error, {:tls_file, path, :enoent}} = TLS.ensure(dir)
      assert path == tls.certfile
      assert File.read!(tls.keyfile) == key
    end

    test "a certificate of another key is an error that names the certificate", %{tmp_dir: dir} do
      {:ok, tls} = TLS.ensure(dir)
      {:ok, other} = TLS.ensure(Path.join(dir, "other"))
      :ok = File.cp(other.certfile, tls.certfile)

      assert {:error, {:tls_file, path, :mismatch}} = TLS.ensure(dir)
      assert path == tls.certfile
    end

    test "a valid armor with bad content is the same error", %{tmp_dir: dir} do
      {:ok, tls} = TLS.ensure(dir)

      :ok =
        File.write(
          tls.keyfile,
          "-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----\n"
        )

      assert {:error, {:tls_file, path, :bad_pem}} = TLS.ensure(dir)
      assert path == tls.keyfile
    end

    test "only a missing pair makes a new key", %{tmp_dir: dir} do
      {:ok, tls} = TLS.ensure(dir)
      :ok = File.rm(tls.keyfile)
      :ok = File.rm(tls.certfile)

      assert {:ok, new} = TLS.ensure(dir)
      assert new.pin != tls.pin
      assert File.exists?(new.keyfile)
      assert File.exists?(new.certfile)
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

    test "the public listener accepts TLS 1.3 only", %{port: port, tls: tls} do
      assert {:error, _reason} = TlsClient.connect(port, tls.pin, versions: [:"tlsv1.2"])
      assert {:ok, socket} = TlsClient.connect(port, tls.pin, versions: [:"tlsv1.3"])
      :ssl.close(socket)
    end

    test "the public listener answers 404 on a webhook path", %{port: port, tls: tls} do
      {:ok, socket} = TlsClient.connect(port, tls.pin)

      :ok =
        :ssl.send(socket, [
          "POST /hooks/AAAAAAAAAAAA HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n"
        ])

      assert {:ok, line} = :ssl.recv(socket, 0, 5_000)
      assert line =~ " 404 "
      :ssl.close(socket)
    end

    @tag :slow
    test "a TLS connection that sends no HTTP request closes at handshake_ms", %{
      port: port,
      tls: tls
    } do
      {:ok, socket} = TlsClient.connect(port, tls.pin)

      assert {:ok, line} = :ssl.recv(socket, 0, TLS.handshake_ms() + 5_000)
      assert line =~ "408"
      assert :ok = drain(socket, 5)
      :ssl.close(socket)
    end

    @tag :slow
    test "a TLS connection that sends no ClientHello closes at handshake_ms", %{port: port} do
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      assert {:error, :closed} = :gen_tcp.recv(socket, 0, TLS.handshake_ms() + 5_000)
      :gen_tcp.close(socket)
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

  # The lines of a response, then the close of the server.
  defp drain(_socket, 0), do: :no_close

  defp drain(socket, left) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, _line} -> drain(socket, left - 1)
      {:error, :closed} -> :ok
    end
  end
end
