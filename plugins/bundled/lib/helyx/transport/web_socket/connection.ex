defmodule Helyx.Transport.WebSocket.Connection do
  @moduledoc false
  # One WebSocket connection (`docs/features/wire-protocol.md`, "Connection").
  # This process owns the socket and writes the frames that its writers add
  # to the outbound queue. Each request runs in a linked worker, and each
  # subscription is a linked process, so a call that waits does not stop
  # the socket.

  @behaviour WebSock

  alias Helyx.Transport.WebSocket.{Authorize, Bounds, Frame, Ops, Outbound, Records, Subscription}

  @hello_ms Bounds.get("hello_ms")
  @ping_ms Bounds.get("ping_ms")
  @idle_ms Bounds.get("idle_ms")
  @max_in_flight Bounds.get("requests_in_flight")
  @max_subscriptions Bounds.get("subscriptions")

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :hello_timeout, @hello_ms)
    Process.send_after(self(), :ping, @ping_ms)
    Process.send_after(self(), :idle, @idle_ms)

    # `writers` holds one entry for each writer; `waiting` is the order of the
    # writers that wait for the slot; `nonce` is the one challenge.
    nonce = :crypto.strong_rand_bytes(32)

    {:push, texts(%{"type" => "challenge", "nonce" => Base.encode64(nonce)}),
     Map.merge(config, %{
       phase: :hello,
       nonce: nonce,
       auth: nil,
       parts: nil,
       out: Outbound.new(self()),
       writers: %{},
       next_sub: 0,
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
      # A hello is small: a client that did not prove the key gets no
      # buffer of parts.
      {tag, _} when tag in [:joined, :more] and state.phase == :hello -> close(4400, state)
      {:joined, frame} -> frame(frame, %{state | parts: nil})
      {:more, parts} -> {:ok, %{state | parts: parts}}
    end
  end

  def handle_in({_data, opcode: :binary}, state), do: close(4400, state)

  @impl true
  def handle_control(_ping_or_pong, state), do: {:ok, %{state | last_in: now()}}

  defp frame(%{"type" => "hello", "protocol" => protocol} = hello, %{phase: :hello} = state)
       when is_integer(protocol) and protocol >= 0 do
    server = Helyx.Transport.WebSocket.protocol()

    # The protocol number first: a client of another protocol learns that it
    # must update, whatever its proof.
    if protocol != server do
      refused = %{"type" => "refused", "code" => "protocol", "server_protocol" => server}
      {:stop, {:shutdown, :closed}, 4426, texts(refused), state}
    else
      case authenticate(state, hello) do
        {:ok, auth} ->
          welcome = texts(%{"type" => "welcome", "protocol" => server})
          {:push, welcome, %{state | phase: :open, auth: auth}}

        {:close, code} ->
          close(code, state)
      end
    end
  end

  defp frame(%{"type" => "req", "id" => id} = req, %{phase: :open} = state)
       when is_binary(id) and byte_size(id) in 1..64 do
    cond do
      owed?(state, id) -> close(4400, state)
      not is_binary(req["op"]) or not is_map(req["params"]) -> error(id, "bad_params", state)
      in_flight(state) >= @max_in_flight -> error(id, "busy", state)
      true -> request(id, req["op"], req["params"], state)
    end
  end

  defp frame(%{"type" => "req", "id" => id}, %{phase: :open} = state) when is_binary(id),
    do: error(id, "bad_params", state)

  defp frame(%{"type" => "ack", "sub" => sub, "seq" => seq} = ack, %{phase: :open} = state)
       when map_size(ack) == 3 and is_binary(sub) and is_integer(seq) and seq >= 0 do
    # An ack of a sub that ended is ignored.
    case sub_writer(state, sub) do
      nil -> {:ok, state}
      {pid, _writer} -> {:ok, ack(state, pid, seq)}
    end
  end

  defp frame(_frame, state), do: close(4400, state)

  # With an authority, the authority decides the credential of the
  # connection; with none, the proof of the server token.
  defp authenticate(%{authority: nil} = state, hello) do
    if proof?(state.key, state.nonce, hello["proof"]), do: {:ok, nil}, else: {:close, 4401}
  end

  defp authenticate(state, hello), do: Authorize.hello(state.authority, state.nonce, hello)

  defp proof?(nil, _nonce, _given), do: true

  defp proof?(key, nonce, given) when is_binary(given) do
    proof = Base.encode64(:crypto.mac(:hmac, :sha256, key.(), nonce))
    Plug.Crypto.secure_compare(proof, given)
  end

  defp proof?(_key, _nonce, _given), do: false

  defp request(id, "subscribe", params, state) do
    with {:ok, session, opts} <- Ops.subscribe_params(state.core, params),
         true <- subs(state) < @max_subscriptions || "too_many_subscriptions" do
      sub = Integer.to_string(state.next_sub)
      access = state.authority && {{state.authority, state.auth}, state.core, params}
      pid = Subscription.start_link(state.out, sub, id, session, opts, access)
      writer = {:sub, sub, id, nil, 0, :none}
      {:ok, %{put_writer(state, pid, writer) | next_sub: state.next_sub + 1}}
    else
      :bad_params -> error(id, "bad_params", state)
      code -> error(id, code, state)
    end
  end

  defp request(id, "unsubscribe", %{"sub" => sub} = params, state)
       when map_size(params) == 1 and is_binary(sub) do
    case sub_writer(state, sub) do
      # The sub leaves the active map at once, so it gets one unsubscribe,
      # and a later ack of it is ignored.
      nil ->
        error(id, "unknown_sub", state)

      {pid, writer} ->
        send(pid, {:unsubscribe, id})
        {:ok, put_writer(state, pid, unsubscribe(writer, id))}
    end
  end

  defp request(id, "unsubscribe", _params, state), do: error(id, "bad_params", state)

  # One records subscription of the connection (`docs/features/live-records.md`).
  # A server with no authority answers as it answers a `hub.*` op.
  defp request(id, "records.subscribe", params, state) when map_size(params) == 0 do
    cond do
      state.authority == nil ->
        error(id, "unknown_op", state)

      records_writer(state) != nil ->
        error(id, "too_many_subscriptions", state)

      true ->
        pid = Records.start_link(state.out, id, state.authority, state.auth)
        {:ok, put_writer(state, pid, {:records, id, nil, :none})}
    end
  end

  defp request(id, "records.subscribe", _params, state), do: error(id, "bad_params", state)

  defp request(id, "records.unsubscribe", params, state) when map_size(params) == 0 do
    case records_writer(state) do
      nil ->
        error(id, "unknown_sub", state)

      {pid, writer} ->
        send(pid, {:unsubscribe, id})
        {:ok, put_writer(state, pid, unsubscribe_records(writer, id))}
    end
  end

  defp request(id, "records.unsubscribe", _params, state), do: error(id, "bad_params", state)

  # The params are checked here, before the worker: a worker holds only the
  # checked values, not the decoded frame (`docs/features/wire-protocol.md`,
  # "Bounds").
  #
  # Under an authority the worker holds the params too: its `check` and
  # `run` get them (`Helyx.Transport.WebSocket.Authority`).
  defp request(id, op, params, state) do
    case worker(id, op, params, state) do
      {:ok, work} ->
        pid = spawn_link(work)
        {:ok, put_writer(state, pid, {:worker, id, :none})}

      :bad_params ->
        error(id, "bad_params", state)

      :unknown_op ->
        error(id, "unknown_op", state)
    end
  end

  # The closure of the worker holds only the values it needs, not the state.
  defp worker(id, op, params, %{authority: nil} = state) do
    {conn, out} = {self(), state.out}

    with {:ok, call} <- Ops.check(state.core, op, params) do
      reply = fn -> Outbound.reply(out, id, Ops.run(call)) end
      {:ok, fn -> Ops.within(conn, out, id, op, Ops.deadline(op), reply) end}
    end
  end

  defp worker(id, op, params, state),
    do: Authorize.worker(self(), state.out, id, op, params, state)

  # A sub holds at most one ack, and none before its subscribe reply
  # (`docs/features/wire-protocol.md`, "Subscriptions").
  defp ack(state, pid, seq) do
    case Map.fetch!(state.writers, pid) do
      {:sub, sub, req, unsub, nil, slot} ->
        send(pid, {:ack, seq})
        put_writer(state, pid, {:sub, sub, req, unsub, 0, slot})

      {:sub, sub, req, unsub, waiting, slot} ->
        put_writer(state, pid, {:sub, sub, req, unsub, max(waiting, seq), slot})
    end
  end

  # The sub handled its ack or its subscribe reply went: it gets the ack
  # that waits.
  defp next_ack(state, pid) do
    case Map.fetch(state.writers, pid) do
      {:ok, {:sub, _, _, _, nil, _}} ->
        state

      {:ok, {:sub, sub, req, unsub, 0, slot}} ->
        put_writer(state, pid, {:sub, sub, req, unsub, nil, slot})

      {:ok, {:sub, sub, req, unsub, seq, slot}} ->
        send(pid, {:ack, seq})
        put_writer(state, pid, {:sub, sub, req, unsub, 0, slot})

      :error ->
        state
    end
  end

  @impl true
  def handle_info({:out, texts, size}, state) do
    Outbound.taken(state.out, size)
    {:push, Enum.map(texts, &{:text, &1}), state}
  end

  def handle_info({:reply, pid, id, texts, size}, state) do
    Outbound.taken(state.out, size)
    state = release(state, pid)

    if owed?(state, pid, id),
      do: {:push, Enum.map(texts, &{:text, &1}), replied(state, pid, id)},
      else: {:ok, state}
  end

  def handle_info({:deadline, pid, id}, state) do
    if owed?(state, pid, id),
      do: error(id, "timeout", replied(state, pid, id)),
      else: {:ok, state}
  end

  def handle_info({:close, code}, state), do: close(code, state)

  def handle_info({:acked, pid}, state), do: {:ok, next_ack(state, pid)}

  # The records process sent `records_end` (its Hub ended): the connection
  # holds no records subscription from here, so a subscribe that follows the
  # frame finds a free place.
  def handle_info({:records_ended, pid}, state) do
    {:ok,
     %{
       state
       | writers: Map.delete(state.writers, pid),
         waiting: :queue.delete(pid, state.waiting)
     }}
  end

  def handle_info({:slot, pid}, state) do
    writer = put_slot(Map.fetch!(state.writers, pid), :wait)
    {:ok, grant(%{put_writer(state, pid, writer) | waiting: :queue.in(pid, state.waiting)})}
  end

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

  # A writer ends and frees its place in flight and the slot.
  def handle_info({:EXIT, pid, reason}, state) do
    writer = Map.get(state.writers, pid)
    state = release(state, pid)

    state = %{
      state
      | writers: Map.delete(state.writers, pid),
        waiting: :queue.delete(pid, state.waiting)
    }

    ids = if writer, do: owed(writer), else: []
    in_flight? = writer != nil and in_flight?(writer)

    cond do
      # A subscription after its reply answers its unsubscribe: it is gone;
      # one before its reply fails.
      ids != [] ->
        answer = if in_flight?, do: Outbound.error("failed"), else: {:ok, %{}}
        {:push, Enum.flat_map(ids, &texts(Outbound.res(&1, answer))), state}

      # A writer that ended, or a worker that crashed after its reply.
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
  def terminate(_reason, state),
    do: Enum.each(Map.keys(state.writers), &Process.exit(&1, :kill))

  # The slot goes to the next waiter when its holder replied or ended.
  defp release(state, pid) do
    case Map.fetch(state.writers, pid) do
      {:ok, writer} ->
        if slot(writer) == :hold,
          do: grant(put_writer(state, pid, put_slot(writer, :none))),
          else: state

      :error ->
        state
    end
  end

  defp grant(state) do
    if Enum.any?(state.writers, fn {_pid, writer} -> slot(writer) == :hold end) do
      state
    else
      case :queue.out(state.waiting) do
        {{:value, pid}, waiting} ->
          send(pid, :slot)
          writer = put_slot(Map.fetch!(state.writers, pid), :hold)
          put_writer(%{state | waiting: waiting}, pid, writer)

        {:empty, _waiting} ->
          state
      end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # The reply of request `id` went. A worker counts against the requests in
  # flight until it ends; a subscription until its subscribe reply, and it
  # gets the acks that came before it.
  defp replied(state, pid, id) do
    case Map.fetch!(state.writers, pid) do
      {:worker, ^id, slot} ->
        put_writer(state, pid, {:worker, nil, slot})

      {:sub, sub, ^id, unsub, ack, slot} ->
        state = put_writer(state, pid, {:sub, sub, nil, unsub, ack, slot})
        next_ack(state, pid)

      {:sub, sub, req, ^id, ack, slot} ->
        state = put_writer(state, pid, {:sub, sub, req, nil, ack, slot})
        next_ack(state, pid)

      {:records, nil, ^id, _slot} ->
        # The unsubscribe reply: the subscription is gone, so a subscribe
        # that follows the reply finds no records writer.
        %{state | writers: Map.delete(state.writers, pid)}

      {:records, ^id, unsub, slot} ->
        put_writer(state, pid, {:records, nil, unsub, slot})
    end
  end

  defp error(id, code, state), do: {:push, texts(Outbound.res(id, Outbound.error(code))), state}

  defp texts(frame), do: Enum.map(Frame.encode(frame), &{:text, &1})

  # Not `:normal`: after a normal stop Bandit keeps the process and hands it
  # the later frames of the client.
  defp close(code, state), do: {:stop, {:shutdown, :closed}, code, state}

  # The writers, and the facts of one writer.
  defp put_writer(state, pid, writer), do: %{state | writers: Map.put(state.writers, pid, writer)}

  defp owed?(state, id), do: Enum.any?(state.writers, fn {_pid, writer} -> id in owed(writer) end)

  defp owed?(state, pid, id) do
    case Map.fetch(state.writers, pid) do
      {:ok, writer} -> id in owed(writer)
      :error -> false
    end
  end

  defp owed({:worker, nil, _slot}), do: []
  defp owed({:worker, id, _slot}), do: [id]
  defp owed({:sub, _sub, req, unsub, _ack, _slot}), do: Enum.reject([req, unsub], &is_nil/1)

  defp owed({:records, req, unsub, _slot}), do: Enum.reject([req, unsub], &is_nil/1)

  defp in_flight(state), do: Enum.count(state.writers, fn {_, writer} -> in_flight?(writer) end)
  defp in_flight?({:worker, _id, _slot}), do: true
  defp in_flight?({:sub, _sub, req, _unsub, _ack, _slot}), do: req != nil
  defp in_flight?({:records, req, _unsub, _slot}), do: req != nil

  # The active subscriptions: a sub that is unsubscribing does not count.
  defp subs(state), do: Enum.count(state.writers, &match?({_, {:sub, _, _, nil, _, _}}, &1))

  defp sub_writer(state, sub) do
    Enum.find_value(state.writers, fn
      {pid, {:sub, ^sub, _req, nil, _ack, _slot} = writer} -> {pid, writer}
      _other -> nil
    end)
  end

  defp unsubscribe({:sub, sub, req, nil, ack, slot}, id), do: {:sub, sub, req, id, ack, slot}
  defp unsubscribe_records({:records, req, nil, slot}, id), do: {:records, req, id, slot}
  defp slot({:worker, _id, slot}), do: slot
  defp slot({:sub, _sub, _req, _unsub, _ack, slot}), do: slot
  defp slot({:records, _req, _unsub, slot}), do: slot
  defp put_slot({:worker, id, _slot}, slot), do: {:worker, id, slot}
  defp put_slot({:sub, sub, req, unsub, ack, _}, slot), do: {:sub, sub, req, unsub, ack, slot}
  defp put_slot({:records, req, unsub, _}, slot), do: {:records, req, unsub, slot}

  # The records writer that is not unsubscribing, with its tuple. A writer
  # whose process is gone is not one: its `:EXIT` is on the way, and a
  # subscribe that follows `records_end` or an unsubscribe reply must pass.
  defp records_writer(state) do
    Enum.find_value(state.writers, fn
      {pid, {:records, _req, nil, _slot} = writer} ->
        if Process.alive?(pid), do: {pid, writer}

      _other ->
        nil
    end)
  end
end
