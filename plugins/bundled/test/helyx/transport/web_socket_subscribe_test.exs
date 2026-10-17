defmodule Helyx.Transport.WebSocketSubscribeTest do
  # The conformance client on subscriptions: join during streaming, page
  # boundaries, reconnect, a slow consumer, and session death.
  use ExUnit.Case, async: true

  alias Helyx.Test.{Events, Gate, Gated}
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  defmodule Burst do
    @moduledoc false
    use Helyx.Provider.Loop

    @impl true
    def id, do: "burst"

    # More deltas than the credits of a subscription.
    @impl true
    def stream(_model, _context, opts), do: {:ok, Helyx.Test.Burst.stream(17_000, opts)}
  end

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Gated.Loop, Gate, Burst]})
    transport = start_supervised!({WebSocket, core: core, port: 0})
    port = WebSocket.port(transport)
    socket = Client.open(port)
    gate = Gate.open()

    %{"result" => %{"session" => session}} =
      Client.request(socket, "start", "start", %{"cwd" => File.cwd!(), "model" => "gated/#{gate}"})

    %{core: core, port: port, socket: socket, session: session}
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

    assert Enum.map(events, & &1["seq"]) ==
             Enum.to_list((snapshot["seq"] + 1)..(snapshot["seq"] + length(events)))

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

    Events.wait_until(fn -> match?({:messages, [_ | _]}, Process.info(pid, :messages)) end)
    {:messages, [{:"$gen_call", {sub, _tag}, _call}]} = Process.info(pid, :messages)
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

    Events.wait_until(fn -> match?({:messages, [_ | _]}, Process.info(pid, :messages)) end)
    {:messages, [{:"$gen_call", {sub, _tag}, _call}]} = Process.info(pid, :messages)
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
    %{"result" => %{"session" => session}} =
      Client.request(socket, "b", "start", %{"cwd" => File.cwd!(), "model" => "burst/x"})

    subscribe(socket, session)

    assert %{"ok" => true} =
             Client.request(socket, "p", "prompt", %{"session" => session, "text" => "go"})

    assert {:close, 4408} = Client.until_close(socket)
  end

  test "the 17th request in flight gets busy, and a reply frees its slot", context do
    %{core: core, socket: socket, session: session} = context
    pid = Helyx.Session.pid(%Helyx.Session{id: session, core: core})
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

    assert %{"error" => %{"code" => "busy"}} = Client.request(socket, "17", "sessions.live", %{})
    :erlang.resume_process(pid)
    # The replies of parallel workers have no order.
    replies = for _ <- 1..16, do: Client.recv(socket)

    assert Enum.sort(for {:frame, %{"ok" => true, "id" => id}} <- replies, do: id) ==
             Enum.sort(for n <- 1..16, do: "#{n}")

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
end
