defmodule Helyx.TUI.Wire.ConnectionTest do
  use ExUnit.Case, async: true

  import Helyx.Test.WireClient,
    only: [
      fake_challenge: 1,
      fake_server: 1,
      fake_upgrade: 1,
      server_frame: 3,
      client_frame: 1,
      client_raw: 1
    ]

  alias Helyx.Event
  alias Helyx.Session.Snapshot
  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.Frame
  alias Helyx.Transport.WebSocket.Wire, as: ServerWire
  alias Helyx.TUI.Wire
  alias Helyx.TUI.Wire.Connection

  @loopback {127, 0, 0, 1}
  @max_joined 26_214_400

  defp open(port) do
    {:ok, socket} = Wire.connect(@loopback, port, fn -> "token" end, 5_000)
    Connection.open(socket)
  end

  describe "a real server" do
    setup do
      core = :"core_#{System.unique_integer([:positive])}"
      start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake]})
      transport = start_supervised!({WebSocket, core: core, port: 0})
      {:ok, conn, ref} = open(WebSocket.port(transport))
      %{core: core, conn: conn, ref: ref}
    end

    # A client in the node, whose events the test gets as `{:core, event}`.
    defp node_client(session) do
      test = self()

      spawn_link(fn ->
        {:ok, snapshot, _ref} = Helyx.Session.subscribe(session)
        send(test, {:node_snapshot, snapshot})
        forward(test)
      end)

      assert_receive {:node_snapshot, snapshot}
      snapshot
    end

    defp forward(test) do
      receive do
        {:helyx_event, event} -> send(test, {:node, event})
      end

      forward(test)
    end

    defp until_turn_end(tag, acc \\ []) do
      assert_receive {^tag, %Event{} = event}

      if event.type == :turn_end,
        do: Enum.reverse([event | acc]),
        else: until_turn_end(tag, [event | acc])
    end

    test "the events of a turn are the Core events of a client in the node", %{core: core} = c do
      assert {:ok, id} = Connection.start(c.conn, cwd: File.cwd!(), model: "fake/echo")
      in_node = node_client(%Helyx.Session{id: id, core: core})

      assert {:ok, %Snapshot{} = snapshot, sub} = Connection.subscribe(c.conn, id)
      assert snapshot == in_node

      assert :ok = Connection.steer(c.conn, id, "hello over the wire")
      events = until_turn_end(:helyx_event)
      assert events == until_turn_end(:node)
      assert Enum.any?(events, &(&1.type == :message_update))

      assert :ok = Connection.set_model(c.conn, id, "fake/other")
      assert_receive {:helyx_event, %Event{type: :model_change} = change}
      assert_receive {:node, ^change}

      :ok = Helyx.Sessions.stop(%Helyx.Session{id: id, core: core})
      assert_receive {:helyx_end, ^sub, :stopped}
    end

    test "the operations give the results and the errors of Core", c do
      assert {:ok, id} = Connection.start(c.conn, cwd: File.cwd!(), model: "fake/echo")
      assert {:error, {:invalid_model_ref, _text}} = Connection.set_model(c.conn, id, "bad")
      assert {:error, {:unknown_provider, "nope"}} = Connection.set_model(c.conn, id, "nope/m")
      assert {:error, :not_waiting} = Connection.answer(c.conn, id, "no-ask", %{})
      assert :ok = Connection.abort(c.conn, id)
      assert {:error, :session_not_found} = Connection.follow_up(c.conn, "gone", "x")
      assert {:error, :session_not_found} = Connection.compact(c.conn, "gone", "")
      assert {:error, :session_not_found} = Connection.subscribe(c.conn, "gone")
      assert {:error, :bad_params} = Connection.list_saved(c.conn, limit: 0)

      assert {:error, {:unknown_provider, "nope"}} =
               Connection.start(c.conn, cwd: "/", model: "nope/m")

      assert {:error, :not_found} = Connection.resume(c.conn, id: "missing")
    end

    test "a text over the frame bound goes as parts", c do
      assert {:ok, id} = Connection.start(c.conn, cwd: File.cwd!(), model: "fake/echo")
      assert {:ok, _snapshot, _sub} = Connection.subscribe(c.conn, id)
      text = String.duplicate("é", Frame.max_frame())
      assert :ok = Connection.steer(c.conn, id, text)

      assert_receive {:helyx_event,
                      %Event{type: :message_end, data: %{message: %{role: :user}}} = e}

      assert Helyx.Message.text(e.data.message) == text
    end
  end

  # A fake server that passes the handshake and then runs `script` with
  # its socket; `fake/1` opens a connection of the test to it.
  defp fake_port(script) do
    fake_server(fn socket ->
      fake_upgrade(socket)
      fake_challenge(socket)
      _hello = client_frame(socket)
      :ok = :gen_tcp.send(socket, text(%{type: "welcome", protocol: WebSocket.protocol()}))
      script.(socket)
      Process.sleep(:infinity)
    end)
  end

  defp fake(script) do
    {:ok, conn, ref} = open(fake_port(script))
    {conn, ref}
  end

  defp text(frame) when is_map(frame), do: text(JSON.encode!(frame))
  defp text(iodata), do: server_frame(1, 1, IO.iodata_to_binary(iodata))

  defp res(id, result), do: %{type: "res", id: id, ok: true, result: result}

  defp snapshot do
    %Snapshot{
      instance_id: "i1",
      seq: 0,
      messages: [],
      more: false,
      turn: nil,
      model: "fake/echo",
      queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
      persisting: true,
      usage: %Helyx.Session.Totals{},
      context: nil
    }
  end

  defp notice(seq, text \\ "n"),
    do: %{
      type: "notice",
      session_id: "s1",
      instance_id: "i1",
      turn_id: nil,
      seq: seq,
      data: %{text: text}
    }

  defp event(sub, event), do: text(%{type: "event", sub: sub, event: event})

  # The server answers the subscribe of the test with the sub "x", then
  # sends `frames`.
  defp subscribed(frames) do
    {conn, ref} =
      fake(fn socket ->
        %{"id" => id, "op" => "subscribe", "params" => params} = client_frame(socket)
        %{"session" => "s1", "answers" => true} = params

        :ok =
          :gen_tcp.send(socket, [
            text(res(id, %{sub: "x", snapshot: ServerWire.snapshot(snapshot())})) | frames
          ])
      end)

    assert {:ok, %Snapshot{}, "x"} = Connection.subscribe(conn, "s1")
    {conn, ref}
  end

  test "events go to the owner as Core events, an unknown type is dropped, and session_end ends them" do
    {_conn, _ref} =
      subscribed([
        event("x", notice(1)),
        event("x", %{notice(2) | type: "future"}),
        event("x", Map.put(notice(3, "m"), :extra, 1)),
        text(%{type: "session_end", sub: "x", reason: "crashed"})
      ])

    assert_receive {:helyx_event, %Event{type: :notice, seq: 1, data: %{text: "n"}}}
    assert_receive {:helyx_event, %Event{type: :notice, seq: 3, data: %{text: "m"}}}
    assert_receive {:helyx_end, "x", :crashed}
    refute_received {:helyx_event, %Event{seq: 2}}
  end

  test "a frame that the contract does not allow ends the connection with one error" do
    broken = [
      text("not json"),
      text(%{type: "welcome", protocol: WebSocket.protocol()}),
      text(%{type: "future"}),
      text(res("99", %{})),
      event("nobody", notice(1)),
      text(%{type: "session_end", sub: "nobody", reason: "stopped"}),
      server_frame(1, 2, "binary"),
      [<<1::1, 0::3, 1::4, 1::1, 0::7>>, <<0::32>>],
      server_frame(1, 0, "continuation"),
      # A reserved bit, a fragmented ping, and a ping over 125 bytes.
      [<<1::1, 1::3, 1::4, 0::1, 0::7>>],
      server_frame(0, 9, "p"),
      server_frame(1, 9, String.duplicate("p", 126)),
      text(%{type: "part", n: 1, last: true, data: ""}),
      # Parts out of order, and another frame between two parts.
      [part(0, false), part(2, true)],
      [part(0, false), text(res("1", %{}))]
    ]

    for frame <- broken do
      {conn, ref} = fake(&(:ok = :gen_tcp.send(&1, frame)))
      assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, :broken}}
    end

    for frame <- [
          event("x", %{notice(1) | data: %{}}),
          event("x", %{notice(1) | seq: -1}),
          # A key that the client does not know, over the decode bounds of
          # the transport: 65,536 values and more.
          event("x", Map.put(notice(1), :x, List.duplicate(0, 65_536))),
          text(%{type: "session_end", sub: "x", reason: "gone"})
        ] do
      {conn, ref} = subscribed([frame])
      assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, :broken}}
    end
  end

  defp part(n, last), do: text(%{type: "part", n: n, last: last, data: Base.encode64("{")})

  # A `res` of `start` of `size` bytes of JSON, padded in a key that the
  # client does not know.
  defp padded_res(id, size) do
    res = res(id, %{session: "s", x: ""})
    put_in(res.result.x, String.duplicate("a", size - byte_size(JSON.encode!(res))))
  end

  # The server replies to the first request with `reply.(id)`.
  defp replies(reply) do
    fake(fn socket ->
      %{"id" => id} = client_frame(socket)
      :ok = :gen_tcp.send(socket, reply.(id))
    end)
  end

  test "a whole text frame of the frame bound passes; one byte more is a contract break" do
    for {size, ok?} <- [{Frame.max_frame(), true}, {Frame.max_frame() + 1, false}] do
      {conn, ref} = replies(&text(padded_res(&1, size)))
      result = Connection.start(conn, cwd: "/")
      if ok?, do: assert(result == {:ok, "s"}), else: assert(result == {:error, :closed})
      if not ok?, do: assert_receive({:DOWN, ^ref, :process, ^conn, {:shutdown, :broken}})
    end
  end

  # Two frames of 25 MiB through loopback take about 1 s.
  @tag :slow
  test "a frame joined from parts of the joined bound passes, with a ping between them; one byte more is a contract break" do
    for {size, ok?} <- [{@max_joined, true}, {@max_joined + 1, false}] do
      {conn, ref} =
        replies(fn id ->
          [first | rest] = id |> padded_res(size) |> Frame.encode() |> Enum.map(&text/1)
          [first, server_frame(1, 9, "between") | rest]
        end)

      result = Connection.start(conn, cwd: "/")
      if ok?, do: assert(result == {:ok, "s"}), else: assert(result == {:error, :closed})
      if not ok?, do: assert_receive({:DOWN, ^ref, :process, ^conn, {:shutdown, :broken}})
    end
  end

  test "a reply in WebSocket fragments with a ping between them, and a reply written one byte at a time, pass" do
    {conn, _ref} =
      replies(fn id ->
        <<first::binary-size(10), rest::binary>> = JSON.encode!(res(id, %{session: "s"}))
        [server_frame(0, 1, first), server_frame(1, 9, "between"), server_frame(1, 0, rest)]
      end)

    assert Connection.start(conn, cwd: "/") == {:ok, "s"}

    {conn, _ref} =
      fake(fn socket ->
        %{"id" => id} = client_frame(socket)

        for <<byte <- IO.iodata_to_binary(text(res(id, %{session: "s"})))>> do
          :ok = :gen_tcp.send(socket, <<byte>>)
          Process.sleep(1)
        end
      end)

    assert Connection.start(conn, cwd: "/") == {:ok, "s"}
  end

  test "a ping gets a pong with its payload, and each 1,024th event that the owner applied an ack" do
    test = self()

    {conn, _ref} =
      fake(fn socket ->
        send(test, {:server, self()})
        %{"id" => id} = client_frame(socket)
        snapshot = ServerWire.snapshot(snapshot())
        events = for seq <- 1..1_024, do: event("x", notice(seq))
        :ok = :gen_tcp.send(socket, [text(res(id, %{sub: "x", snapshot: snapshot})) | events])
        receive do: (:ping -> :ok = :gen_tcp.send(socket, server_frame(1, 9, "p1")))
        # An ack of the events before 1,024 would come before the pong.
        send(test, {:client, client_raw(socket)})
        send(test, {:client, client_raw(socket)})
      end)

    {:ok, _snapshot, "x"} = Connection.subscribe(conn, "s1")
    assert_receive {:server, server}

    for seq <- 1..1_023 do
      assert_receive {:helyx_event, %Event{seq: ^seq} = event}
      :ok = Connection.ack(conn, "x", event)
    end

    send(server, :ping)
    assert_receive {:client, {10, "p1"}}
    assert_receive {:helyx_event, %Event{seq: 1_024} = last}
    :ok = Connection.ack(conn, "x", last)
    assert_receive {:client, {1, ack}}
    assert JSON.decode!(ack) == %{"type" => "ack", "sub" => "x", "seq" => 1_024}
  end

  test "a close of the server ends the connection with its code, and a waiting request gets closed" do
    {conn, ref} =
      fake(fn socket ->
        _req = client_frame(socket)
        :ok = :gen_tcp.send(socket, server_frame(1, 8, <<4408::16>>))
      end)

    assert Connection.steer(conn, "s1", "x") == {:error, :closed}
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, {:closed, 4408}}}

    {conn, ref} = fake(&:gen_tcp.close/1)
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, {:closed, nil}}}
    assert Connection.abort(conn, "s1") == {:error, :closed}

    {conn, ref} = fake(&(:ok = :gen_tcp.send(&1, server_frame(1, 8, ""))))
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, {:closed, nil}}}
  end

  test "the connection ends with its owner, and the socket closes" do
    test = self()

    port = fake_port(&send(test, {:closed, :gen_tcp.recv(&1, 0, 5_000)}))

    owner =
      spawn(fn ->
        {:ok, conn, _ref} = open(port)
        send(test, {:conn, conn})
        Process.sleep(:infinity)
      end)

    assert_receive {:conn, conn}
    ref = Process.monitor(conn)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^conn, :normal}
    assert_receive {:closed, {:error, :closed}}
  end

  test "at most 16 requests wait for a reply; one more is busy and sends nothing" do
    test = self()

    {conn, _ref} =
      fake(fn socket ->
        for _n <- 1..16, do: client_frame(socket)
        send(test, {:sixteen, self()})
        # A request of the 17th call would come before the pong.
        receive do: (:ping -> :ok = :gen_tcp.send(socket, server_frame(1, 9, "p")))
        send(test, {:next, client_raw(socket)})
      end)

    tasks = for _n <- 1..16, do: Task.async(fn -> Connection.abort(conn, "s1") end)
    assert_receive {:sixteen, server}
    assert Connection.abort(conn, "s1") == {:error, :busy}
    send(server, :ping)
    assert_receive {:next, {10, "p"}}
    Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
  end

  # The client waits for the subscribe the call timeout of the server,
  # 6,000 ms, and its margin, 5,000 ms.
  @tag :slow
  @tag timeout: 30_000
  test "a late subscribe reply is dropped: its subscription ends with unsubscribe" do
    test = self()

    {conn, ref} =
      fake(fn socket ->
        send(test, {:server, self()})
        %{"id" => id, "op" => "subscribe"} = client_frame(socket)
        receive do: (:late -> :ok)
        reply = text(res(id, %{sub: "x", snapshot: ServerWire.snapshot(snapshot())}))
        :ok = :gen_tcp.send(socket, [reply, event("x", notice(1))])

        %{"id" => unsub, "op" => "unsubscribe", "params" => %{"sub" => "x"}} =
          client_frame(socket)

        :ok = :gen_tcp.send(socket, [event("x", notice(2)), text(res(unsub, %{}))])
        send(test, :unsubscribed)
        %{"id" => abort, "op" => "abort"} = client_frame(socket)
        :ok = :gen_tcp.send(socket, text(res(abort, %{})))
      end)

    assert_receive {:server, server}
    assert Connection.subscribe(conn, "s1") == {:error, :timeout}
    send(server, :late)
    assert_receive :unsubscribed
    # The reply of the abort comes after the frames of the dropped
    # subscription, from the same connection.
    assert Connection.abort(conn, "s1") == :ok
    refute_received {:helyx_event, _event}
    refute_received {:DOWN, ^ref, _, _, _}
  end

  @tag :slow
  @tag timeout: 30_000
  test "a late reply of a broken shape is a contract break" do
    test = self()

    {conn, ref} =
      fake(fn socket ->
        send(test, {:server, self()})
        %{"id" => id, "op" => "steer"} = client_frame(socket)
        receive do: (:late -> :ok)
        :ok = :gen_tcp.send(socket, text(%{type: "res", id: id, ok: "yes"}))
      end)

    assert_receive {:server, server}
    assert Connection.steer(conn, "s1", "x") == {:error, :timeout}
    send(server, :late)
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, :broken}}
  end
end
