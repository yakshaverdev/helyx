defmodule Helyx.Transport.WebSocketTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Helyx.Provider.Fake
  alias Helyx.Test.Events
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.{Frame, Ops, Outbound}

  @doc_path Path.expand("../../../../../docs/features/wire-protocol.md", __DIR__)

  defp serve(context, opts \\ []) do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake]})
    transport = start_supervised!({WebSocket, [core: core, port: 0] ++ opts})
    Map.merge(context, %{core: core, port: WebSocket.port(transport), transport: transport})
  end

  defp schema(text) do
    [_, rest] = String.split(text, "<!-- wire-schema:start -->\n")
    [schema, _] = String.split(rest, "<!-- wire-schema:end -->")
    schema
  end

  defp sha256(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)

  describe "the schema fingerprint" do
    test "the schema of the wire doc has the SHA-256 of the protocol number" do
      assert sha256(schema(File.read!(@doc_path))) == WebSocket.schema_sha256()
    end

    test "a schema change without a new number fails the check" do
      changed = String.replace(schema(File.read!(@doc_path)), "\"busy\"", "\"busier\"")
      refute sha256(changed) == WebSocket.schema_sha256()
    end
  end

  describe "the upgrade" do
    setup context, do: serve(context, origins: ["https://app.example"])

    test "an Origin outside the list gets 403, a listed one and none upgrade", %{port: port} do
      assert {:http, 403} = Client.upgrade(port, [{"origin", "https://evil.example"}])
      assert {:ok, _socket} = Client.upgrade(port, [{"origin", "https://app.example"}])
      assert {:ok, _socket} = Client.upgrade(port)
    end

    test "a refused upgrade closes at once, and its hello is not logged", %{port: port} do
      hello = JSON.encode!(Map.put(Client.hello(nil, nil), "proof", "fake"))
      # The bytes after a refusal would be the next HTTP request.
      next = [Client.text_frame(hello), "\r\n"]

      for {version, origin, after_bytes} <- [
            {13, "https://evil.example", next},
            {12, "https://app.example", next},
            {13, "https://evil.example", []}
          ] do
        {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
        request = Client.upgrade_request([{"origin", origin}], version)

        log =
          capture_log(fn ->
            :ok = :gen_tcp.send(socket, [request, after_bytes])
            assert [_status] = Regex.scan(~r"HTTP/1.1 ", until_closed(socket, ""))
          end)

        refute log =~ "Bandit.HTTPError"
      end
    end

    test "an HTTP/2 connection closes, and its frames are not logged", %{port: port} do
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      log =
        capture_log(fn ->
          :ok =
            :gen_tcp.send(socket, [
              "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
              # An empty SETTINGS frame, then a frame of an unknown type.
              <<0::24, 4, 0, 0::32>>,
              <<6::24, 0x2A, 0, 0::32, "secret">>
            ])

          assert "" = until_closed(socket, "")
        end)

      refute log =~ "secret"
    end

    test "the 65th connection gets 503 and closes at once, and a closed one frees its place",
         %{port: port} do
      sockets = for _ <- 1..64, do: elem(Client.upgrade(port), 1)
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      # The bytes after a refusal would be the next HTTP request.
      hello = JSON.encode!(Map.put(Client.hello(nil, nil), "proof", "fake"))

      log =
        capture_log(fn ->
          :ok =
            :gen_tcp.send(socket, [Client.upgrade_request([]), Client.text_frame(hello), "\r\n"])

          assert ["HTTP/1.1 503"] =
                   Regex.scan(~r"HTTP/1.1 \d+", until_closed(socket, "")) |> List.flatten()
        end)

      refute log =~ "Bandit.HTTPError"
      :gen_tcp.close(hd(sockets))
      Events.wait_until(fn -> match?({:ok, _}, Client.upgrade(port)) end)
    end
  end

  test "a bind outside loopback needs a token, and a bad token or origin list is refused" do
    assert {:error, :token_required} =
             WebSocket.start_link(core: :none, port: 0, ip: {0, 0, 0, 0})

    for opts <- [[token: 7], [token: ""], [origins: "https://a.example"], [origins: [:a]]] do
      assert {:error, :invalid_options} = WebSocket.start_link([core: :none, port: 0] ++ opts)
    end

    # The same checks through `child_spec/1`, which gives the token in a closure.
    for {opts, error} <- [{[token: 7], :invalid_options}, {[token: nil], :token_required}] do
      %{start: {module, fun, [args]}} =
        WebSocket.child_spec([core: :none, port: 0, ip: {0, 0, 0, 0}] ++ opts)

      assert {:error, ^error} = apply(module, fun, [args])
    end
  end

  describe "the hello" do
    setup context, do: serve(context, token: "secret")

    test "the proof of the token gets welcome", context do
      assert Client.open(context.port, "secret")
    end

    test "a token that is a closure starts under a supervisor and takes its proof", context do
      opts = [core: context.core, port: 0, token: fn -> "closed" end]
      transport = start_supervised!({WebSocket, opts}, id: :closure)
      assert Client.open(WebSocket.port(transport), "closed")
    end

    test "a missing or wrong proof, or the proof of another nonce, closes with 4401", context do
      {:ok, other} = Client.upgrade(context.port)
      stale = Client.proof(Client.challenge(other), "secret")

      for hello <- [
            &Client.hello(&1, nil),
            &Map.put(Client.hello(&1, nil), "proof", "wrong"),
            &Map.put(Client.hello(&1, nil), "proof", 7),
            &Map.put(Client.hello(&1, nil), "proof", stale),
            &Client.hello(&1, "secreT")
          ] do
        {:ok, socket} = Client.upgrade(context.port)
        hello = hello.(Client.challenge(socket))
        Client.send_frame(socket, hello)
        assert {:close, 4401} = Client.recv(socket)
      end
    end

    test "a second hello closes with 4400", %{port: port} do
      socket = Client.open(port, "secret")
      Client.send_frame(socket, Client.hello(nonce(), "secret"))
      assert {:close, 4400} = Client.recv(socket)
    end

    test "the challenge is 32 random bytes, one for each connection", %{port: port} do
      nonces =
        for _ <- 1..2 do
          {:ok, socket} = Client.upgrade(port)
          Base.decode64!(Client.challenge(socket))
        end

      assert [<<_::binary-size(32)>>, <<_::binary-size(32)>>] = nonces
      assert Enum.uniq(nonces) == nonces
    end

    test "another protocol number gets refused and 4426, before the proof", %{port: port} do
      {:ok, socket} = Client.upgrade(port)
      # A client of protocol 1 sends no proof; it learns that it must update.
      hello = Client.hello(Client.challenge(socket), nil)
      Client.send_frame(socket, %{hello | "protocol" => 1})

      assert {:frame, %{"type" => "refused", "code" => "protocol", "server_protocol" => 3}} ==
               Client.recv(socket)

      assert {:close, 4426} = Client.recv(socket)
    end

    test "a frame before welcome, a protocol that is not an integer >= 0, bad JSON or a byte after it, or a binary frame closes with 4400",
         %{port: port} do
      hello = Map.put(Client.hello(nil, nil), "proof", "fake")
      [hello_part | _] = parts(Map.put(hello, "pad", String.duplicate("p", 1_048_576)))

      for send <- [
            &Client.send_frame(&1, %{"type" => "req", "id" => "1", "op" => "x", "params" => %{}}),
            &Client.send_frame(&1, %{hello | "protocol" => -1}),
            &Client.send_frame(&1, %{hello | "protocol" => 2.0}),
            &Client.send_frame(&1, %{hello | "protocol" => "2"}),
            # A byte after the JSON value; whitespace passes.
            &Client.send_text(&1, JSON.encode!(hello) <> " x"),
            # A hello as parts: a client that gave no proof gets no buffer.
            &Client.send_text(&1, hello_part),
            &Client.send_frame(&1, %{
              "type" => "part",
              "n" => 0,
              "last" => true,
              "data" => Base.encode64(JSON.encode!(hello))
            }),
            &Client.send_text(&1, "{"),
            &Client.send_text(&1, "{}", 2)
          ] do
        {:ok, socket} = Client.upgrade(port)
        Client.challenge(socket)
        send.(socket)
        assert {:close, 4400} = Client.recv(socket)
      end
    end

    test "a bad frame around the hello logs nothing that holds its bytes", context do
      %{port: port, transport: transport} = context

      # Not UTF-8; a continuation with no frame before it; an unknown opcode;
      # an empty continuation that is not the last.
      for {packet, code} <- [
            {&Client.text_frame(binary_part(&1, 0, byte_size(&1) - 2) <> <<0xFF, ?", ?}>>), 4400},
            {&[Client.text_frame(&1), Client.masked_frame(1, 0, "")], 1002},
            {&[Client.text_frame(&1), Client.masked_frame(1, 3, "")], 1002},
            {&[Client.masked_frame(0, 1, &1), Client.masked_frame(0, 0, "")], 1008}
          ] do
        {:ok, socket} = Client.upgrade(port)
        hello = JSON.encode!(Client.hello(Client.challenge(socket), "secret"))
        [connection] = connections(transport)
        ref = Process.monitor(connection)

        log =
          capture_log(fn ->
            :ok = :gen_tcp.send(socket, packet.(hello))
            assert_receive {:DOWN, ^ref, :process, ^connection, _reason}
          end)

        assert {:close, ^code} = Client.until_close(socket)
        refute log =~ inspect(connection)
        refute log =~ "deserializing"
      end
    end

    @tag :slow
    test "no hello within 5,000 ms closes with 4401", %{port: port} do
      {:ok, socket} = Client.upgrade(port)
      Client.challenge(socket)
      assert {:close, 4401} = Client.recv(socket, 10_000)
    end
  end

  # A log handler that sends each raw event, metadata too, to the test.
  # A formatter prints less than the event holds.
  def log(event, %{config: %{test: pid}}), do: send(pid, {:log_event, event})

  describe "no log, option, or process state holds the token or the key" do
    setup context do
      token = "token-" <> Base.encode16(:crypto.strong_rand_bytes(16))
      id = :"wire_log_#{System.unique_integer([:positive])}"
      :ok = :logger.add_handler(id, __MODULE__, %{config: %{test: self()}})
      on_exit(fn -> :logger.remove_handler(id) end)
      serve(Map.put(context, :token, token), token: token)
    end

    test "a socket error stops with a crash report that holds a hello in fragments", context do
      {:ok, socket} = Client.upgrade(context.port)
      %{"proof" => proof} = hello = Client.hello(Client.challenge(socket), context.token)
      # The first fragment waits in the fragment buffer of the WebSocket server.
      :ok = :gen_tcp.send(socket, Client.masked_frame(0, 1, JSON.encode!(hello), <<0::32>>))
      [connection] = connections(context.transport)
      Events.wait_until(fn -> inspect(:sys.get_state(connection)) =~ proof end)
      {raw_socket, _state} = :sys.get_state(connection)

      capture_log(fn ->
        send(connection, {:tcp_error, raw_socket.socket, :etimedout})
        assert_logged([proof], context.token)
      end)
    end

    test "a handshake that raises logs its conn, with the bytes after the request", context do
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", context.port, [:binary, active: false])
      hello = Client.hello(nonce(), "x")
      request = Client.upgrade_request([{"sec-websocket-extensions", ";"}])
      frame = Client.masked_frame(1, 1, JSON.encode!(hello), <<0::32>>)

      capture_log(fn ->
        :ok = :gen_tcp.send(socket, [request, frame])
        assert_logged([hello["proof"]], context.token)
      end)
    end

    test "a TLS packet on the clear channel logs the plug options", context do
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", context.port, [:binary, active: false])

      capture_log(fn ->
        :ok = :gen_tcp.send(socket, <<22, 3, 1>>)

        assert_logged(
          ["looks like TLS", "Helyx.Transport.WebSocket, %{", "#Function<"],
          context.token
        )
      end)
    end

    test "the state of each process and the child spec hold the key only in a closure",
         context do
      socket = Client.open(context.port, context.token)
      assert %{"ok" => true} = Client.request(socket, "1", "sessions.live", %{})

      states =
        for pid <- tree(context.transport) do
          {:dictionary, dictionary} = Process.info(pid, :dictionary)
          # A supervisor or a gen process; an acceptor takes no system message.
          case dictionary[:"$initial_call"] do
            {m, f, 1} when m == :supervisor or f == :init -> :sys.get_state(pid)
            _task -> nil
          end
        end

      spec = WebSocket.child_spec(core: :core, port: 0, token: context.token)
      text = full_inspect({states, spec})
      assert text =~ "Helyx.Transport.WebSocket.Connection"
      assert text =~ "#Function<"
      refute_secret(text, context.token)
    end
  end

  defp nonce, do: Base.encode64(:crypto.strong_rand_bytes(32))

  # Every process under the transport supervisor.
  defp tree(sup) do
    Enum.flat_map(Supervisor.which_children(sup), fn
      {_id, pid, :supervisor, _} when is_pid(pid) -> [pid | tree(pid)]
      {_id, pid, :worker, _} when is_pid(pid) -> [pid]
      _restarting -> []
    end)
  end

  # Waits for a log event that holds each text of `shown`, which proves that
  # the path ran, and checks that the event holds no form of the token or the
  # key.
  defp assert_logged(shown, token) do
    assert_receive {:log_event, event}
    text = full_inspect(event)

    if Enum.all?(shown, &String.contains?(text, &1)) do
      refute_secret(text, token)
    else
      assert_logged(shown, token)
    end
  end

  # A binary with a byte that is not printable shows as bytes in the first
  # form, and as text in the second.
  defp full_inspect(term) do
    opts = [limit: :infinity, printable_limit: :infinity]
    inspect(term, opts) <> inspect(term, [binaries: :as_strings] ++ opts)
  end

  # The token, and the key as bytes, as Elixir and Erlang print them, and in
  # base16 and base64.
  defp refute_secret(text, token) do
    key = :crypto.hash(:sha256, token)

    for form <- [
          token,
          key,
          inspect(key, limit: :infinity),
          inspect(key, binaries: :as_strings),
          IO.chardata_to_string(:io_lib.format(~c"~w", [key])),
          Base.encode16(key),
          Base.encode16(key, case: :lower),
          Base.encode64(key)
        ] do
      refute String.contains?(text, form), "the log holds a form of the token or the key"
    end
  end

  describe "requests" do
    setup context, do: serve(context)

    test "a server with no token takes a hello with any proof", %{port: port} do
      for proof <- ["fake", 7, %{}] do
        {:ok, socket} = Client.upgrade(port)

        Client.send_frame(
          socket,
          Map.put(Client.hello(Client.challenge(socket), nil), "proof", proof)
        )

        assert {:frame, %{"type" => "welcome", "protocol" => 3}} = Client.recv(socket)
      end
    end

    test "a session starts, takes a prompt, is live, and stops", %{port: port} do
      socket = Client.open(port)

      assert %{"ok" => true, "result" => %{"session" => id}} =
               Client.request(socket, "1", "start", %{
                 "cwd" => File.cwd!(),
                 "model" => "fake/echo"
               })

      assert %{"ok" => true} =
               Client.request(socket, "2", "prompt", %{"session" => id, "text" => "hi"})

      assert %{
               "ok" => true,
               "result" => %{"sessions" => [%{"id" => ^id, "model" => "fake/echo"}]}
             } =
               Client.request(socket, "3", "sessions.live", %{})

      assert %{"ok" => true} = Client.request(socket, "4", "stop", %{"session" => id})

      assert %{"ok" => false, "error" => %{"code" => "session_not_found"}} =
               Client.request(socket, "5", "abort", %{"session" => id})
    end

    test "an unknown op, a bad param, and an unknown key get their errors", %{port: port} do
      socket = Client.open(port)
      assert %{"error" => %{"code" => "unknown_op"}} = Client.request(socket, "1", "nope", %{})
      assert %{"error" => %{"code" => "bad_params"}} = Client.request(socket, "2", "abort", %{})

      assert %{"error" => %{"code" => "bad_params"}} =
               Client.request(socket, "3", "sessions.live", %{"x" => 1})

      assert %{"error" => %{"code" => "bad_params"}} =
               Client.request(socket, String.duplicate("i", 65), "sessions.live", %{})

      assert %{"ok" => true} =
               Client.request(socket, String.duplicate("i", 64), "sessions.live", %{})
    end

    test "a request id whose reply was not sent closes with 4400", %{port: port, core: core} do
      socket = Client.open(port)
      {:ok, session} = Helyx.Sessions.start(core, cwd: File.cwd!(), model: "fake/echo")
      pid = Helyx.Session.pid(session)
      # The first request waits while the session is suspended.
      :erlang.suspend_process(pid)

      req = %{
        "type" => "req",
        "id" => "1",
        "op" => "abort",
        "params" => %{"session" => session.id}
      }

      Client.send_frame(socket, req)
      Client.send_frame(socket, req)
      assert {:close, 4400} = Client.recv(socket)
      :erlang.resume_process(pid)
    end

    test "a close ends the connection process: a request after it in one packet does not run",
         %{port: port, core: core, transport: transport} do
      socket = Client.open(port)
      {:ok, session} = Helyx.Sessions.start(core, cwd: File.cwd!(), model: "fake/echo")
      pid = Helyx.Session.pid(session)
      :ok = :sys.suspend(pid)

      abort = %{
        "type" => "req",
        "id" => "1",
        "op" => "abort",
        "params" => %{"session" => session.id}
      }

      :ok =
        :gen_tcp.send(socket, [Client.text_frame("{"), Client.text_frame(JSON.encode!(abort))])

      assert {:close, 4400} = Client.recv(socket)

      Events.wait_until(fn -> connections(transport) == [] end)
      assert {:messages, []} = Process.info(pid, :messages)
      :ok = :sys.resume(pid)
    end

    test "a req with no readable id closes with 4400", %{port: port} do
      socket = Client.open(port)
      Client.send_frame(socket, %{"type" => "req", "op" => "sessions.live", "params" => %{}})
      assert {:close, 4400} = Client.recv(socket)
    end

    test "a text over 1 MiB goes as parts, cut inside a UTF-8 character", %{port: port} do
      socket = Client.open(port)
      # The first piece of 786,000 bytes ends inside an "é".
      json =
        Enum.find_value(0..1, fn pad ->
          text = String.duplicate("a", 700_000 + pad) <> String.duplicate("é", 300_000)
          params = %{"session" => "none", "text" => text}

          json =
            JSON.encode!(%{"type" => "req", "id" => "1", "op" => "prompt", "params" => params})

          if not String.valid?(binary_part(json, 0, 786_000)), do: json
        end)

      for part <- parts(JSON.decode!(json)), do: Client.send_text(socket, part)
      assert %{"error" => %{"code" => "session_not_found"}} = Client.res(socket, "1")
    end

    test "a part out of order closes with 4400", %{port: port} do
      socket = Client.open(port)

      [first, _second | _] =
        parts(%{"type" => "x", "t" => String.duplicate("x", 2_000_000)})

      Client.send_text(socket, first)
      Client.send_text(socket, first)
      assert {:close, 4400} = Client.recv(socket)
    end

    test "parts that join to 25 MiB and one byte under pass", %{port: port} do
      socket = Client.open(port)

      for {size, id} <- [{26_214_400, "at"}, {26_214_399, "under"}] do
        req =
          JSON.encode!(%{"type" => "req", "id" => id, "op" => "sessions.live", "params" => %{}})

        send_parts(socket, req <> String.duplicate(" ", size - byte_size(req)))
        assert %{"ok" => true} = Client.res(socket, id)
      end
    end

    test "an integer over the largest BEAM integer closes with 4400, as bad JSON", %{port: port} do
      socket = Client.open(port)
      # Every integer of 1,262,592 digits decodes; 1,262,593 nines are over the
      # largest integer of the BEAM (OTP 28), so only parts carry them.
      req = fn id, digits ->
        ~s({"type":"req","id":"#{id}","op":"sessions.live","params":{},"n":) <>
          String.duplicate("9", digits) <> "}"
      end

      send_parts(socket, req.("at", 1_262_592))
      assert %{"ok" => true} = Client.res(socket, "at")
      send_parts(socket, req.("over", 1_262_593))
      assert {:close, 4400} = Client.recv(socket)
    end

    test "parts joined over 25 MiB close with 4413", %{port: port} do
      socket = Client.open(port)
      piece = Base.encode64(String.duplicate("x", 786_000))

      # 33 pieces are 25,938,000 bytes; the 34th passes 26,214,400.
      for n <- 0..33 do
        Client.send_frame(socket, %{"type" => "part", "n" => n, "last" => false, "data" => piece})
      end

      assert {:close, 4413} = Client.recv(socket)
    end

    test "a WebSocket frame at 1 MiB passes, one over it closes with 1009", %{port: port} do
      socket = Client.open(port)
      at = JSON.encode!(%{"type" => "req", "id" => "1", "op" => "sessions.live", "params" => %{}})
      Client.send_text(socket, at <> String.duplicate(" ", 1_048_576 - byte_size(at)))
      assert %{"ok" => true} = Client.res(socket, "1")
      under = String.replace(at, ~s("id":"1"), ~s("id":"2"))
      Client.send_text(socket, under <> String.duplicate(" ", 1_048_575 - byte_size(under)))
      assert %{"ok" => true} = Client.res(socket, "2")

      # Only the header goes: the close comes before the payload, and no
      # unread payload resets the socket before the client reads the close.
      :ok = :gen_tcp.send(socket, <<0x81, 1::1, 127::7, 1_048_577::64, 0::32>>)
      assert {:close, 1009} = Client.recv(socket)
    end

    test "a crash of the connection process closes with 1011", %{port: port, transport: transport} do
      socket = Client.open(port)
      [connection] = connections(transport)

      capture_log(fn ->
        # A message that no clause takes: a bug.
        send(connection, :bug)
        assert {:close, 1011} = Client.until_close(socket)
      end)
    end

    test "a message of fragments over 1 MiB closes with 1009, one at 1 MiB passes", %{port: port} do
      socket = Client.open(port)
      at = JSON.encode!(%{"type" => "req", "id" => "1", "op" => "sessions.live", "params" => %{}})
      pad = String.duplicate(" ", 1_048_576 - byte_size(at))
      Client.send_fragments(socket, [at, pad])
      assert %{"ok" => true} = Client.res(socket, "1")

      Client.send_fragments(socket, [at, pad <> " "])
      assert {:close, 1009} = Client.recv(socket)
    end
  end

  # The idle check reads the clock, and a deadline timer fires, within this
  # time of the test.
  @load_ms 1_000

  @tag :slow
  test "a request leaves no deadline timer after its reply", context do
    %{port: port, transport: transport} = serve(context)
    socket = Client.open(port)
    [connection] = connections(transport)
    :erlang.trace(connection, true, [:receive])

    for n <- 1..50 do
      params = %{"session" => "none", "model" => "fake/echo"}
      assert %{"ok" => false} = Client.request(socket, "#{n}", "set_model", params)
    end

    refute_receive {:trace, ^connection, :receive, {:deadline, _pid, _id}},
                   Ops.deadline("set_model") + @load_ms
  end

  test "45,000 ms with no inbound frame or pong closes with 4408" do
    now = System.monotonic_time(:millisecond)
    connection = Helyx.Transport.WebSocket.Connection

    assert {:stop, {:shutdown, :closed}, 4408, _state} =
             connection.handle_info(:idle, %{last_in: now - 45_000})

    assert {:ok, _state} = connection.handle_info(:idle, %{last_in: now - 45_000 + @load_ms})
  end

  test "the outbound queue closes with 4408 at an add over 64 MiB, not at one at it" do
    out = Outbound.new(self())
    frame = %{"type" => "x"}
    size = IO.iodata_length(JSON.encode_to_iodata!(frame))
    :atomics.put(out.bytes, 1, 67_108_864)
    assert :ok = Outbound.add(out, frame)
    assert_received {:out, _texts, ^size}
    assert :full = Outbound.add(out, frame)
    assert_received {:close, 4408}

    # The connection takes the frame it got; the count of the `:full` add
    # stays, as the connection closes.
    Outbound.taken(out, 67_108_864 + size)
    assert :atomics.get(out.bytes, 1) == size
  end

  test "the deadlines of abort and stop follow the Core bounds of the docs" do
    # Two hands releases, the armed kill of an idle close, and a margin.
    abort =
      2 * Helyx.Session.Hands.State.release_ms() +
        Helyx.Session.Server.State.provider_close_ms() + 1_000

    assert Ops.deadline("abort") == abort
    assert Ops.deadline("stop") == abort + Helyx.Session.Server.Stop.shutdown_ms()
  end

  test "a subscribe with no tail gets the tail of 200" do
    assert {:ok, _session, [tail: 200]} = Ops.subscribe_params(:core, %{"session" => "s"})
  end

  @tag :slow
  test "the server pings every 15,000 ms", context do
    %{port: port} = serve(context)
    socket = Client.open(port)
    assert {:ping, ""} = Client.recv(socket, 20_000)
  end

  describe "parts" do
    test "a frame at 1 MiB goes whole, one over it as parts that join to it" do
      at = %{"t" => String.duplicate("a", 1_048_576 - 8)}
      assert [json] = Frame.encode(at)
      assert IO.iodata_length(json) == 1_048_576

      over = %{"type" => "x", "t" => String.duplicate("é", 1_048_576)}
      texts = over |> Frame.encode() |> Enum.map(&IO.iodata_to_binary/1)
      assert length(texts) == 3
      assert Enum.all?(texts, &(byte_size(&1) < 1_048_576))

      joined =
        Enum.reduce(texts, nil, fn text, parts ->
          case Frame.decode(text, parts) do
            {:more, parts} -> parts
            {:joined, frame} -> frame
          end
        end)

      assert joined == over
    end
  end

  test "a crash of the gate ends the transport, its listener with it", context do
    %{port: port, transport: transport} = serve(context)
    ref = Process.monitor(transport)

    [gate] =
      for {WebSocket.Gate, pid, :worker, _} <- Supervisor.which_children(transport), do: pid

    Process.exit(gate, :kill)
    assert_receive {:DOWN, ^ref, :process, ^transport, _reason}
    assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [])
  end

  defp until_closed(socket, bytes) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, more} -> until_closed(socket, bytes <> more)
      {:error, :closed} -> bytes
    end
  end

  defp connections(transport) do
    [gate] =
      for {WebSocket.Gate, pid, :worker, _} <- Supervisor.which_children(transport), do: pid

    {:monitors, monitors} = Process.info(gate, :monitors)
    for {:process, pid} <- monitors, do: pid
  end

  defp parts(frame) do
    [_, _ | _] = parts = Frame.encode(frame)
    Enum.map(parts, &IO.iodata_to_binary/1)
  end

  # The parts of a JSON text, cut by the client itself, as a client of the
  # contract does.
  defp send_parts(socket, json, n \\ 0) do
    {piece, rest} = cut(json)
    part = %{"type" => "part", "n" => n, "last" => rest == "", "data" => Base.encode64(piece)}
    Client.send_frame(socket, part)
    if rest != "", do: send_parts(socket, rest, n + 1)
  end

  defp cut(<<piece::binary-size(786_000), rest::binary>>), do: {piece, rest}
  defp cut(piece), do: {piece, ""}
end
