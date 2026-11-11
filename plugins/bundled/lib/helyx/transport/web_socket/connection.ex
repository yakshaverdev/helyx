defmodule Helyx.Transport.WebSocket.Connection do
  @moduledoc false
  # One WebSocket connection (`docs/features/wire-protocol.md`, "Connection").
  # This process owns the socket and writes the frames that its writers add
  # to the outbound queue. Each request runs in a linked worker, and each
  # subscription is a linked process, so a call that waits does not stop
  # the socket.

  @behaviour WebSock

  alias Helyx.Transport.WebSocket.{Authorize, Bounds, Frame, Ops, Outbound, Pairing, Subscription}

  @hello_ms Bounds.get("hello_ms")
  @ping_ms Bounds.get("ping_ms")
  @idle_ms Bounds.get("idle_ms")
  @max_in_flight Bounds.get("requests_in_flight")
  @max_subscriptions Bounds.get("subscriptions")

  # The id of the one liveness request that the server sends a hands
  # connection (`docs/features/remote-hands.md`, "Registration and lease").
  @live_id "hands.live"

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
       role: nil,
       runner: nil,
       lease_at: nil,
       lease_ms: nil,
       live_seq: 0,
       live_ack: 0,
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
        {:ok, auth, role, runner} ->
          welcome = texts(%{"type" => "welcome", "protocol" => server})
          state = %{state | phase: :open, auth: auth, role: role, runner: runner}
          {:push, welcome, state}

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

  defp frame(
         %{"type" => "res", "id" => @live_id, "ok" => true, "result" => %{"seq" => seq}},
         %{role: "hands"} = state
       )
       when is_integer(seq) do
    {:ok, %{state | lease_at: now(), live_ack: seq, live_seq: state.live_seq + 1}}
  end

  defp frame(%{"type" => "res"}, %{role: "hands"} = state), do: {:ok, state}

  defp frame(_frame, state), do: close(4400, state)

  # The public listener takes no server token: only a pairing link or the key
  # of a paired peer (`docs/features/remote-hands.md`, "Pairing and the
  # public listener").
  defp authenticate(%{listener: :public} = state, hello) do
    case Pairing.hello(state.pairing, state.nonce, hello, self()) do
      {:ok, kind, name} -> {:ok, nil, kind, name}
      {:close, code} -> {:close, code}
    end
  end

  # A pairing attempt on the loopback listener is not a handshake there.
  defp authenticate(%{listener: :loopback} = state, hello) do
    with nil <- hello["pair"],
         nil <- hello["signature"],
         {:ok, role} <- role(hello),
         :ok <- runner(role, hello["runner"]),
         {:ok, auth} <- loopback_auth(state, hello) do
      {:ok, auth, role, hello["runner"]}
    else
      {:close, code} -> {:close, code}
      _other -> {:close, 4400}
    end
  end

  # With an authority, the authority decides the credential of the
  # connection; with none, the proof of the server token.
  defp loopback_auth(%{authority: nil} = state, hello) do
    if proof?(state.key, state.nonce, hello["proof"]), do: {:ok, nil}, else: {:close, 4401}
  end

  defp loopback_auth(state, hello), do: Authorize.hello(state.authority, state.nonce, hello)

  defp role(%{"role" => "hands"}), do: {:ok, "hands"}
  defp role(%{"role" => "client"}), do: {:ok, "client"}
  defp role(%{"role" => _other}), do: :error
  defp role(_hello), do: {:ok, "client"}

  # A hands role names its runner: 1 to 64 bytes of a-z, 0-9, and _.
  defp runner("hands", name) when is_binary(name) and byte_size(name) in 1..64 do
    if name =~ ~r/\A[a-z0-9_]+\z/, do: :ok, else: :error
  end

  defp runner("client", _name), do: :ok
  defp runner(_role, _name), do: :error

  defp proof?(nil, _nonce, _given), do: true

  defp proof?(key, nonce, given) when is_binary(given) do
    proof = Base.encode64(:crypto.mac(:hmac, :sha256, key.(), nonce))
    Plug.Crypto.secure_compare(proof, given)
  end

  defp proof?(_key, _nonce, _given), do: false

  # A pairing operation runs in a worker, so a Hub call in it does not hold
  # the socket.
  defp pair_request(id, op, params, pairing, state) do
    out = state.out

    pid =
      spawn_link(fn ->
        answer =
          case Pairing.request(pairing, op, params) do
            {:ok, result} -> {:ok, result}
            {:error, code} -> Ops.error(op, to_string(code))
          end

        Outbound.reply(out, id, answer)
      end)

    {:ok, put_writer(state, pid, {:worker, id, :none})}
  end

  # The server token, or no authority, and nothing else, may pair a peer.
  defp server_credential?(%{authority: nil}), do: true
  defp server_credential?(%{auth: %{token: nil}}), do: true
  defp server_credential?(_state), do: false

  defp forbidden(id, op, state),
    do: {:push, texts(Outbound.res(id, Ops.error(op, "forbidden"))), state}

  # The folder of a session on a runner is the folder of the runner
  # (`docs/features/remote-hands.md`, decision 5).
  defp register(id, %{"runner" => runner, "folder" => folder} = params, state)
       when map_size(params) == 2 and is_binary(folder) do
    if runner == state.runner and byte_size(folder) <= 4_096 do
      case Pairing.register_hands(state.pairing, self(), runner, folder) do
        {:ok, lease_ms} ->
          state = lease(state, lease_ms)
          {:push, texts(Outbound.res(id, {:ok, %{"lease_ms" => lease_ms}})), state}

        {:error, _unauthorized} ->
          close(4401, state)
      end
    else
      close(4401, state)
    end
  end

  defp register(id, _params, state), do: error(id, "bad_params", state)

  # The lease runs on the server's clock: one liveness request each third,
  # and a close when its answer came no later than one lease before.
  defp lease(state, lease_ms) do
    Process.send_after(self(), :hands_live, div(lease_ms, 3))
    Process.send_after(self(), :hands_lease, lease_ms)
    %{state | lease_ms: lease_ms, lease_at: now()}
  end

  # The pairing operations of the loopback listener, and the registration of
  # a hands connection (`docs/features/remote-hands.md`, "Pairing and the
  # public listener", "Registration and lease"). A client operation on a
  # hands connection, and a hands operation on a client connection, are
  # `unknown_op`.
  defp request(id, "pair." <> _op = op, params, %{listener: :loopback} = state) do
    cond do
      state.pairing == nil -> error(id, "no_public_listener", state)
      not server_credential?(state) -> forbidden(id, op, state)
      true -> pair_request(id, op, params, state.pairing, state)
    end
  end

  defp request(id, "pair." <> _op, _params, %{listener: :public} = state),
    do: error(id, "unknown_op", state)

  # A hands role over the loopback listener proved the server token, and it
  # has no pairing to register with (`docs/features/remote-hands.md`,
  # "The pairing handshake").
  defp request(_id, "hands.register", _params, %{role: "hands", pairing: nil} = state),
    do: close(4401, state)

  defp request(id, "hands.register", params, %{role: "hands"} = state),
    do: register(id, params, state)

  defp request(id, "hands." <> _op, _params, state), do: error(id, "unknown_op", state)

  defp request(id, _op, _params, %{role: "hands"} = state), do: error(id, "unknown_op", state)

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

  def handle_info({:slot, pid}, state) do
    writer = put_slot(Map.fetch!(state.writers, pid), :wait)
    {:ok, grant(%{put_writer(state, pid, writer) | waiting: :queue.in(pid, state.waiting)})}
  end

  def handle_info(:ping, state) do
    Process.send_after(self(), :ping, @ping_ms)
    {:push, [{:ping, ""}], state}
  end

  def handle_info(:hands_live, %{lease_ms: lease_ms} = state) when is_integer(lease_ms) do
    Process.send_after(self(), :hands_live, div(lease_ms, 3))

    request = %{
      "type" => "req",
      "id" => @live_id,
      "op" => "hands.live",
      "params" => %{"seq" => state.live_seq, "ack" => state.live_ack}
    }

    {:push, texts(request), state}
  end

  def handle_info(:hands_live, state), do: {:ok, state}

  def handle_info(:hands_lease, %{lease_ms: lease_ms, lease_at: at} = state)
      when is_integer(lease_ms) do
    idle = now() - at

    if idle >= lease_ms do
      close(4408, state)
    else
      Process.send_after(self(), :hands_lease, lease_ms - idle)
      {:ok, state}
    end
  end

  def handle_info(:hands_lease, state), do: {:ok, state}

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

  defp in_flight(state), do: Enum.count(state.writers, fn {_, writer} -> in_flight?(writer) end)
  defp in_flight?({:worker, _id, _slot}), do: true
  defp in_flight?({:sub, _sub, req, _unsub, _ack, _slot}), do: req != nil

  # The active subscriptions: a sub that is unsubscribing does not count.
  defp subs(state), do: Enum.count(state.writers, &match?({_, {:sub, _, _, nil, _, _}}, &1))

  defp sub_writer(state, sub) do
    Enum.find_value(state.writers, fn
      {pid, {:sub, ^sub, _req, nil, _ack, _slot} = writer} -> {pid, writer}
      _other -> nil
    end)
  end

  defp unsubscribe({:sub, sub, req, nil, ack, slot}, id), do: {:sub, sub, req, id, ack, slot}
  defp slot({:worker, _id, slot}), do: slot
  defp slot({:sub, _sub, _req, _unsub, _ack, slot}), do: slot
  defp put_slot({:worker, id, _slot}, slot), do: {:worker, id, slot}
  defp put_slot({:sub, sub, req, unsub, ack, _}, slot), do: {:sub, sub, req, unsub, ack, slot}
end
