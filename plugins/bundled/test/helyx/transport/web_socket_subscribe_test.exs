defmodule Helyx.Transport.WebSocketSubscribeTest do
  # The conformance client on subscriptions: join during streaming, page
  # boundaries, reconnect, a slow consumer, and session death.
  use ExUnit.Case, async: true

  alias Helyx.Test.{Events, Gate, Gated}
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.{Frame, Outbound, Subscription}

  defmodule Burst do
    @moduledoc false
    use Helyx.Provider.Loop

    @impl true
    def id, do: "burst"

    # More deltas than the credits of a subscription.
    @impl true
    def stream(_model, _context, opts), do: {:ok, Helyx.Test.Burst.stream(17_000, opts)}
  end

  defmodule Paced do
    @moduledoc false
    use Helyx.Provider.Loop

    @impl true
    def id, do: "paced"

    # The model is the count of deltas; 1 ms after each 5, so the stream
    # runs while a client acts.
    @impl true
    def stream(count, _context, _opts) do
      deltas =
        Stream.map(1..String.to_integer(count), fn n ->
          if rem(n, 5) == 0, do: Process.sleep(1)
          {:text_delta, "x"}
        end)

      {:ok, Stream.concat(deltas, [{:done, %{stop_reason: :end_turn, usage: nil}}])}
    end
  end

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Gated.Loop, Gate, Burst, Paced]})
    transport = start_supervised!({WebSocket, core: core, port: 0})
    port = WebSocket.port(transport)
    socket = Client.open(port)
    gate = Gate.open()

    session = start(socket, "gated/#{gate}")

    %{core: core, port: port, socket: socket, session: session}
  end

  defp start(socket, model) do
    %{"result" => %{"session" => session}} =
      Client.request(socket, "start", "start", %{"cwd" => File.cwd!(), "model" => model})

    session
  end

  defp prompt(socket, session) do
    params = %{"session" => session, "text" => "go"}
    assert %{"ok" => true} = Client.request(socket, "p", "prompt", params)
  end

  defp contiguous?(events, after_seq),
    do:
      Enum.map(events, & &1["seq"]) == Enum.to_list((after_seq + 1)..(after_seq + length(events)))

  # The event frames of `sub` until its `session_end`.
  defp until_end(socket, sub, acc \\ []) do
    case Client.recv(socket) do
      {:frame, %{"type" => "session_end", "sub" => ^sub}} ->
        Enum.reverse(acc)

      {:frame, %{"type" => "event", "sub" => ^sub, "event" => event}} ->
        until_end(socket, sub, [event | acc])

      {:frame, _other} ->
        until_end(socket, sub, acc)
    end
  end

  # The subscription process waits in the session for its subscribe reply.
  defp subscriber(session_pid) do
    Events.wait_until(fn ->
      match?({:messages, [_ | _]}, Process.info(session_pid, :messages))
    end)

    {:messages, [{:"$gen_call", {sub, _tag}, _call}]} = Process.info(session_pid, :messages)
    {:links, [connection]} = Process.info(sub, :links)
    {sub, connection}
  end

  defp subscribe(socket, session, params \\ %{}) do
    %{"ok" => true, "result" => result} =
      Client.request(socket, "s", "subscribe", Map.put(params, "session", session))

    result
  end

  # The event frames of `sub` until `stop?` holds for one, all in order.
  defp events(socket, sub, stop?, acc \\ []) do
    case Client.recv(socket) do
      {:frame, %{"type" => "event", "sub" => ^sub, "event" => event}} ->
        if stop?.(event),
          do: Enum.reverse([event | acc]),
          else: events(socket, sub, stop?, [event | acc])

      {:frame, _other} ->
        events(socket, sub, stop?, acc)
    end
  end

  defp turn_end?(event), do: event["type"] == "turn_end"

  test "a client joins during streaming, gets every live event once, then session_end", context do
    %{port: port, socket: socket, session: session} = context

    assert %{"ok" => true} =
             Client.request(socket, "p", "prompt", %{"session" => session, "text" => "ok"})

    assert_receive {:waiting, provider}, 5_000

    joiner = Client.open(port)
    %{"sub" => sub, "snapshot" => snapshot} = subscribe(joiner, session)
    assert %{"turn" => %{"partial" => %{"content" => [%{"text" => "hel"}]}}} = snapshot

    send(provider, :go)
    assert_receive {:waiting, tool}, 5_000
    send(tool, :go)
    events = events(joiner, sub, &turn_end?/1)

    assert contiguous?(events, snapshot["seq"])

    Client.send_frame(joiner, %{"type" => "ack", "sub" => sub, "seq" => List.last(events)["seq"]})
    assert %{"ok" => true} = Client.request(socket, "stop", "stop", %{"session" => session})

    assert {:frame, %{"type" => "session_end", "sub" => ^sub, "reason" => "stopped"}} =
             Client.recv(joiner)
  end

  test "a reconnect with after gets the events it missed, then a page before the tail", context do
    %{port: port, socket: socket, session: session} = context

    %{"sub" => sub, "snapshot" => %{"instance_id" => instance, "seq" => seq}} =
      subscribe(socket, session)

    # Another client sends the prompt: `Client.request/4` skips the events before its reply.
    driver = Client.open(port)

    assert %{"ok" => true} =
             Client.request(driver, "p", "prompt", %{"session" => session, "text" => "hi"})

    missed = events(socket, sub, &turn_end?/1)

    late = Client.open(port)
    after_ = %{"instance_id" => instance, "seq" => seq}
    assert %{"replay" => ^missed} = subscribe(late, session, %{"after" => after_})

    %{"snapshot" => %{"messages" => [newest], "more" => true}} =
      subscribe(late, session, %{"tail" => 1})

    assert %{"ok" => true, "result" => %{"messages" => [%{"role" => "user"}], "more" => false}} =
             Client.request(late, "h", "history", %{
               "session" => session,
               "instance_id" => instance,
               "before" => newest["id"]
             })
  end

  test "a session that crashes gives session_end crashed", context do
    %{core: core, socket: socket, session: session} = context
    %{"sub" => sub} = subscribe(socket, session)
    Process.exit(Helyx.Session.pid(%Helyx.Session{id: session, core: core}), :kill)

    assert {:frame, %{"type" => "session_end", "sub" => ^sub, "reason" => "crashed"}} =
             Client.recv(socket)
  end

  test "an ack above the last seq sent closes with 4400; one of an unknown sub is ignored",
       context do
    %{socket: socket, session: session} = context
    %{"sub" => sub, "snapshot" => %{"seq" => seq}} = subscribe(socket, session)
    Client.send_frame(socket, %{"type" => "ack", "sub" => "nope", "seq" => 99})
    Client.send_frame(socket, %{"type" => "ack", "sub" => sub, "seq" => seq})
    assert %{"ok" => true} = Client.request(socket, "l", "sessions.live", %{})
    Client.send_frame(socket, %{"type" => "ack", "sub" => sub, "seq" => seq + 1})
    assert {:close, 4400} = Client.recv(socket)
  end

  test "a subscription that dies before its subscribe reply answers its unsubscribe too",
       context do
    %{core: core, socket: socket, session: session} = context
    pid = Helyx.Session.pid(%Helyx.Session{id: session, core: core})
    :ok = :sys.suspend(pid)

    req = %{
      "type" => "req",
      "id" => "s",
      "op" => "subscribe",
      "params" => %{"session" => session}
    }

    Client.send_frame(socket, req)
    # The sub id "0" is the first of the connection; the client guesses it.
    Client.send_frame(socket, %{
      req
      | "id" => "u",
        "op" => "unsubscribe",
        "params" => %{"sub" => "0"}
    })

    {sub, _connection} = subscriber(pid)
    # The connection handled the unsubscribe before the sub dies.
    Events.wait_until(fn -> {:unsubscribe, "u"} in elem(Process.info(sub, :messages), 1) end)

    Process.exit(sub, :kill)
    replies = for _ <- 1..2, do: Client.recv(socket)
    failed = for {:frame, %{"id" => id, "error" => %{"code" => "failed"}}} <- replies, do: id
    assert Enum.sort(failed) == ["s", "u"]
    :ok = :sys.resume(pid)
  end

  test "acks before the subscribe reply wait in the connection as one, then go", context do
    %{core: core, socket: socket, session: session} = context
    pid = Helyx.Session.pid(%Helyx.Session{id: session, core: core})
    :ok = :sys.suspend(pid)

    Client.send_frame(socket, %{
      "type" => "req",
      "id" => "s",
      "op" => "subscribe",
      "params" => %{"session" => session}
    })

    # The sub id "0" is the first of the connection; the client guesses it.
    # Only the highest of them is above the seq: a connection that kept the
    # first or the last would not close.
    seqs = [0 | Enum.to_list(100_000..3//-1)] ++ [0]
    acks = for seq <- seqs, do: %{"type" => "ack", "sub" => "0", "seq" => seq}
    :ok = :gen_tcp.send(socket, Enum.map(acks, &Client.text_frame(JSON.encode!(&1))))
    # The connection handles its frames in order, so it took every ack.
    assert %{"ok" => false} = Client.request(socket, "u", "nope", %{})

    {sub, _connection} = subscriber(pid)
    assert {:message_queue_len, 0} = Process.info(sub, :message_queue_len)

    # After the reply the sub gets the highest ack, above its last seq.
    :ok = :sys.resume(pid)
    assert %{"ok" => true, "result" => %{"sub" => "0"}} = Client.res(socket, "s")
    assert {:close, 4400} = Client.recv(socket)
  end

  # An ack at the credit base and one above it: only the second reaches the
  # session. One sender, so an ack at the base would come first.
  defp assert_acks_from_base(socket, pid, sub, base, last) do
    :ok = :sys.suspend(pid)
    Client.send_frame(socket, %{"type" => "ack", "sub" => sub, "seq" => base})
    Client.send_frame(socket, %{"type" => "ack", "sub" => sub, "seq" => last})

    acks = fn ->
      {:messages, messages} = Process.info(pid, :messages)
      for {:ack, _sub, seq} <- messages, do: seq
    end

    Events.wait_until(fn -> acks.() != [] end)
    assert acks.() == [last]
    :ok = :sys.resume(pid)
  end

  test "the credits start at the seq of the snapshot or of after", context do
    %{core: core, port: port, socket: socket, session: session} = context
    pid = Helyx.Session.pid(%Helyx.Session{id: session, core: core})
    %{"sub" => sub, "snapshot" => %{"instance_id" => instance}} = subscribe(socket, session)
    driver = Client.open(port)
    prompt = %{"session" => session, "text" => "hi"}
    assert %{"ok" => true} = Client.request(driver, "p1", "prompt", prompt)
    [first | _] = missed = events(socket, sub, &turn_end?/1)

    # A snapshot after the first turn has a seq above 0.
    late = Client.open(port)
    %{"sub" => snap_sub, "snapshot" => %{"seq" => base}} = subscribe(late, session)
    assert base == List.last(missed)["seq"]
    assert %{"ok" => true} = Client.request(driver, "p2", "prompt", prompt)
    last = List.last(events(late, snap_sub, &turn_end?/1))["seq"]
    assert_acks_from_base(late, pid, snap_sub, base, last)

    replay = Client.open(port)
    after_ = %{"instance_id" => instance, "seq" => first["seq"]}
    %{"sub" => replay_sub, "replay" => [_ | _]} = subscribe(replay, session, %{"after" => after_})
    assert_acks_from_base(replay, pid, replay_sub, first["seq"], last)
  end

  test "unsubscribe ends the sub, and the 17th subscription is refused", context do
    %{socket: socket, session: session} = context
    subs = for _ <- 1..16, do: subscribe(socket, session)["sub"]

    assert %{"error" => %{"code" => "too_many_subscriptions"}} =
             Client.request(socket, "17", "subscribe", %{"session" => session})

    # Two unsubscribes of one sub in a row: one reply each.
    unsubscribe = %{"type" => "req", "op" => "unsubscribe", "params" => %{"sub" => hd(subs)}}
    Client.send_frame(socket, Map.put(unsubscribe, "id", "u"))
    Client.send_frame(socket, Map.put(unsubscribe, "id", "u2"))
    replies = for _ <- 1..2, do: Client.recv(socket)
    assert Enum.any?(replies, &match?({:frame, %{"id" => "u", "ok" => true}}, &1))

    assert Enum.any?(
             replies,
             &match?({:frame, %{"id" => "u2", "error" => %{"code" => "unknown_sub"}}}, &1)
           )

    assert %{"sub" => _} = subscribe(socket, session)
  end

  test "a server close ends the subscriptions of the connection", context do
    %{core: core, port: port, session: session} = context
    pid = Helyx.Session.pid(%Helyx.Session{id: session, core: core})
    client = Client.open(port)
    {:monitored_by, before} = Process.info(pid, :monitored_by)
    subscribe(client, session)
    assert {:monitored_by, [_ | _] = during} = Process.info(pid, :monitored_by)
    assert length(during) == length(before) + 1
    Client.send_text(client, "{}", 2)
    assert {:close, 4400} = Client.recv(client)

    Events.wait_until(fn ->
      length(elem(Process.info(pid, :monitored_by), 1)) == length(before)
    end)
  end

  test "a subscribe of no session gets session_not_found", %{socket: socket} do
    assert %{"error" => %{"code" => "session_not_found"}} =
             Client.request(socket, "s", "subscribe", %{"session" => "none"})
  end

  test "a consumer that does not ack closes with 4408", %{socket: socket} do
    session = start(socket, "burst/x")

    subscribe(socket, session)

    assert %{"ok" => true} =
             Client.request(socket, "p", "prompt", %{"session" => session, "text" => "go"})

    assert {:close, 4408} = Client.until_close(socket)
  end

  test "the 17th request in flight gets busy, and a slot frees after the replies", context do
    %{core: core, port: port, session: session} = context
    pid = Helyx.Session.pid(%Helyx.Session{id: session, core: core})
    # A new connection: the worker of the `start` counts until it ends, which
    # can be after its reply (#769).
    socket = Client.open(port)
    # Each call waits while the session is suspended, under its 5,000 ms timeout.
    :erlang.suspend_process(pid)

    for n <- 1..16 do
      params = %{"session" => session, "text" => "t#{n}"}

      Client.send_frame(socket, %{
        "type" => "req",
        "id" => "#{n}",
        "op" => "follow_up",
        "params" => params
      })
    end

    # The session is suspended, so the next frame is the reply to "17": a
    # `busy` to an earlier request would show here.
    Client.send_frame(socket, %{
      "type" => "req",
      "id" => "17",
      "op" => "sessions.live",
      "params" => %{}
    })

    assert {:frame, %{"id" => "17", "error" => %{"code" => "busy"}}} = Client.recv(socket)
    :erlang.resume_process(pid)
    # The replies of parallel workers have no order.
    replies = for _ <- 1..16, do: Client.recv(socket)

    assert Enum.sort(for {:frame, %{"ok" => true, "id" => id}} <- replies, do: id) ==
             Enum.sort(for n <- 1..16, do: "#{n}"),
           "replies: #{inspect(replies)}"

    Events.wait_until(fn ->
      match?(%{"ok" => true}, Client.request(socket, "l", "sessions.live", %{}))
    end)
  end

  @tag :slow
  test "a call past its deadline answers timeout, and its late result is dropped", context do
    %{core: core, socket: socket, session: session} = context
    pid = Helyx.Session.pid(%Helyx.Session{id: session, core: core})
    :erlang.suspend_process(pid)
    params = %{"session" => session, "model" => "gated/x"}
    assert %{"error" => %{"code" => "timeout"}} = Client.request(socket, "m", "set_model", params)
    :erlang.resume_process(pid)
    assert %{"ok" => true} = Client.request(socket, "l", "sessions.live", %{})
  end

  test "a reconnect with after while the turn streams gets the replay, then the live events",
       context do
    %{port: port, socket: driver} = context
    session = start(driver, "paced/900")
    first = Client.open(port)

    %{"sub" => sub, "snapshot" => %{"instance_id" => instance, "seq" => base}} =
      subscribe(first, session)

    prompt(driver, session)
    seen = events(first, sub, &(&1["seq"] >= base + 20))
    assert contiguous?(seen, base)
    # The connection is lost while the session still streams.
    :ok = :gen_tcp.close(first)

    late = Client.open(port)
    after_ = %{"instance_id" => instance, "seq" => List.last(seen)["seq"]}
    %{"sub" => late_sub, "replay" => replay} = subscribe(late, session, %{"after" => after_})
    live = if Enum.any?(replay, &turn_end?/1), do: [], else: events(late, late_sub, &turn_end?/1)
    missed = replay ++ live

    assert contiguous?(missed, after_["seq"])
    assert [%{"data" => %{"outcome" => "done"}}] = Enum.filter(missed, &turn_end?/1)
  end

  test "an abort while the turn streams: the events before it come, then the aborted end",
       context do
    %{port: port, socket: driver} = context
    session = start(driver, "paced/100000")
    client = Client.open(port)
    %{"sub" => sub, "snapshot" => %{"seq" => base}} = subscribe(client, session)
    prompt(driver, session)
    before = events(client, sub, &(&1["type"] == "message_update"))
    assert %{"ok" => true} = Client.request(driver, "a", "abort", %{"session" => session})
    rest = events(client, sub, &turn_end?/1)

    assert contiguous?(before ++ rest, base)
    %{"turn_id" => turn} = turn_end = List.last(rest)
    assert %{"data" => %{"outcome" => "aborted"}} = turn_end

    assert Enum.any?(
             rest,
             &match?(
               %{"type" => "message_end", "data" => %{"error" => %{"kind" => "aborted"}}},
               &1
             )
           )

    # `session_end` comes after every event: none of the turn follows its end.
    assert %{"ok" => true} = Client.request(driver, "stop", "stop", %{"session" => session})
    assert [] = for(%{"turn_id" => ^turn} = event <- until_end(client, sub), do: event)
  end

  test "a request with bad params answers while the encoder slot is held; a waiting one holds no result",
       context do
    %{core: core, socket: socket, session: session} = context
    pid = Helyx.Session.pid(%Helyx.Session{id: session, core: core})
    :ok = :sys.suspend(pid)
    # The subscription takes the slot, then waits in the suspended session.
    Client.send_request(socket, "s", "subscribe", %{"session" => session})
    {_sub, connection} = subscriber(pid)
    history = %{"session" => session, "instance_id" => "i", "before" => "b"}
    Client.send_request(socket, "h", "history", history)
    Client.send_request(socket, "bad", "history", %{history | "instance_id" => [0]})
    assert {:frame, %{"id" => "bad", "error" => %{"code" => "bad_params"}}} = Client.recv(socket)

    # The worker of "h" waits for the slot, with no call in the session.
    Events.wait_until(fn ->
      {:links, links} = Process.info(connection, :links)
      waiting = {:current_function, {Outbound, :slot, 1}}
      waiting in for(pid when is_pid(pid) <- links, do: Process.info(pid, :current_function))
    end)

    assert {:messages, [_subscribe]} = Process.info(pid, :messages)
    :ok = :sys.resume(pid)
    assert %{"ok" => true} = Client.res(socket, "s")
    assert %{"error" => %{"code" => "instance_changed"}} = Client.res(socket, "h")
  end

  test "an unsubscribe handled before the subscribe reply gets {} when the sub ends after it",
       context do
    %{core: core, socket: socket, session: session} = context
    pid = Helyx.Session.pid(%Helyx.Session{id: session, core: core})
    :ok = :sys.suspend(pid)
    Client.send_request(socket, "s", "subscribe", %{"session" => session})
    {sub, connection} = subscriber(pid)

    # The connection takes the unsubscribe before the subscribe reply.
    :erlang.suspend_process(connection)
    # The sub id "0" is the first of the connection; the client guesses it.
    Client.send_request(socket, "u", "unsubscribe", %{"sub" => "0"})

    Events.wait_until(fn ->
      Process.info(connection, :message_queue_len) != {:message_queue_len, 0}
    end)

    :ok = :sys.resume(pid)

    Events.wait_until(fn ->
      Process.info(sub, :current_function) == {:current_function, {Subscription, :loop, 1}}
    end)

    # The session ends before the sub takes the unsubscribe.
    ref = Process.monitor(sub)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^sub, :normal}
    :erlang.resume_process(connection)

    assert %{"ok" => true, "result" => %{"sub" => "0"}} = Client.res(socket, "s")
    assert %{"ok" => true, "result" => %{}} = Client.res(socket, "u")
  end

  test "a decoded string does not keep the text of its frame in the session", context do
    %{core: core, socket: socket, session: session} = context
    pid = Helyx.Session.pid(%Helyx.Session{id: session, core: core})
    pad = 900_000
    text = String.duplicate("t", 100)

    # A text over 64 bytes in a frame that a key pads: one frame, then parts.
    for {id, op, pad_bytes} <- [{"p", "prompt", pad}, {"f", "follow_up", 2 * pad}] do
      params = %{"session" => session, "text" => text}
      frame = %{"type" => "req", "id" => id, "op" => op, "params" => params}
      texts = Frame.encode(Map.put(frame, "pad", String.duplicate("p", pad_bytes)))
      for text <- texts, do: Client.send_text(socket, IO.iodata_to_binary(text))
      assert %{"ok" => true} = Client.res(socket, id)
    end

    :erlang.garbage_collect(pid)
    {:binary, binaries} = Process.info(pid, :binary)
    assert Enum.all?(binaries, fn {_id, size, _refs} -> size < pad end)
  end
end
