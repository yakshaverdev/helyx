defmodule Helyx.Transport.WebSocket.Connection do
  @moduledoc false
  # One WebSocket connection (`docs/features/wire-protocol.md`, "Connection").
  # This process owns the socket and writes the frames that its writers add
  # to the outbound queue. Each request runs in a linked worker, and each
  # subscription is a linked process, so a call that waits does not stop
  # the socket.

  @behaviour WebSock

  alias Helyx.Transport.WebSocket.{Frame, Ops, Outbound, Subscription}

  @hello_ms 5_000
  @ping_ms 15_000
  @idle_ms 45_000
  @max_in_flight 16
  @max_subscriptions 16

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :hello_timeout, @hello_ms)
    Process.send_after(self(), :ping, @ping_ms)
    Process.send_after(self(), :idle, @idle_ms)

    # `ids`: the request ids whose reply was not sent => the writer pid.
    # `flight`: the writers that count against the requests in flight; a
    # worker until it ends, a subscription until its reply. `subs`: sub id
    # => pid. `acks`: the subs that handle an ack or wait for their
    # subscribe reply => the highest ack that waits for them, 0 for none.
    # `slot`: the writer that holds the one encoder
    # slot of a large result, and `waiting` the writers that wait for it, in
    # order.
    {:ok,
     Map.merge(config, %{
       phase: :hello,
       parts: nil,
       out: Outbound.new(self()),
       ids: %{},
       flight: MapSet.new(),
       subs: %{},
       acks: %{},
       next_sub: 0,
       slot: nil,
       waiting: :queue.new(),
       last_in: now()
     })}
  end

  @impl true
  def handle_in({text, opcode: :text}, state) do
    state = %{state | last_in: now()}

    case Frame.decode(text, state.parts) do
      {:frame, frame} -> frame(frame, state)
      {:close, code} -> close(code, state)
      # A hello is small: a part before it would hold its token.
      {tag, _} when tag in [:joined, :more] and state.phase == :hello -> close(4400, state)
      {:joined, frame} -> frame(frame, %{state | parts: nil})
      {:more, parts} -> {:ok, %{state | parts: parts}}
    end
  end

  def handle_in({_data, opcode: :binary}, state), do: close(4400, state)

  @impl true
  def handle_control(_ping_or_pong, state), do: {:ok, %{state | last_in: now()}}

  defp frame(%{"type" => "hello", "protocol" => protocol} = hello, %{phase: :hello} = state)
       when is_integer(protocol) do
    server = Helyx.Transport.WebSocket.protocol()

    cond do
      not token?(state.token, hello["token"]) ->
        close(4401, state)

      protocol != server ->
        refused = %{"type" => "refused", "code" => "protocol", "server_protocol" => server}
        {:stop, {:shutdown, :closed}, 4426, texts(refused), state}

      true ->
        {:push, texts(%{"type" => "welcome", "protocol" => server}), %{state | phase: :open}}
    end
  end

  defp frame(%{"type" => "req", "id" => id} = req, %{phase: :open} = state)
       when is_binary(id) and byte_size(id) in 1..64 do
    cond do
      Map.has_key?(state.ids, id) -> close(4400, state)
      not is_binary(req["op"]) or not is_map(req["params"]) -> error(id, "bad_params", state)
      MapSet.size(state.flight) >= @max_in_flight -> error(id, "busy", state)
      true -> request(id, req["op"], req["params"], state)
    end
  end

  defp frame(%{"type" => "req", "id" => id}, %{phase: :open} = state) when is_binary(id),
    do: error(id, "bad_params", state)

  defp frame(%{"type" => "ack", "sub" => sub, "seq" => seq} = ack, %{phase: :open} = state)
       when map_size(ack) == 3 and is_binary(sub) and is_integer(seq) and seq >= 0 do
    # An ack of a sub that ended is ignored.
    case state.subs do
      %{^sub => pid} -> {:ok, ack(state, pid, seq)}
      _ -> {:ok, state}
    end
  end

  defp frame(_frame, state), do: close(4400, state)

  defp token?(nil, _given), do: true

  defp token?(hash, given) when is_binary(given),
    do: Plug.Crypto.secure_compare(hash, :crypto.hash(:sha256, given))

  defp token?(_token, _given), do: false

  defp request(id, "subscribe", params, state) do
    with {:ok, session, opts} <- Ops.subscribe_params(state.core, params),
         true <- map_size(state.subs) < @max_subscriptions || "too_many_subscriptions" do
      sub = Integer.to_string(state.next_sub)
      pid = Subscription.start_link(state.out, sub, id, session, opts)
      state = %{track(state, pid, id) | subs: Map.put(state.subs, sub, pid)}
      state = %{state | acks: Map.put(state.acks, pid, 0)}
      {:ok, %{state | next_sub: state.next_sub + 1}}
    else
      :bad_params -> error(id, "bad_params", state)
      code -> error(id, code, state)
    end
  end

  defp request(id, "unsubscribe", %{"sub" => sub} = params, state)
       when map_size(params) == 1 and is_binary(sub) do
    case state.subs do
      # The sub leaves the map at once, so it gets one unsubscribe, and a
      # later ack of it is ignored.
      %{^sub => pid} ->
        send(pid, {:unsubscribe, id})
        {:ok, %{state | ids: Map.put(state.ids, id, pid), subs: Map.delete(state.subs, sub)}}

      _ ->
        error(id, "unknown_sub", state)
    end
  end

  defp request(id, "unsubscribe", _params, state), do: error(id, "bad_params", state)

  defp request(id, op, params, state) do
    if Ops.known?(op) do
      {conn, out, core} = {self(), state.out, state.core}

      pid = spawn_link(fn -> work(conn, out, core, id, op, params) end)
      {:ok, track(state, pid, id)}
    else
      error(id, "unknown_op", state)
    end
  end

  defp work(conn, out, core, id, op, params) do
    # The deadline of a request with a large result starts at its slot.
    if Ops.slot?(op), do: Outbound.slot(out)
    timer = Process.send_after(conn, {:deadline, self(), id}, Ops.deadline(op))

    try do
      Outbound.reply(out, id, Ops.run(core, op, params))
    after
      # The timer ends with its worker, so the timers are at most the
      # requests in flight.
      Process.cancel_timer(timer)
    end
  end

  # A sub holds at most one ack, and none before its subscribe reply
  # (`docs/features/wire-protocol.md`, "Subscriptions").
  defp ack(state, pid, seq) do
    case state.acks do
      %{^pid => waiting} ->
        %{state | acks: Map.put(state.acks, pid, max(waiting, seq))}

      _ ->
        send(pid, {:ack, seq})
        %{state | acks: Map.put(state.acks, pid, 0)}
    end
  end

  # The sub handled its ack or its subscribe reply went: it gets the ack
  # that waits.
  defp next_ack(state, pid) do
    case state.acks do
      %{^pid => 0} ->
        %{state | acks: Map.delete(state.acks, pid)}

      %{^pid => seq} ->
        send(pid, {:ack, seq})
        %{state | acks: Map.put(state.acks, pid, 0)}

      _ ->
        state
    end
  end

  defp track(state, pid, id),
    do: %{state | ids: Map.put(state.ids, id, pid), flight: MapSet.put(state.flight, pid)}

  @impl true
  def handle_info({:out, texts, size}, state) do
    Outbound.taken(state.out, size)
    {:push, Enum.map(texts, &{:text, &1}), state}
  end

  def handle_info({:reply, pid, id, texts, size}, state) do
    Outbound.taken(state.out, size)
    state = release(state, pid)

    case state.ids do
      %{^id => ^pid} ->
        {:push, Enum.map(texts, &{:text, &1}), replied(state, pid, id)}

      # The deadline answered first; the late reply is dropped.
      _ ->
        {:ok, state}
    end
  end

  def handle_info({:deadline, pid, id}, state) do
    case state.ids do
      %{^id => ^pid} -> error(id, "timeout", replied(state, pid, id))
      _ -> {:ok, state}
    end
  end

  def handle_info({:close, code}, state), do: close(code, state)

  def handle_info({:acked, pid}, state), do: {:ok, next_ack(state, pid)}

  def handle_info({:slot, pid}, state),
    do: {:ok, grant(%{state | waiting: :queue.in(pid, state.waiting)})}

  def handle_info(:ping, state) do
    Process.send_after(self(), :ping, @ping_ms)
    {:push, [{:ping, ""}], state}
  end

  def handle_info(:idle, state) do
    case now() - state.last_in do
      idle when idle >= @idle_ms ->
        close(4408, state)

      idle ->
        Process.send_after(self(), :idle, @idle_ms - idle)
        {:ok, state}
    end
  end

  # A writer ends and frees its place in flight and the slot. One that
  # ended before its reply gets `failed`.
  def handle_info({:EXIT, pid, reason}, state) do
    in_flight? = MapSet.member?(state.flight, pid)
    # A subscription can hold two ids: its subscribe and an unsubscribe.
    ids = for {id, ^pid} <- state.ids, do: id

    state =
      release(
        %{
          state
          | flight: MapSet.delete(state.flight, pid),
            subs: Map.reject(state.subs, fn {_sub, writer} -> writer == pid end),
            acks: Map.delete(state.acks, pid),
            waiting: :queue.delete(pid, state.waiting),
            ids: Map.drop(state.ids, ids)
        },
        pid
      )

    cond do
      # A subscription that ended after its subscribe reply answers its
      # unsubscribe: it is gone. A writer that ended before its reply fails.
      ids != [] ->
        answer = if in_flight?, do: Outbound.error("failed"), else: {:ok, %{}}
        {:push, Enum.flat_map(ids, &texts(Outbound.res(&1, answer))), state}

      # A writer that ended, or a worker that crashed after its reply: a
      # subscription in flight still has its subscribe id.
      reason == :normal or in_flight? ->
        {:ok, state}

      true ->
        {:stop, reason, state}
    end
  end

  def handle_info(:hello_timeout, %{phase: :hello} = state), do: close(4401, state)
  def handle_info(:hello_timeout, state), do: {:ok, state}

  # The writers end with the connection, at any close: a normal exit does
  # not end its links.
  @impl true
  def terminate(_reason, state) do
    [state.flight, Map.values(state.subs), Map.values(state.ids)]
    |> Enum.concat()
    |> Enum.each(&Process.exit(&1, :kill))
  end

  # The slot goes to the next waiter when its holder replied or ended.
  defp release(%{slot: pid} = state, pid), do: grant(%{state | slot: nil})
  defp release(state, _pid), do: state

  defp grant(%{slot: nil} = state) do
    case :queue.out(state.waiting) do
      {{:value, pid}, waiting} ->
        send(pid, :slot)
        %{state | slot: pid, waiting: waiting}

      {:empty, _waiting} ->
        state
    end
  end

  defp grant(state), do: state

  defp now, do: System.monotonic_time(:millisecond)

  # The reply of request `id` went. A subscription stops counting against
  # the requests in flight and gets the acks that came before it; a worker
  # counts until it ends.
  defp replied(state, pid, id) do
    state = %{state | ids: Map.delete(state.ids, id)}

    if pid in Map.values(state.subs),
      do: next_ack(%{state | flight: MapSet.delete(state.flight, pid)}, pid),
      else: state
  end

  defp error(id, code, state), do: {:push, texts(Outbound.res(id, Outbound.error(code))), state}

  defp texts(frame), do: Enum.map(Frame.encode(frame), &{:text, &1})

  # Not `:normal`: after a normal stop Bandit keeps the process and hands it
  # the later frames of the client.
  defp close(code, state), do: {:stop, {:shutdown, :closed}, code, state}
end
