defmodule Helyx.Transport.WebSocket.PairingTest do
  # The links, the pairing operations, the two handshakes, and the
  # registration of a hands connection (`docs/features/remote-hands.md`,
  # "Pairing and the public listener", "Registration and lease").
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Provider.Fake
  alias Helyx.Test.TlsClient
  alias Helyx.Test.WireClient
  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.{Pairing, TLS}

  @moduletag :tmp_dir

  @token "secret"

  defp serve(context, opts \\ []) do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake]}, id: :core)
    {:ok, tls} = TLS.ensure(context.tmp_dir)

    hub =
      start_supervised!(
        Supervisor.child_spec({Hub, core: core, default_owner: "owner"}, id: :hub)
      )

    public = [ip: {127, 0, 0, 1}, port: 0, address: "127.0.0.1:0"]

    transport =
      start_supervised!(
        {WebSocket,
         [
           core: core,
           port: 0,
           token: @token,
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
      port: WebSocket.public_port(transport),
      loop: WebSocket.port(transport)
    })
  end

  # A pairing link over the loopback listener, with the server token.
  defp link(context, kind \\ "hands", name \\ "mac") do
    socket = WireClient.open(context.loop, @token)

    %{"ok" => true, "result" => %{"link" => link, "expires_ms" => expires_ms}} =
      WireClient.request(socket, "1", "pair.create", %{"kind" => kind, "name" => name})

    :gen_tcp.close(socket)
    {link, expires_ms}
  end

  defp link_parts(link) do
    "helyx-pair:1:" <> encoded = link
    JSON.decode!(Base.url_decode64!(encoded, padding: false))
  end

  defp key_pair, do: :crypto.generate_key(:eddsa, :ed25519)

  defp pair_hello(nonce, link, role, {public_key, private_key}, name \\ nil) do
    parts = link_parts(link)
    token = parts["t"]
    nonce_bytes = Base.decode64!(nonce)

    %{
      "type" => "hello",
      "protocol" => WebSocket.protocol(),
      "role" => role,
      "runner" => name || parts["n"],
      "pair" => %{
        "proof" =>
          Base.encode64(:crypto.mac(:hmac, :sha256, :crypto.hash(:sha256, token), nonce_bytes)),
        "public_key" => Base.encode64(public_key),
        "signature" =>
          Base.encode64(:crypto.sign(:eddsa, :none, nonce_bytes, [private_key, :ed25519]))
      }
    }
  end

  defp signature_hello(nonce, role, {_public_key, private_key}, name) do
    nonce_bytes = Base.decode64!(nonce)

    %{
      "type" => "hello",
      "protocol" => WebSocket.protocol(),
      "role" => role,
      "runner" => name,
      "signature" =>
        Base.encode64(:crypto.sign(:eddsa, :none, nonce_bytes, [private_key, :ed25519]))
    }
  end

  defp pair_socket(context, link, kind \\ "hands") do
    keys = key_pair()

    {socket, reply} =
      TlsClient.open(context.port, context.tls.pin, fn nonce ->
        pair_hello(nonce, link, kind, keys)
      end)

    {socket, reply, keys}
  end

  # The next frame of the server, with a WebSocket ping skipped.
  defp next(socket) do
    case TlsClient.recv(socket) do
      {:ping, _payload} -> next(socket)
      frame -> frame
    end
  end

  describe "the pairing operations on the loopback listener" do
    setup context, do: serve(context)

    test "a link carries the address, the token, the pin, the kind, and the name",
         %{tls: tls} = context do
      {link, expires_ms} = link(context, "hands", "mac")

      assert expires_ms == Pairing.link_ms()

      assert %{"a" => "127.0.0.1:0", "p" => pin, "k" => "hands", "n" => "mac", "t" => token} =
               link_parts(link)

      assert pin == tls.pin
      assert String.length(token) == 43
    end

    test "pair.list shows the peer after the pairing, and pair.revoke closes it",
         context do
      {link, _expires} = link(context)
      {peer, {:frame, %{"type" => "welcome"}}, _keys} = pair_socket(context, link)

      socket = WireClient.open(context.loop, @token)

      %{"ok" => true, "result" => %{"peers" => [peer_row]}} =
        WireClient.request(socket, "2", "pair.list", %{})

      assert %{"kind" => "hands", "name" => "mac", "connected" => true} = peer_row

      assert %{"ok" => true, "result" => %{}} =
               WireClient.request(socket, "3", "pair.revoke", %{
                 "kind" => "hands",
                 "name" => "mac"
               })

      assert %{"ok" => true, "result" => %{"peers" => []}} =
               WireClient.request(socket, "4", "pair.list", %{})

      assert {:close, 4401} = TlsClient.until_close(peer)
      :gen_tcp.close(socket)
    end

    test "pair.create with a bad name or kind answers bad_params", context do
      socket = WireClient.open(context.loop, @token)

      for params <- [
            %{"kind" => "hands", "name" => "Mac"},
            %{"kind" => "hands", "name" => "maç"},
            %{"kind" => "hands", "name" => String.duplicate("a", 65)},
            %{"kind" => "robot", "name" => "mac"},
            %{"kind" => "hands", "name" => "mac", "extra" => true}
          ] do
        assert %{"ok" => false, "error" => %{"code" => "bad_params"}} =
                 WireClient.request(socket, "1", "pair.create", params)
      end

      # A name of 64 bytes is the longest that fits.
      assert %{"ok" => true, "result" => %{"link" => _link}} =
               WireClient.request(socket, "2", "pair.create", %{
                 "kind" => "hands",
                 "name" => String.duplicate("a", 64)
               })

      :gen_tcp.close(socket)
    end

    test "a server with no public listener answers no_public_listener", _context do
      core = :"core_#{System.unique_integer([:positive])}"
      start_supervised!({Helyx.Core, name: core, plugins: [Fake]}, id: :plain_core)
      plain = start_supervised!({WebSocket, core: core, port: 0, token: @token}, id: :plain)
      socket = WireClient.open(WebSocket.port(plain), @token)

      assert %{"ok" => false, "error" => %{"code" => "no_public_listener"}} =
               WireClient.request(socket, "1", "pair.create", %{
                 "kind" => "hands",
                 "name" => "mac"
               })

      assert %{"ok" => false, "error" => %{"code" => "no_public_listener"}} =
               WireClient.request(socket, "2", "pair.list", %{})

      :gen_tcp.close(socket)
    end

    test "a Hub user token on the loopback listener cannot pair", %{tmp_dir: dir} do
      core = :"core_#{System.unique_integer([:positive])}"
      start_supervised!({Helyx.Core, name: core, plugins: [Fake]}, id: :auth_core)
      {:ok, tls} = TLS.ensure(Path.join(dir, "auth"))

      hub =
        start_supervised!(
          Supervisor.child_spec(
            {Hub, core: core, default_owner: "owner", server_token: fn -> "server" end},
            id: :auth_hub
          )
        )

      {:ok, user} = Hub.add_user(hub, "ann")
      {:ok, token} = Hub.create_token(hub, user.id, "phone")
      token_id = token |> String.split(".") |> hd()

      transport =
        start_supervised!(
          {WebSocket,
           core: core,
           port: 0,
           authority: Hub.authority(hub),
           public: [ip: {127, 0, 0, 1}, port: 0, address: "127.0.0.1:0"],
           tls: tls,
           pairing: hub},
          id: :auth_transport
        )

      port = WebSocket.port(transport)

      {:ok, socket} = WireClient.upgrade(port)
      nonce = WireClient.challenge(socket)

      WireClient.send_frame(
        socket,
        Map.merge(WireClient.hello(nonce, token), %{"token" => token_id})
      )

      assert {:frame, %{"type" => "welcome"}} = WireClient.recv(socket)

      assert %{"ok" => false, "error" => %{"code" => "forbidden"}} =
               WireClient.request(socket, "1", "pair.create", %{
                 "kind" => "hands",
                 "name" => "mac"
               })

      :gen_tcp.close(socket)

      server = WireClient.open(port, "server")

      assert %{"ok" => true, "result" => %{"link" => _link}} =
               WireClient.request(server, "2", "pair.create", %{
                 "kind" => "hands",
                 "name" => "mac"
               })

      :gen_tcp.close(server)
    end
  end

  describe "the pairing handshake on the public listener" do
    setup context, do: serve(context)

    test "a pairing, then a second connection with the key alone", %{tls: tls} = context do
      {link, _expires} = link(context)
      {socket, reply, keys} = pair_socket(context, link)
      assert {:frame, %{"type" => "welcome"}} = reply

      assert %{"ok" => true, "result" => %{"lease_ms" => lease}} =
               TlsClient.request(socket, "1", "hands.register", %{
                 "runner" => "mac",
                 "folder" => "/tmp/project"
               })

      assert lease == WebSocket.hands_lease_ms()
      :ssl.close(socket)

      {second, reply} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          signature_hello(nonce, "hands", keys, "mac")
        end)

      assert {:frame, %{"type" => "welcome"}} = reply

      assert %{"ok" => true, "result" => %{"lease_ms" => _lease}} =
               TlsClient.request(second, "2", "hands.register", %{
                 "runner" => "mac",
                 "folder" => "/tmp/project"
               })

      :ssl.close(second)
    end

    test "a wrong signature closes with 4401", %{tls: tls} = context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair_socket(context, link)
      :ssl.close(socket)

      {_public, private} = key_pair()

      {other, reply} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          signature_hello(nonce, "hands", {nil, private}, "mac")
        end)

      assert {:close, 4401} = reply
      _ = other
    end

    test "a used link closes with 4401", %{tls: tls} = context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair_socket(context, link)
      :ssl.close(socket)

      {other, reply} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          pair_hello(nonce, link, "hands", key_pair())
        end)

      assert {:close, 4401} = reply
      _ = other
    end

    test "a link of the other kind closes with 4401", %{tls: tls} = context do
      {link, _expires} = link(context, "client", "phone")

      {_socket, reply} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          pair_hello(nonce, link, "hands", key_pair(), "phone")
        end)

      assert {:close, 4401} = reply
    end

    test "a pairing with a public key that is not 32 bytes closes with 4401",
         %{tls: tls} = context do
      {link, _expires} = link(context)

      {_socket, reply} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          hello = pair_hello(nonce, link, "hands", key_pair())
          put_in(hello, ["pair", "public_key"], Base.encode64(<<1, 2, 3>>))
        end)

      assert {:close, 4401} = reply
    end

    test "pair.create on the public listener is unknown_op", %{tls: tls} = context do
      {link, _expires} = link(context, "client", "phone")

      {socket, {:frame, %{"type" => "welcome"}}} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          pair_hello(nonce, link, "client", key_pair(), "phone")
        end)

      assert %{"ok" => false, "error" => %{"code" => "unknown_op"}} =
               TlsClient.request(socket, "1", "pair.create", %{"kind" => "hands", "name" => "mac"})

      :ssl.close(socket)
    end
  end

  describe "the hands registration" do
    setup context, do: serve(context, hands_lease_ms: 30_000)

    test "a registration with another name than the hello closes with 4401", context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair_socket(context, link)

      TlsClient.send_frame(socket, %{
        "type" => "req",
        "id" => "1",
        "op" => "hands.register",
        "params" => %{"runner" => "other", "folder" => "/tmp/project"}
      })

      assert {:close, 4401} = TlsClient.until_close(socket)
    end

    test "a second registration of a name closes the first connection", %{tls: tls} = context do
      {link, _expires} = link(context)
      {first, {:frame, %{"type" => "welcome"}}, keys} = pair_socket(context, link)

      assert %{"ok" => true} =
               TlsClient.request(first, "1", "hands.register", %{
                 "runner" => "mac",
                 "folder" => "/tmp/project"
               })

      {second, {:frame, %{"type" => "welcome"}}} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          signature_hello(nonce, "hands", keys, "mac")
        end)

      assert {:close, 4401} = TlsClient.until_close(first)

      assert %{"ok" => true} =
               TlsClient.request(second, "2", "hands.register", %{
                 "runner" => "mac",
                 "folder" => "/tmp/project"
               })

      :ssl.close(second)
    end

    test "a client operation on a hands connection is unknown_op", context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair_socket(context, link)

      assert %{"ok" => false, "error" => %{"code" => "unknown_op"}} =
               TlsClient.request(socket, "1", "sessions.live", %{})

      assert %{"ok" => false, "error" => %{"code" => "unknown_op"}} =
               TlsClient.request(socket, "2", "subscribe", %{"session" => "AAAAAAAAAAAA"})

      :ssl.close(socket)
    end

    @tag :slow
    test "the lease closes a runner that answers no hands.live", context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair_socket(context, link)

      assert %{"ok" => true} =
               TlsClient.request(socket, "1", "hands.register", %{
                 "runner" => "mac",
                 "folder" => "/tmp/project"
               })

      # The server asks for liveness, and the runner sends no answer.
      assert {:frame, %{"type" => "req", "op" => "hands.live"}} = next(socket)
      assert {:close, 4408} = TlsClient.until_close(socket)
    end
  end

  describe "the lifetime and the cap of links" do
    setup context, do: serve(context)

    test "an expired link is refused, with an injected clock", context do
      clock = :counters.new(1, [])
      :counters.put(clock, 1, 0)

      {:ok, pairing} =
        Pairing.start_link(
          hub: context.hub,
          address: "127.0.0.1:0",
          pin: context.tls.pin,
          lease_ms: WebSocket.hands_lease_ms(),
          clock: fn -> :counters.get(clock, 1) end
        )

      {:ok, %{"link" => link}} = Pairing.create(pairing, "hands", "mac")
      keys = key_pair()
      nonce = :crypto.strong_rand_bytes(32)

      :counters.put(clock, 1, Pairing.link_ms() + 1)

      assert {:close, 4401} =
               Pairing.hello(
                 pairing,
                 nonce,
                 pair_hello(Base.encode64(nonce), link, "hands", keys),
                 self()
               )

      assert Pairing.list(pairing) == {:ok, []}
    end

    test "at most max_links links wait", context do
      {:ok, pairing} =
        Pairing.start_link(
          hub: context.hub,
          address: "127.0.0.1:0",
          pin: context.tls.pin,
          lease_ms: WebSocket.hands_lease_ms(),
          clock: fn -> 0 end
        )

      for n <- 1..Pairing.max_links() do
        assert {:ok, %{"link" => _link}} = Pairing.create(pairing, "hands", "mac#{n}")
      end

      assert Pairing.create(pairing, "hands", "one_too_many") == {:error, :too_many_links}
    end
  end
end
