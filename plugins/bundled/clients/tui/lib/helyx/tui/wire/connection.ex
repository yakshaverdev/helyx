defmodule Helyx.TUI.Wire.Connection do
  @moduledoc """
  The wire session of the TUI (`docs/features/tui-attach.md`, decision 7): one process that owns
  the socket of `Helyx.TUI.Wire.connect/4` after `welcome`. It sends the requests of the TUI and
  matches their replies by id, joins the parts of a frame and decodes it with the codec of the
  transport and the decode bounds of a frame of the server (`docs/features/tui-attach.md`,
  decision 13), checks it strictly against the schema (decision 14), turns the events of a
  subscription into `Helyx.Event` structs, sends the acks, and answers the pings.

  The process that calls `open/1` owns the connection, which ends with it; `take/1` makes another
  process the owner. The owner gets the events of its subscriptions as a client in the node gets
  them from `Helyx.Session.subscribe/2`: `{:helyx_event, event}` for each event, then
  `{:helyx_end, sub, reason}` at the end of the session, with `reason` `:stopped` or `:crashed`.
  It passes each event that it applied to `ack/3`. The connection ends with `{:shutdown,
  :broken}` at a frame that the contract does not allow, and with `{:shutdown, {:closed, code}}`
  when the server closes it, `code` nil for a close with no code: a close of TCP, a close frame
  with no code, or a failed read or write.

  An operation gives the result of the Core call of the server, or `{:error, code}` with the error
  code of the wire as an atom; for `invalid_model_ref`, `unknown_provider`, and `start_failed`,
  `{code, text}`. It waits for its reply at most the deadline of the server for the operation
  under a Hub and 15,000 ms more from the moment that the connection takes it, its wait for the
  writer included (decision 15), then gives `{:error, :timeout}`: the outcome is unknown, and the
  late reply is dropped; `start` and `resume` wait while the connection lives (decision 17). At
  most 16 requests wait for a reply, late ones too, and at most 16 request frames wait for the
  writer; one more gives `{:error, :busy}` and sends nothing. After the end of the connection an
  operation gives `{:error, :closed}`. A request over the request bound of the server gives
  `{:error, :too_large}` and sends nothing; a sub id that no frame carries is not acked, and its
  detach drops it with no request (`Helyx.TUI.Wire`).
  """

  use GenServer

  alias Helyx.Event
  alias Helyx.Session.File.Scan
  alias Helyx.Session.Snapshot
  alias Helyx.Transport.WebSocket.{Frame, Ops}
  alias Helyx.TUI.Wire
  alias Helyx.TUI.Wire.{Decode, Reader, Subscriptions, Writer}

  # Past the server deadline: the slot wait, the encode, two Hub calls (hub.md, decision 5).
  @margin_ms 5_000 + 2 * 5_000
  # The requests in flight of one connection of the server.
  @max_waiting 16

  @type error :: atom() | {atom(), String.t()}

  @doc "Starts the connection on `socket` and the WebSocket state of `Helyx.TUI.Wire.connect/4`. Returns the connection and the caller's monitor of it."
  @spec open(:gen_tcp.socket(), term()) :: {:ok, pid(), reference()}
  def open(socket, ws) do
    {:ok, conn} = GenServer.start(__MODULE__, {self(), socket, ws})
    ref = Process.monitor(conn)
    :ok = :gen_tcp.controlling_process(socket, conn)
    send(conn, :read)
    {:ok, conn, ref}
  end

  @doc """
  Makes the caller the owner of `conn` in place of the process that opened
  it: a process that did not exist at `open/1`, such as the TUI, which
  starts in its `start_link`. Returns the caller's monitor of it.
  """
  @spec take(pid()) :: reference()
  def take(conn) do
    ref = Process.monitor(conn)
    # A connection that ended gives its `:DOWN` to the monitor.
    _ = call(conn, :take)
    ref
  end

  @doc """
  Subscribes to `session` with `answers: true`; `sub` names the
  subscription. With `after: %{instance_id: id, seq: seq}` of the last
  event that the owner applied, the server answers with the events after
  it, `{:replay, events}`, or with a snapshot (`docs/features/tui-attach.md`,
  decision 11); with no `after`, a replay is a contract break.
  """
  @spec subscribe(pid(), String.t(), after: %{instance_id: String.t(), seq: non_neg_integer()}) ::
          {:ok, Snapshot.t() | {:replay, [Event.t()]}, String.t()} | {:error, error()}
  def subscribe(conn, session, opts \\ []) do
    params = Map.merge(params(opts), %{"session" => session, "answers" => true})
    request(conn, "subscribe", params)
  end

  @doc """
  Acks the events of `sub` up to `event`, which the owner applied. As
  `Helyx.Session.ack/2` with an event, it acks only each 1,024th `seq`.
  """
  @spec ack(pid(), String.t(), Event.t()) :: :ok
  def ack(conn, sub, %Event{seq: seq}) do
    if rem(seq, 1_024) == 0, do: send(conn, {:ack, sub, seq})
    :ok
  end

  @doc "Starts a session with `cwd:` and an optional `model:`; gives its id."
  @spec start(pid(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def start(conn, opts), do: request(conn, "start", params(opts))

  @doc "Resumes the session `id:`, or the newest one of `cwd:`; gives its id."
  @spec resume(pid(), [id: String.t()] | [cwd: String.t()]) ::
          {:ok, String.t()} | {:error, error()}
  def resume(conn, opts), do: request(conn, "resume", params(opts))

  @doc "A page of the saved sessions, with the options `cwd`, `after`, and `limit`."
  @spec list_saved(pid(), keyword()) ::
          {:ok, [Scan.Summary.t()], String.t() | nil} | {:error, error()}
  def list_saved(conn, opts \\ []), do: request(conn, "sessions.saved", params(opts))

  @doc "Sends `text` to `session` as a steer, as `Helyx.Session.steer/2`."
  @spec steer(pid(), String.t(), String.t()) :: :ok | {:error, error()}
  def steer(conn, session, text), do: text_request(conn, "steer", session, text)

  @doc "Sends `text` to `session` as a follow-up, as `Helyx.Session.follow_up/2`."
  @spec follow_up(pid(), String.t(), String.t()) :: :ok | {:error, error()}
  def follow_up(conn, session, text), do: text_request(conn, "follow_up", session, text)

  @doc "Compacts `session` with the instructions `text`, as `Helyx.Session.compact/2`."
  @spec compact(pid(), String.t(), String.t()) :: :ok | {:error, error()}
  def compact(conn, session, text), do: text_request(conn, "compact", session, text)

  @doc "Aborts the turn of `session`, as `Helyx.Session.abort/1`."
  @spec abort(pid(), String.t()) :: :ok | {:error, error()}
  def abort(conn, session), do: request(conn, "abort", %{"session" => session})

  @doc "Stops `session` after an abort of its turn, as `Helyx.Sessions.stop/1`."
  @spec stop(pid(), String.t()) :: :ok | {:error, error()}
  def stop(conn, session), do: request(conn, "stop", %{"session" => session})

  @doc "Ends the subscription `sub`; the session runs on (decision 18)."
  @spec unsubscribe(pid(), String.t()) :: :ok | {:error, error()}
  def unsubscribe(conn, sub), do: call(conn, {:unsubscribe, sub})

  @doc "Sets the model of the next turn of `session`, as `Helyx.Session.set_model/2`."
  @spec set_model(pid(), String.t(), String.t()) :: :ok | {:error, error()}
  def set_model(conn, session, model),
    do: request(conn, "set_model", %{"session" => session, "model" => model})

  @doc "Answers the ask `ask_id` of `session`, as `Helyx.Session.answer/3`."
  @spec answer(pid(), String.t(), String.t(), map()) :: :ok | {:error, error()}
  def answer(conn, session, ask_id, answer),
    do: request(conn, "answer", %{"session" => session, "ask_id" => ask_id, "answer" => answer})

  defp text_request(conn, op, session, text),
    do: request(conn, op, %{"session" => session, "text" => text})

  defp params(opts), do: Map.new(opts, fn {key, value} -> {Atom.to_string(key), value} end)

  defp request(conn, op, params) do
    if Wire.fits?(op, params), do: call(conn, {:request, op, params}), else: {:error, :too_large}
  end

  defp call(conn, message) do
    GenServer.call(conn, message, :infinity)
  catch
    :exit, _ended -> {:error, :closed}
  end

  @impl true
  def init({owner, socket, ws}) do
    # `waiting` maps the id of a request to its op and `{from, timer}`, or
    # `:late` after the timer, or `{:unsubscribe, sub}` for the end of a sub
    # that a late reply made; `replays` holds the id of each `subscribe`
    # with `after`. `subs` holds the subscriptions
    # (`Helyx.TUI.Wire.Subscriptions`), `unwritten` counts the request
    # frames that wait for the writer, and `control` and `pong` hold the
    # next batch of a pong and acks.
    {:ok,
     %{
       owner: owner,
       monitor: Process.monitor(owner),
       socket: socket,
       writer: Writer.start_link(socket, ws),
       ws: ws,
       pending: 0,
       unwritten: 0,
       control: :idle,
       pong: nil,
       parts: nil,
       next: 1,
       waiting: %{},
       replays: MapSet.new(),
       subs: Subscriptions.new()
     }}
  end

  @impl true
  def handle_call({:request, _op, _params}, _from, state)
      when map_size(state.waiting) >= @max_waiting or state.unwritten >= @max_waiting,
      do: {:reply, {:error, :busy}, state}

  def handle_call({:request, op, params}, from, state),
    do: start_request(state, op, params, op, from)

  def handle_call({:unsubscribe, sub}, from, state) do
    case Subscriptions.detach(state.subs, sub) do
      {:ok, _op}
      when map_size(state.waiting) >= @max_waiting or state.unwritten >= @max_waiting ->
        {:reply, {:error, :busy}, state}

      {:ok, op} ->
        start_request(state, "unsubscribe", %{"sub" => sub}, op, from)

      {:dropped, subs} ->
        {:reply, :ok, %{state | subs: subs}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:take, {owner, _tag}, state) do
    Process.demonitor(state.monitor, [:flush])
    {:reply, :ok, %{state | owner: owner, monitor: Process.monitor(owner)}}
  end

  @impl true
  def handle_info(:read, state), do: active(state)

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    case Reader.read(state.ws, data, state.pending) do
      {:ok, messages, ws, pending} ->
        messages(messages, %{state | ws: ws, pending: pending})

      {:partial, messages, ws} ->
        messages(messages ++ [:broken], %{state | ws: ws, pending: 0})

      :broken ->
        broken(state)
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state), do: closed(nil, state)

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state),
    do: closed(nil, state)

  def handle_info({:deadline, id}, state) do
    case state.waiting do
      %{^id => {op, {from, _timer}}} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, put_in(state.waiting[id], {op, :late})}

      _answered_or_late ->
        {:noreply, state}
    end
  end

  def handle_info({:ack, sub, seq}, state) do
    if Subscriptions.live?(state.subs, sub),
      do: control(%{state | subs: Subscriptions.ack(state.subs, sub, seq)}),
      else: {:noreply, state}
  end

  def handle_info(:written, state) do
    Subscriptions.flush(%{state | unwritten: state.unwritten - 1}, @max_waiting, &write_request/4)
  end

  def handle_info(:sent, state), do: control(%{state | control: :idle})

  # gen_tcp drops the bytes that wait to be read at a failed send: no close code (decision 15).
  def handle_info(:write_failed, state), do: closed(nil, state)

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  defp messages([], state), do: active(state)

  defp messages([message | rest], state) do
    case message(message, state) do
      {:noreply, state} -> messages(rest, state)
      stop -> stop
    end
  end

  defp active(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, _closed} -> closed(nil, state)
    end
  end

  defp message({:ping, payload}, state), do: control(%{state | pong: payload})

  defp message({:close, code, _reason}, state), do: closed(code, state)
  defp message(:broken, state), do: broken(state)

  defp message({:text, text}, state) do
    case Frame.decode(text, state.parts, :outbound) do
      {:more, parts} -> {:noreply, %{state | parts: parts}}
      {:close, _code} -> broken(state)
      {_whole, frame} -> frame(frame, %{state | parts: nil})
    end
  end

  # Every reply is checked, a late one too.
  defp frame(%{"type" => "res", "id" => id} = res, state) when is_map_key(state.waiting, id) do
    {{op, caller}, waiting} = Map.pop(state.waiting, id)
    replay? = MapSet.member?(state.replays, id)
    state = %{state | waiting: waiting, replays: MapSet.delete(state.replays, id)}

    case Decode.result(op, res) do
      {:ok, {:ok, {:replay, _events}, _sub}} when not replay? -> broken(state)
      {:ok, result} -> reply(caller, op, result, state)
      :error -> broken(state)
    end
  end

  defp frame(%{"type" => "event", "sub" => sub, "event" => event}, state) do
    case Subscriptions.event(state.subs, state.owner, sub, Decode.event(event)) do
      {:ok, subs} -> {:noreply, %{state | subs: subs}}
      :broken -> broken(state)
    end
  end

  defp frame(%{"type" => "session_end", "sub" => sub, "reason" => reason}, state)
       when reason in ["stopped", "crashed"] do
    case Subscriptions.ended(state.subs, state.owner, sub, reason) do
      {:ok, subs} -> {:noreply, %{state | subs: subs}}
      :broken -> broken(state)
    end
  end

  defp frame(_frame, state), do: broken(state)

  # The reply of the subscription ops; `:next` for every other op.
  defp reply(caller, op, result, state) do
    case Subscriptions.reply(state.subs, caller, op, result) do
      {:next, subs} ->
        reply_caller(caller, result, %{state | subs: subs})

      {ended, subs} when ended in [:detached, :dropped] ->
        {:noreply, %{state | subs: subs}}

      {:late_subscribe, sub, subs} ->
        Subscriptions.late_subscribe(%{state | subs: subs}, sub, @max_waiting, &write_request/4)

      :broken ->
        broken(state)
    end
  end

  defp reply_caller(:late, _result, state), do: {:noreply, state}

  defp reply_caller({from, timer}, result, state) do
    if timer, do: Process.cancel_timer(timer)
    GenServer.reply(from, result)
    {:noreply, state}
  end

  defp arm(_id, :infinity), do: nil
  defp arm(id, ms), do: Process.send_after(self(), {:deadline, id}, ms + @margin_ms)

  defp register(state, id, op, caller),
    do: %{state | next: state.next + 1, waiting: Map.put(state.waiting, id, {op, caller})}

  # The request of an op, or of a detach, whose `pending` op is `{:unsub, sub}`. An id is never
  # used again, so a late reply is told apart.
  defp start_request(state, op, params, pending, from) do
    id = Integer.to_string(state.next)
    state = if params["after"], do: update_in(state.replays, &MapSet.put(&1, id)), else: state
    timer = arm(id, Ops.deadline(op, true))
    write_request(register(state, id, pending, {from, timer}), id, op, params)
  end

  defp write_request(state, id, op, params) do
    Writer.write(
      state.writer,
      [%{"type" => "req", "id" => id, "op" => op, "params" => params}],
      :written
    )

    {:noreply, %{state | unwritten: state.unwritten + 1}}
  end

  # At most one batch of a pong and acks waits for the writer, so pings and events that come
  # faster than it writes do not grow its queue. The next batch holds the latest ping (RFC 6455,
  # section 5.5.3) and the latest seq of each live sub: an ack covers the events before it.
  defp control(%{control: :idle} = state) do
    {acks, subs} = Subscriptions.take_acks(state.subs)
    pong = if state.pong, do: [{:pong, state.pong}], else: []

    if acks == [] and pong == [] do
      {:noreply, %{state | subs: subs}}
    else
      Writer.write(state.writer, acks ++ pong, :sent)
      {:noreply, %{state | subs: subs, control: :waiting, pong: nil}}
    end
  end

  defp control(state), do: {:noreply, state}

  # The writer ends with the connection, also in a send: a `:normal` end does not pass the link.
  # The unlink comes first, so that the `:killed` of the writer is not the reason of the connection.
  @impl true
  def terminate(_reason, state), do: state.writer |> tap(&Process.unlink/1) |> Process.exit(:kill)

  defp broken(state), do: {:stop, {:shutdown, :broken}, state}
  defp closed(code, state), do: {:stop, {:shutdown, {:closed, code}}, state}
end
