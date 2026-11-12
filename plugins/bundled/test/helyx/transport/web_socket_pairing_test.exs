defmodule Helyx.Transport.WebSocket.PairingTest do
  # The links, the pairing operations, the two handshakes, and the
  # registration of a hands connection (`docs/features/remote-hands.md`,
  # "Pairing and the public listener", "Registration and lease").
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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
  defp link(context, name \\ "mac") do
    socket = WireClient.open(context.loop, @token)

    %{"ok" => true, "result" => %{"link" => link, "expires_ms" => expires_ms}} =
      WireClient.request(socket, "1", "pair.create", %{"kind" => "hands", "name" => name})

    :gen_tcp.close(socket)
    {link, expires_ms}
  end

  defp link_parts(link) do
    "helyx-pair:1:" <> encoded = link
    JSON.decode!(Base.url_decode64!(encoded, padding: false))
  end

  defp key_pair, do: :crypto.generate_key(:eddsa, :ed25519)

  defp pair_hello(nonce, link, keys \\ nil) do
    keys = keys || key_pair()
    {public_key, private_key} = keys
    parts = link_parts(link)
    token = parts["t"]
    nonce_bytes = Base.decode64!(nonce)
    text = Pairing.signature_text(parts["p"], parts["k"], parts["n"], nonce_bytes)

    hello = %{
      "type" => "hello",
      "protocol" => WebSocket.protocol(),
      "role" => parts["k"],
      "runner" => parts["n"],
      "pair" => %{
        "proof" =>
          Base.encode64(:crypto.mac(:hmac, :sha256, :crypto.hash(:sha256, token), nonce_bytes)),
        "public_key" => Base.encode64(public_key),
        "signature" => Base.encode64(:crypto.sign(:eddsa, :none, text, [private_key, :ed25519]))
      }
    }

    {hello, keys}
  end

  # A pairing hello of a link, for one connection.
  defp hello(link) do
    fn nonce ->
      {hello, _keys} = pair_hello(nonce, link)
      hello
    end
  end

  defp signature_hello(nonce, pin, {_public_key, private_key}, name) do
    nonce_bytes = Base.decode64!(nonce)
    text = Pairing.signature_text(pin, "hands", name, nonce_bytes)

    %{
      "type" => "hello",
      "protocol" => WebSocket.protocol(),
      "role" => "hands",
      "runner" => name,
      "signature" => Base.encode64(:crypto.sign(:eddsa, :none, text, [private_key, :ed25519]))
    }
  end

  # The next frame of the server, with a WebSocket ping skipped.
  defp next(socket) do
    case TlsClient.recv(socket) do
      {:ping, _payload} -> next(socket)
      frame -> frame
    end
  end

  defp pairing(context) do
    children = Supervisor.which_children(context.transport)
    {_, pid, :worker, _} = List.keyfind(children, Pairing, 0)
    pid
  end

  defp conn_state(context, name) do
    %{connections: connections} = :sys.get_state(pairing(context))
    {conn, _monitor} = Map.fetch!(connections, {"hands", name})

    {_socket, %{connection: %Bandit.WebSocket.Connection{websock_state: state}}} =
      :sys.get_state(conn)

    state
  end

  describe "the pairing operations on the loopback listener" do
    setup context, do: serve(context)

    test "a link carries the address, the token, the pin, the kind, and the name",
         %{tls: tls} = context do
      {link, expires_ms} = link(context)

      assert expires_ms == Pairing.link_ms()

      assert %{"a" => "127.0.0.1:0", "p" => pin, "k" => "hands", "n" => "mac", "t" => token} =
               link_parts(link)

      assert pin == tls.pin
      assert String.length(token) == 43
    end

    test "pair.list shows the peer after the pairing, and pair.revoke closes it", context do
      {link, _expires} = link(context)
      peer = TlsClient.open(context.port, context.tls.pin, hello(link))

      {_socket, {:frame, %{"type" => "welcome"}}} = peer

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

      assert {:close, 4401} = TlsClient.until_close(elem(peer, 0))
      :gen_tcp.close(socket)
    end

    test "pair.revoke closes a connection whose row is gone", context do
      {link, _expires} = link(context)

      {peer, {:frame, %{"type" => "welcome"}}} =
        TlsClient.open(context.port, context.tls.pin, hello(link))

      # The operator path deletes the row and does not own the connection.
      assert :ok = Hub.revoke_peer(context.hub, "hands", "mac")

      socket = WireClient.open(context.loop, @token)

      assert %{"ok" => true, "result" => %{}} =
               WireClient.request(socket, "1", "pair.revoke", %{
                 "kind" => "hands",
                 "name" => "mac"
               })

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

    test "the public gate takes no place of the loopback listener", context do
      # Fill the public gate with upgrades that send no `hello`: each holds
      # its place until the hello wait ends.
      public =
        for _ <- 1..WebSocket.max_connections() do
          {:ok, socket} = TlsClient.upgrade(context.port, context.tls.pin)
          socket
        end

      loop = WireClient.open(context.loop, @token)
      assert %{"ok" => true} = WireClient.request(loop, "1", "sessions.live", %{})
      :gen_tcp.close(loop)
      Enum.each(public, &:ssl.close/1)
    end

    test "pair.revoke with a kind or name that is not a string is bad_params", context do
      socket = WireClient.open(context.loop, @token)

      for params <- [%{"kind" => 1, "name" => 2}, %{"kind" => "hands", "name" => 2}] do
        assert %{"ok" => false, "error" => %{"code" => "bad_params"}} =
                 WireClient.request(socket, "1", "pair.revoke", params)
      end

      # The pairing process and both listeners still serve.
      assert %{"ok" => true} = WireClient.request(socket, "2", "sessions.live", %{})
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
      {socket, reply, keys} = pair(context, link)
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
          signature_hello(nonce, tls.pin, keys, "mac")
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
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, link)
      :ssl.close(socket)

      {_public, private} = key_pair()

      {other, reply} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          signature_hello(nonce, tls.pin, {nil, private}, "mac")
        end)

      assert {:close, 4401} = reply
      _ = other
    end

    test "a signature over the nonce alone is refused", %{tls: tls} = context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, keys} = pair(context, link)
      :ssl.close(socket)
      {_public, private} = keys

      {_other, reply} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          %{
            "type" => "hello",
            "protocol" => WebSocket.protocol(),
            "role" => "hands",
            "runner" => "mac",
            "signature" =>
              Base.encode64(
                :crypto.sign(:eddsa, :none, Base.decode64!(nonce), [private, :ed25519])
              )
          }
        end)

      assert {:close, 4401} = reply
    end

    test "a signature for another name is refused", %{tls: tls} = context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, keys} = pair(context, link)
      :ssl.close(socket)

      {_other, reply} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          signature_hello(nonce, tls.pin, keys, "other")
        end)

      assert {:close, 4401} = reply
    end

    test "a used link closes with 4401", %{tls: tls} = context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, link)
      :ssl.close(socket)

      {_other, reply} = TlsClient.open(context.port, tls.pin, hello(link))
      assert {:close, 4401} = reply
    end

    test "a pairing with a public key that is not 32 bytes closes with 4401",
         %{tls: tls} = context do
      {link, _expires} = link(context)

      {_socket, reply} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          {hello, _keys} = pair_hello(nonce, link)
          put_in(hello, ["pair", "public_key"], Base.encode64(<<1, 2, 3>>))
        end)

      assert {:close, 4401} = reply
    end

    test "a bad hello closes only that connection", context do
      for hello <- [
            %{"role" => "client", "signature" => "AAAA"},
            %{
              "role" => "hands",
              "runner" => 12,
              "pair" => %{"proof" => "AAAA", "public_key" => "AAAA", "signature" => "AAAA"}
            },
            %{"role" => "hands", "runner" => "mac", "pair" => "AAAA"}
          ] do
        {:ok, socket} = TlsClient.upgrade(context.port, context.tls.pin)
        TlsClient.challenge(socket)

        TlsClient.send_frame(
          socket,
          Map.merge(%{"type" => "hello", "protocol" => WebSocket.protocol()}, hello)
        )

        assert {:close, 4401} = TlsClient.until_close(socket)
      end

      # The loopback listener of the same transport still answers.
      loop = WireClient.open(context.loop, @token)
      assert %{"ok" => true} = WireClient.request(loop, "1", "sessions.live", %{})
      :gen_tcp.close(loop)
    end

    @tag :slow
    test "a Hub that does not answer closes with 4503, not a connection crash",
         %{tls: tls} = context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, keys} = pair(context, link)
      :ssl.close(socket)

      :sys.suspend(context.hub)

      try do
        {_other, reply} =
          TlsClient.open(context.port, tls.pin, fn nonce ->
            signature_hello(nonce, tls.pin, keys, "mac")
          end)

        assert {:close, 4503} = reply
      after
        :sys.resume(context.hub)
      end
    end

    test "pair.create on the public listener is unknown_op", %{tls: tls} = context do
      {link, _expires} = link(context)

      {socket, {:frame, %{"type" => "welcome"}}} =
        TlsClient.open(context.port, tls.pin, hello(link))

      assert %{"ok" => false, "error" => %{"code" => "unknown_op"}} =
               TlsClient.request(socket, "1", "pair.create", %{"kind" => "hands", "name" => "mac"})

      :ssl.close(socket)
    end

    test "each listener has its own connection gate", context do
      children = Supervisor.which_children(context.transport)
      {_, loop_gate, :worker, _} = List.keyfind(children, Helyx.Transport.WebSocket.Gate, 0)
      {_, public_gate, :worker, _} = List.keyfind(children, :public_gate, 0)
      assert loop_gate != public_gate
      assert WebSocket.max_connections() == 64
    end
  end

  describe "the hands registration" do
    setup context, do: serve(context, hands_lease_ms: 30_000)

    test "a registration with another name than the hello closes with 4401", context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, link)

      TlsClient.send_frame(socket, %{
        "type" => "req",
        "id" => "1",
        "op" => "hands.register",
        "params" => %{"runner" => "other", "folder" => "/tmp/project"}
      })

      assert {:close, 4401} = TlsClient.until_close(socket)
    end

    test "a second registration on one connection is bad_params", context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, link)

      assert %{"ok" => true} =
               TlsClient.request(socket, "1", "hands.register", %{
                 "runner" => "mac",
                 "folder" => "/tmp/project"
               })

      assert %{"ok" => false, "error" => %{"code" => "bad_params"}} =
               TlsClient.request(socket, "2", "hands.register", %{
                 "runner" => "mac",
                 "folder" => "/tmp/project"
               })

      :ssl.close(socket)
    end

    test "a second registration of a name closes the first connection", %{tls: tls} = context do
      {link, _expires} = link(context)
      {first, {:frame, %{"type" => "welcome"}}, keys} = pair(context, link)

      assert %{"ok" => true} =
               TlsClient.request(first, "1", "hands.register", %{
                 "runner" => "mac",
                 "folder" => "/tmp/project"
               })

      {second, {:frame, %{"type" => "welcome"}}} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          signature_hello(nonce, tls.pin, keys, "mac")
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
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, link)

      assert %{"ok" => false, "error" => %{"code" => "unknown_op"}} =
               TlsClient.request(socket, "1", "sessions.live", %{})

      assert %{"ok" => false, "error" => %{"code" => "unknown_op"}} =
               TlsClient.request(socket, "2", "subscribe", %{"session" => "AAAAAAAAAAAA"})

      :ssl.close(socket)
    end

    test "an answer to no open hands.live does not renew the lease", context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, link)

      assert %{"ok" => true} =
               TlsClient.request(socket, "1", "hands.register", %{
                 "runner" => "mac",
                 "folder" => "/tmp/project"
               })

      before = conn_state(context, "mac")
      assert before.live_id == nil

      TlsClient.send_frame(socket, %{
        "type" => "res",
        "id" => "hands.live:0",
        "ok" => true,
        "result" => %{"seq" => 0}
      })

      # A request after it proves that the connection took the answer; the
      # frames of one connection keep their order.
      assert %{"ok" => false, "error" => %{"code" => "unknown_op"}} =
               TlsClient.request(socket, "2", "sessions.live", %{})

      after_answer = conn_state(context, "mac")
      assert after_answer.lease_at == before.lease_at

      :ssl.close(socket)
    end

    @tag :slow
    test "the lease closes a runner that answers no hands.live", context do
      {link, _expires} = link(context)
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, link)

      assert %{"ok" => true} =
               TlsClient.request(socket, "1", "hands.register", %{
                 "runner" => "mac",
                 "folder" => "/tmp/project"
               })

      # The server asks for liveness, and the runner sends no answer. The
      # connection is silent past the HTTP request bound of the public
      # listener; the lease, not that bound, closes it.
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
      nonce = :crypto.strong_rand_bytes(32)
      {hello, _keys} = pair_hello(Base.encode64(nonce), link)

      :counters.put(clock, 1, Pairing.link_ms() + 1)

      assert {:close, 4401} = Pairing.hello(pairing, nonce, hello, self())
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

  describe "a Hub that does not answer, and the state of the links" do
    setup context, do: serve(context)

    test "a pairing closes with 4503 when the Hub does not answer", context do
      {:ok, pairing} =
        Pairing.start_link(
          hub: :no_such_hub,
          address: "127.0.0.1:0",
          pin: context.tls.pin,
          lease_ms: WebSocket.hands_lease_ms(),
          clock: fn -> 0 end
        )

      {:ok, %{"link" => link}} = Pairing.create(pairing, "hands", "mac")
      nonce = :crypto.strong_rand_bytes(32)
      {hello, _keys} = pair_hello(Base.encode64(nonce), link)

      assert {:close, 4503} = Pairing.hello(pairing, nonce, hello, self())
    end

    test "a link is not consumed for a caller that dies during the Hub call", context do
      {:ok, pairing} =
        Pairing.start_link(
          hub: context.hub,
          address: "127.0.0.1:0",
          pin: context.tls.pin,
          lease_ms: WebSocket.hands_lease_ms(),
          clock: fn -> 0 end
        )

      {:ok, %{"link" => link}} = Pairing.create(pairing, "hands", "mac")
      nonce = :crypto.strong_rand_bytes(32)
      {hello, _keys} = pair_hello(Base.encode64(nonce), link)

      :sys.suspend(context.hub)

      caller = spawn(fn -> Pairing.hello(pairing, nonce, hello, self()) end)
      # The Hub is suspended, so the Hub call of the Pairing stays in its
      # mailbox; the caller dies before the row is written.
      Helyx.Test.Events.wait_until(fn ->
        {:message_queue_len, n} = Process.info(GenServer.whereis(context.hub), :message_queue_len)
        n > 0
      end)

      Process.exit(caller, :kill)
      :sys.resume(context.hub)

      # The hello of the dead caller ends; the link is still pending.
      assert {:ok, _peers} = Pairing.list(pairing)
      nonce2 = :crypto.strong_rand_bytes(32)
      {hello2, _keys2} = pair_hello(Base.encode64(nonce2), link)

      assert {:ok, "hands", "mac"} = Pairing.hello(pairing, nonce2, hello2, self())
    end

    test "the link hash is out of the state and out of a crash report", context do
      {:ok, pairing} =
        Pairing.start_link(
          hub: context.hub,
          address: "127.0.0.1:0",
          pin: context.tls.pin,
          lease_ms: WebSocket.hands_lease_ms(),
          clock: fn -> 0 end
        )

      {:ok, %{"link" => link}} = Pairing.create(pairing, "hands", "mac")
      {:ok, %{"link" => client_link}} = Pairing.create(pairing, "client", "phone")
      %{"t" => token} = link_parts(link)
      %{"t" => client_token} = link_parts(client_link)
      hash = Base.encode16(:crypto.hash(:sha256, token))
      client_hash = Base.encode16(:crypto.hash(:sha256, client_token))

      for secret <- [token, client_token, hash, client_hash] do
        refute inspect(:sys.get_state(pairing)) =~ secret
      end

      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          send(pairing, :boom)
          assert_receive {:EXIT, ^pairing, _reason}
        end)

      for secret <- [token, client_token, hash, client_hash] do
        refute log =~ secret
      end
    end
  end

  # A pairing over TLS, its welcome, and the keys that paired.
  defp pair(context, link) do
    keys = key_pair()

    {socket, reply} =
      TlsClient.open(context.port, context.tls.pin, fn nonce ->
        {hello, _keys} = pair_hello(nonce, link, keys)
        hello
      end)

    {socket, reply, keys}
  end
end
