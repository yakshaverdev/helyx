defmodule Helyx.Transport.WebSocket.PairingClientTest do
  # The kind `client` of a link, of the pairing `hello`, and of the handshake
  # of a paired client, which acts as the default owner of the Hub
  # (`docs/features/remote-hands.md`, "Slices" P7).
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
        Supervisor.child_spec(
          {Hub,
           core: core,
           default_owner: "owner",
           server_token: fn -> @token end,
           path: Path.join(context.tmp_dir, "hub.db")},
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
           authority: Hub.authority(hub),
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

  # A link of a kind, made by the operator on the loopback listener.
  defp link(context, kind, name) do
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

  # A pairing hello of a link, with the kind of the link or another role.
  # The signature covers the kind and the name of the link.
  defp pair_hello(nonce, link, keys \\ nil, role \\ nil) do
    keys = keys || key_pair()
    {public_key, private_key} = keys
    parts = link_parts(link)
    role = role || parts["k"]
    nonce_bytes = Base.decode64!(nonce)
    text = Pairing.signature_text(parts["p"], parts["k"], parts["n"], nonce_bytes)

    hello =
      %{
        "type" => "hello",
        "protocol" => WebSocket.protocol(),
        "role" => role,
        "pair" => %{
          "proof" =>
            Base.encode64(
              :crypto.mac(:hmac, :sha256, :crypto.hash(:sha256, parts["t"]), nonce_bytes)
            ),
          "public_key" => Base.encode64(public_key),
          "signature" => Base.encode64(:crypto.sign(:eddsa, :none, text, [private_key, :ed25519]))
        }
      }
      |> name(role, parts["n"])

    {hello, keys}
  end

  # The hello of a paired peer. `role` and `name` are the fields of the
  # `hello`; `signed_kind` and `signed_name` are the kind and the name of
  # the signature text, which name the row that the server reads.
  defp signature_hello(nonce, pin, keys, role, name, signed_kind \\ nil, signed_name \\ nil) do
    {_public_key, private_key} = keys
    nonce_bytes = Base.decode64!(nonce)
    text = Pairing.signature_text(pin, signed_kind || role, signed_name || name, nonce_bytes)

    %{
      "type" => "hello",
      "protocol" => WebSocket.protocol(),
      "signature" => Base.encode64(:crypto.sign(:eddsa, :none, text, [private_key, :ed25519]))
    }
    |> name(role, name)
  end

  defp name(hello, "hands", name), do: Map.merge(hello, %{"role" => "hands", "runner" => name})
  defp name(hello, "client", name), do: Map.merge(hello, %{"role" => "client", "client" => name})

  # A paired client connection of a name whose key is `keys`.
  defp open(context, name, keys) do
    {socket, reply} =
      TlsClient.open(context.port, context.tls.pin, fn nonce ->
        signature_hello(nonce, context.tls.pin, keys, "client", name)
      end)

    {socket, reply, keys}
  end

  # A pairing over TLS, its welcome, and the keys that paired.
  defp pair(context, link, role \\ nil) do
    keys = key_pair()

    {socket, reply} =
      TlsClient.open(context.port, context.tls.pin, fn nonce ->
        {hello, _keys} = pair_hello(nonce, link, keys, role)
        hello
      end)

    {socket, reply, keys}
  end

  # A client pairing over TLS: a link of the name, then its welcome.
  defp open_as_new(context, name) do
    {link, _expires} = link(context, "client", name)
    pair(context, link)
  end

  describe "a client pairing" do
    setup context, do: serve(context)

    test "the link has the kind client, the hello gets welcome, and pair.list shows it",
         %{tls: tls} = context do
      {link, expires_ms} = link(context, "client", "phone")
      assert expires_ms == Pairing.link_ms()
      assert %{"k" => "client", "n" => "phone", "p" => pin} = link_parts(link)
      assert pin == tls.pin

      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, link)

      operator = WireClient.open(context.loop, @token)

      assert %{"ok" => true, "result" => %{"peers" => [row]}} =
               WireClient.request(operator, "2", "pair.list", %{})

      assert %{"kind" => "client", "name" => "phone", "connected" => true} = row
      :gen_tcp.close(operator)
      :ssl.close(socket)
    end

    test "a second connection with the key alone gets welcome", context do
      {socket, {:frame, %{"type" => "welcome"}}, keys} = open_as_new(context, "phone")
      :ssl.close(socket)

      {second, reply, _keys} = open(context, "phone", keys)
      assert {:frame, %{"type" => "welcome"}} = reply
      :ssl.close(second)
    end

    test "a wrong signature, another kind, another name, and no row close with 4401",
         %{tls: tls} = context do
      {_link, _expires} = link(context, "client", "phone")
      {socket, {:frame, %{"type" => "welcome"}}, keys} = open_as_new(context, "phone")
      :ssl.close(socket)

      {_other_public, other_private} = key_pair()

      hellos = [
        # A wrong key.
        fn nonce ->
          signature_hello(nonce, tls.pin, {nil, other_private}, "client", "phone")
        end,
        # The right key text, but a signature for the kind hands.
        fn nonce -> signature_hello(nonce, tls.pin, keys, "client", "phone", "hands") end,
        # The right key, but a signature for another name.
        fn nonce -> signature_hello(nonce, tls.pin, keys, "client", "phone", nil, "other") end,
        # A key with no row.
        fn nonce -> signature_hello(nonce, tls.pin, keys, "client", "tablet") end
      ]

      for hello <- hellos do
        {_bad, reply} = TlsClient.open(context.port, tls.pin, hello)
        assert {:close, 4401} = reply
      end
    end

    test "a used link closes with 4401", %{tls: tls} = context do
      {link, _expires} = link(context, "client", "phone")
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, link)
      :ssl.close(socket)

      {_other, reply} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          {hello, _keys} = pair_hello(nonce, link)
          hello
        end)

      assert {:close, 4401} = reply
    end

    test "an expired link is refused", context do
      clock = :counters.new(1, [])
      :counters.put(clock, 1, 0)
      {:ok, pairing} = direct_pairing(context, fn -> :counters.get(clock, 1) end)

      {:ok, %{"link" => link}} = Pairing.create(pairing, "client", "phone")
      nonce = :crypto.strong_rand_bytes(32)
      {hello, _keys} = pair_hello(Base.encode64(nonce), link)

      :counters.put(clock, 1, Pairing.link_ms() + 1)

      assert {:close, 4401} = Pairing.hello(pairing, nonce, hello, self())
      assert Pairing.list(pairing) == {:ok, []}
    end

    test "a link of another kind with the other role is 4401 and does not consume it", context do
      {hands_link, _expires} = link(context, "hands", "mac")
      {_other, reply, _keys} = pair(context, hands_link, "client")
      assert {:close, 4401} = reply

      # The same link still pairs with its own role.
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, hands_link)
      :ssl.close(socket)

      {client_link, _expires} = link(context, "client", "phone")
      {_other, reply, _keys} = pair(context, client_link, "hands")
      assert {:close, 4401} = reply

      {second, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, client_link)
      :ssl.close(second)
    end

    test "a pairing of the same name replaces the key, and the old key no longer connects",
         %{tls: tls} = context do
      {first, {:frame, %{"type" => "welcome"}}, old_keys} = open_as_new(context, "phone")

      {second, {:frame, %{"type" => "welcome"}}, new_keys} = open_as_new(context, "phone")
      assert {:close, 4401} = TlsClient.until_close(first)
      :ssl.close(second)

      {_old, reply} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          signature_hello(nonce, tls.pin, old_keys, "client", "phone")
        end)

      assert {:close, 4401} = reply

      {third, reply} =
        TlsClient.open(context.port, tls.pin, fn nonce ->
          signature_hello(nonce, tls.pin, new_keys, "client", "phone")
        end)

      assert {:frame, %{"type" => "welcome"}} = reply
      :ssl.close(third)
    end

    test "a client hello with neither a pair nor a signature closes with 4401",
         %{tls: tls} = context do
      # The second hello carries the proof of the server token and no
      # handshake: the public listener still refuses it.
      for proof? <- [false, true] do
        {:ok, socket} = TlsClient.upgrade(context.port, tls.pin)
        nonce = TlsClient.challenge(socket)

        hello = %{
          "type" => "hello",
          "protocol" => WebSocket.protocol(),
          "role" => "client",
          "client" => "phone"
        }

        hello =
          if proof?, do: Map.put(hello, "proof", WireClient.proof(nonce, @token)), else: hello

        TlsClient.send_frame(socket, hello)
        assert {:close, 4401} = TlsClient.until_close(socket)
      end
    end

    test "a client link needs an authority that knows a paired peer", context do
      public = [ip: {127, 0, 0, 1}, port: 0, address: "127.0.0.1:0"]

      transport =
        start_supervised!(
          {WebSocket,
           [
             core: context.core,
             port: 0,
             token: @token,
             public: public,
             tls: context.tls,
             pairing: context.hub
           ]},
          id: :no_authority_transport
        )

      socket = WireClient.open(WebSocket.port(transport), @token)

      assert %{"ok" => false, "error" => %{"code" => "bad_params"}} =
               WireClient.request(socket, "1", "pair.create", %{
                 "kind" => "client",
                 "name" => "phone"
               })

      assert %{"ok" => true, "result" => %{"link" => _link}} =
               WireClient.request(socket, "2", "pair.create", %{
                 "kind" => "hands",
                 "name" => "mac"
               })

      :gen_tcp.close(socket)
    end

    test "a paired hello whose authority is busy closes with 4503", context do
      keys = key_pair()
      {public_key, _private_key} = keys

      assert :ok =
               Hub.put_peer(
                 context.hub,
                 %{kind: "client", name: "phone", public_key: public_key, created_at: 0},
                 Hub.max_peers()
               )

      public = [ip: {127, 0, 0, 1}, port: 0, address: "127.0.0.1:0"]

      transport =
        start_supervised!(
          {WebSocket,
           [
             core: context.core,
             port: 0,
             authority: {Helyx.Test.BusyAuthority, nil},
             public: public,
             tls: context.tls,
             pairing: context.hub
           ]},
          id: :busy_authority_transport
        )

      {_socket, reply} =
        TlsClient.open(WebSocket.public_port(transport), context.tls.pin, fn nonce ->
          signature_hello(nonce, context.tls.pin, keys, "client", "phone")
        end)

      assert {:close, 4503} = reply
    end

    test "a Hub that does not answer closes the pairing hello with 4503", context do
      {:ok, pairing} =
        Pairing.start_link(
          hub: :no_such_hub,
          address: "127.0.0.1:0",
          pin: context.tls.pin,
          lease_ms: WebSocket.hands_lease_ms(),
          clock: fn -> 0 end
        )

      {:ok, %{"link" => link}} = Pairing.create(pairing, "client", "phone")
      nonce = :crypto.strong_rand_bytes(32)
      {hello, _keys} = pair_hello(Base.encode64(nonce), link)

      assert {:close, 4503} = Pairing.hello(pairing, nonce, hello, self())
    end
  end

  describe "the authority of a paired client" do
    setup context, do: serve(context)

    test "it is the default owner: it starts, lists, and follows a session", context do
      server = WireClient.open(context.loop, @token)

      %{"result" => %{"session" => server_session}} =
        WireClient.request(server, "1", "start", %{
          "cwd" => context.tmp_dir,
          "model" => "fake/echo"
        })

      {socket, {:frame, %{"type" => "welcome"}}, _keys} = open_as_new(context, "phone")

      assert %{"result" => %{"session" => client_session}} =
               TlsClient.request(socket, "1", "start", %{
                 "cwd" => context.tmp_dir,
                 "model" => "fake/echo"
               })

      assert %{"result" => %{"sessions" => lines}} =
               TlsClient.request(socket, "2", "sessions.live", %{})

      ids = Enum.map(lines, & &1["id"])
      assert server_session in ids
      assert client_session in ids

      # It follows the session of the server token and its own: a subscribe
      # reads a session that the default owner may read.
      assert %{"result" => %{"snapshot" => _snapshot}} =
               TlsClient.request(socket, "3", "subscribe", %{
                 "session" => server_session
               })

      assert %{"result" => %{"snapshot" => _snapshot}} =
               TlsClient.request(socket, "4", "subscribe", %{
                 "session" => client_session
               })

      # The same user that the server token gives.
      assert %{"result" => %{"user" => %{"name" => "owner"}}} =
               TlsClient.request(socket, "5", "hub.me", %{})

      :ssl.close(socket)
      :gen_tcp.close(server)
    end

    test "the operator operations are unknown_op", context do
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = open_as_new(context, "phone")

      for {id, op, params} <- [
            {"1", "pair.create", %{"kind" => "client", "name" => "phone"}},
            {"2", "pair.revoke", %{"kind" => "client", "name" => "phone"}},
            {"3", "pair.list", %{}}
          ] do
        assert %{"ok" => false, "error" => %{"code" => "unknown_op"}} =
                 TlsClient.request(socket, id, op, params)
      end

      :ssl.close(socket)
    end

    test "hands.register on a paired client is unknown_op", context do
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = open_as_new(context, "phone")

      assert %{"ok" => false, "error" => %{"code" => "unknown_op"}} =
               TlsClient.request(socket, "1", "hands.register", %{
                 "runner" => "phone",
                 "folder" => "/tmp/project"
               })

      :ssl.close(socket)
    end

    test "a revoke closes a connection with a subscription open, and no frame follows",
         context do
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = open_as_new(context, "phone")

      assert %{"result" => %{"session" => id}} =
               TlsClient.request(socket, "1", "start", %{
                 "cwd" => context.tmp_dir,
                 "model" => "fake/echo"
               })

      assert %{"ok" => true} =
               TlsClient.request(socket, "2", "subscribe", %{"session" => id})

      operator = WireClient.open(context.loop, @token)

      assert %{"ok" => true, "result" => %{}} =
               WireClient.request(operator, "3", "pair.revoke", %{
                 "kind" => "client",
                 "name" => "phone"
               })

      :gen_tcp.close(operator)
      assert {:close, 4401} = TlsClient.until_close(socket)
      assert {:error, _reason} = TlsClient.recv(socket)
    end

    test "a change of access to private closes a paired client too", context do
      ann = ann(context)
      ann_conn = open_token(context, ann.token)

      assert %{"result" => %{"session" => id}} =
               WireClient.request(ann_conn, "1", "start", %{
                 "cwd" => context.tmp_dir,
                 "model" => "fake/echo"
               })

      assert %{"ok" => true} =
               WireClient.request(ann_conn, "2", "hub.records.update", %{
                 "session" => id,
                 "visibility" => "hub"
               })

      server = WireClient.open(context.loop, @token)

      assert %{"ok" => true} =
               WireClient.request(server, "3", "subscribe", %{"session" => id})

      {socket, {:frame, %{"type" => "welcome"}}, _keys} = open_as_new(context, "phone")

      assert %{"ok" => true} =
               TlsClient.request(socket, "4", "subscribe", %{"session" => id})

      assert %{"ok" => true} =
               WireClient.request(ann_conn, "5", "hub.records.update", %{
                 "session" => id,
                 "visibility" => "private"
               })

      # The next turn of the private session reaches no closed connection.
      assert %{"ok" => true} =
               WireClient.request(ann_conn, "6", "prompt", %{"session" => id, "text" => "next"})

      assert {:close, 4403} = TlsClient.until_close(socket)
      assert {:close, 4403} = WireClient.until_close(server)

      # No frame of the next turn of the private session reaches the client.
      assert {:error, _reason} = TlsClient.recv(socket)
      :gen_tcp.close(ann_conn)
    end

    test "a record delete that takes read access closes a paired client too", context do
      ann = ann(context)
      ann_conn = open_token(context, ann.token)

      assert %{"result" => %{"session" => id}} =
               WireClient.request(ann_conn, "1", "start", %{
                 "cwd" => context.tmp_dir,
                 "model" => "fake/echo"
               })

      assert %{"ok" => true} =
               WireClient.request(ann_conn, "2", "hub.records.update", %{
                 "session" => id,
                 "visibility" => "hub"
               })

      {socket, {:frame, %{"type" => "welcome"}}, _keys} = open_as_new(context, "phone")

      assert %{"ok" => true} =
               TlsClient.request(socket, "3", "subscribe", %{"session" => id})

      # A stopped session with no file has no derived record: the delete
      # takes read access from every user but its owner.
      assert %{"ok" => true} = WireClient.request(ann_conn, "4", "stop", %{"session" => id})

      assert %{"ok" => true} =
               WireClient.request(ann_conn, "5", "hub.records.delete", %{"session" => id})

      assert {:close, 4403} = TlsClient.until_close(socket)
      :gen_tcp.close(ann_conn)
    end

    test "a revoke closes the connection at once and the key no longer connects", context do
      {socket, {:frame, %{"type" => "welcome"}}, keys} = open_as_new(context, "phone")

      operator = WireClient.open(context.loop, @token)

      assert %{"ok" => true, "result" => %{}} =
               WireClient.request(operator, "2", "pair.revoke", %{
                 "kind" => "client",
                 "name" => "phone"
               })

      :gen_tcp.close(operator)
      assert {:close, 4401} = TlsClient.until_close(socket)

      {_other, reply} =
        TlsClient.open(context.port, context.tls.pin, fn nonce ->
          signature_hello(nonce, context.tls.pin, keys, "client", "phone")
        end)

      assert {:close, 4401} = reply
    end

    test "a second connection of the same name closes the first", context do
      {first, {:frame, %{"type" => "welcome"}}, keys} = open_as_new(context, "phone")

      {second, reply, _keys} = open(context, "phone", keys)
      assert {:frame, %{"type" => "welcome"}} = reply
      assert {:close, 4401} = TlsClient.until_close(first)
      :ssl.close(second)
    end

    test "a client and a runner of the same name both pair and both show", context do
      {hands_link, _expires} = link(context, "hands", "same")
      {runner, {:frame, %{"type" => "welcome"}}, _runner_keys} = pair(context, hands_link)
      :ssl.close(runner)

      {client_link, _expires} = link(context, "client", "same")
      {client, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, client_link)

      operator = WireClient.open(context.loop, @token)

      assert %{"ok" => true, "result" => %{"peers" => rows}} =
               WireClient.request(operator, "2", "pair.list", %{})

      kinds = for %{"kind" => kind, "name" => "same"} <- rows, do: kind
      assert Enum.sort(kinds) == ["client", "hands"]

      :gen_tcp.close(operator)
      :ssl.close(client)
    end

    test "max_peers counts both kinds", context do
      for n <- 1..(Hub.max_peers() - 1) do
        peer = %{
          kind: "hands",
          name: "r#{n}",
          public_key: :crypto.strong_rand_bytes(32),
          created_at: 0
        }

        assert :ok = Hub.put_peer(context.hub, peer, Hub.max_peers())
      end

      # The 64th row, a client, fits.
      {client, {:frame, %{"type" => "welcome"}}, _keys} = open_as_new(context, "phone")
      :ssl.close(client)

      # A runner over the cap closes with 4401, and its link stays unused.
      {hands_link, _expires} = link(context, "hands", "one_more")
      {_over, reply, _keys} = pair(context, hands_link)
      assert {:close, 4401} = reply

      # A row goes, and the same link pairs.
      assert :ok = Hub.revoke_peer(context.hub, "client", "phone")
      {socket, {:frame, %{"type" => "welcome"}}, _keys} = pair(context, hands_link)
      :ssl.close(socket)
    end
  end

  # A Pairing process of the Hub of the test, with an injected clock.
  defp direct_pairing(context, clock) do
    Pairing.start_link(
      hub: context.hub,
      address: "127.0.0.1:0",
      pin: context.tls.pin,
      lease_ms: WebSocket.hands_lease_ms(),
      clock: clock
    )
  end

  # A user of the Hub and a token of that user.
  defp ann(context) do
    {:ok, user} = Hub.add_user(context.hub, "ann")
    {:ok, token} = Hub.create_token(context.hub, user.id, "laptop")
    %{id: user.id, token: token}
  end

  # A connection of the loopback listener that proved the token of a user.
  defp open_token(context, token) do
    {:ok, socket} = WireClient.upgrade(context.loop)

    hello =
      Map.put(WireClient.hello(WireClient.challenge(socket), token), "token", token_id(token))

    WireClient.send_frame(socket, hello)
    {:frame, %{"type" => "welcome"}} = WireClient.recv(socket)
    socket
  end

  defp token_id(token), do: hd(String.split(token, "."))
end
