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
      hello = JSON.encode!(%{"type" => "hello", "protocol" => 1, "token" => "secret"})
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

    test "the 65th connection gets 503, and a closed one frees its place", %{port: port} do
      sockets = for _ <- 1..64, do: elem(Client.upgrade(port), 1)
      assert {:http, 503} = Client.upgrade(port)
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
  end

  describe "the hello" do
    setup context, do: serve(context, token: "secret")

    test "the right token gets welcome, and the connection state holds no token", context do
      assert Client.open(context.port, %{"token" => "secret"})
      [connection] = connections(context.transport)
      state = inspect(:sys.get_state(connection), limit: :infinity, printable_limit: :infinity)
      assert state =~ "Helyx.Transport.WebSocket.Connection"
      refute state =~ "secret"
    end

    test "a missing or wrong token closes with 4401", %{port: port} do
      for hello <- [%{}, %{"token" => "wrong"}, %{"token" => 7}] do
        {:ok, socket} = Client.upgrade(port)
        Client.send_frame(socket, Map.merge(%{"type" => "hello", "protocol" => 1}, hello))
        assert {:close, 4401} = Client.recv(socket)
      end
    end

    test "another protocol number gets refused and 4426", %{port: port} do
      {:ok, socket} = Client.upgrade(port)
      Client.send_frame(socket, %{"type" => "hello", "protocol" => 2, "token" => "secret"})

      assert {:frame, %{"type" => "refused", "code" => "protocol", "server_protocol" => 1}} =
               Client.recv(socket)

      assert {:close, 4426} = Client.recv(socket)
    end

    test "a frame before welcome, bad JSON, or a binary frame closes with 4400", %{port: port} do
      hello = %{"type" => "hello", "protocol" => 1, "token" => "secret"}
      [hello_part | _] = parts(Map.put(hello, "pad", String.duplicate("p", 1_048_576)))

      for send <- [
            &Client.send_frame(&1, %{"type" => "req", "id" => "1", "op" => "x", "params" => %{}}),
            # A hello as parts: its token would wait in the connection.
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
        send.(socket)
        assert {:close, 4400} = Client.recv(socket)
      end
    end

    test "a bad frame around the hello logs nothing that holds its bytes", context do
      %{port: port, transport: transport} = context
      hello = JSON.encode!(%{"type" => "hello", "protocol" => 1, "token" => "secret"})
      bad_utf8 = binary_part(hello, 0, byte_size(hello) - 2) <> <<0xFF, ?", ?}>>

      # Not UTF-8; a continuation with no frame before it; an unknown opcode;
      # an empty continuation that is not the last.
      for {packet, code} <- [
            {Client.text_frame(bad_utf8), 4400},
            {[Client.text_frame(hello), Client.masked_frame(1, 0, "")], 1002},
            {[Client.text_frame(hello), Client.masked_frame(1, 3, "")], 1002},
            {[Client.masked_frame(0, 1, hello), Client.masked_frame(0, 0, "")], 1008}
          ] do
        {:ok, socket} = Client.upgrade(port)
        [connection] = connections(transport)
        ref = Process.monitor(connection)

        log =
          capture_log(fn ->
            :ok = :gen_tcp.send(socket, packet)
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
      assert {:close, 4401} = Client.recv(socket, 10_000)
    end
  end

  describe "requests" do
    setup context, do: serve(context)

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

        json = req <> String.duplicate(" ", size - byte_size(req))
        # The client cuts the parts itself, as a client of the contract does.
        pieces = for <<piece::binary-size(786_000) <- json>>, do: piece
        pieces = pieces ++ [binary_part(json, 33 * 786_000, size - 33 * 786_000)]

        for {piece, n} <- Enum.with_index(pieces) do
          part = %{"type" => "part", "n" => n, "last" => n == 33, "data" => Base.encode64(piece)}
          Client.send_frame(socket, part)
        end

        assert %{"ok" => true} = Client.res(socket, id)
      end
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
end
