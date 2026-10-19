defmodule Helyx.TUI.Wire.Connection do
  @moduledoc """
  The wire session of the TUI (`docs/features/tui-attach.md`, decision 7):
  one process that owns the socket of `Helyx.TUI.Wire.connect/4` after
  `welcome`. It sends the requests of the TUI and matches their replies by
  id, joins the parts of a frame and decodes it with the codec and the
  decode bounds of the transport, turns the events of a subscription into
  `Helyx.Event` structs, sends the acks, and answers the pings.

  The process that calls `open/1` owns the connection, which ends with it.
  The owner gets the events of its subscriptions as a client in the node
  gets them from `Helyx.Session.subscribe/2`: `{:helyx_event, event}` for
  each event, then `{:helyx_end, sub, reason}` at the end of the session,
  with `reason` `:stopped` or `:crashed`. It passes each event that it
  applied to `ack/3`. The connection ends with `{:shutdown, :broken}` at a
  frame that the contract does not allow, and with `{:shutdown, {:closed,
  code}}` when the server closes it, `code` nil for a close with no code:
  a close of TCP, a close frame with no code, or a failed read or write.

  An operation gives the result of the Core call of the server, or
  `{:error, code}` with the error code of the wire as an atom; for
  `invalid_model_ref`, `unknown_provider`, and `start_failed`, `{code,
  text}`. It waits for its reply at most the deadline of the server for the
  operation and 5,000 ms more from the moment that the connection takes
  it, then gives `{:error, :timeout}`: the outcome is unknown, and the late
  reply is dropped. A request waits while the connection writes the frames
  of an earlier one, each within the send timeout of the socket, 5,000 ms
  (`Helyx.TUI.Wire.connect/4`). At most 16 requests wait for a
  reply, late ones too; one more gives `{:error, :busy}` and sends nothing.
  After the end of the connection an operation gives `{:error, :closed}`.
  """

  use GenServer

  alias Helyx.Event
  alias Helyx.Session.File.Scan
  alias Helyx.Session.Snapshot
  alias Helyx.Transport.WebSocket.{Frame, Ops}
  alias Helyx.TUI.Wire
  alias Helyx.TUI.Wire.{Decode, Reader}

  # The wait of the server for its encoder slot and the encode of a large
  # result are outside its deadline (wire-protocol.md, "Deadlines").
  @margin_ms 5_000
  # The requests in flight of one connection of the server.
  @max_waiting 16

  @type error :: atom() | {atom(), String.t()}

  @doc """
  Starts the connection on `socket`, which the caller owns and gives to it.
  Returns the connection and the caller's monitor of it.
  """
  @spec open(:gen_tcp.socket()) :: {:ok, pid(), reference()}
  def open(socket) do
    {:ok, conn} = GenServer.start(__MODULE__, {self(), socket})
    ref = Process.monitor(conn)
    :ok = :gen_tcp.controlling_process(socket, conn)
    send(conn, :read)
    {:ok, conn, ref}
  end

  @doc "Subscribes to `session` with `answers: true`; `sub` names the subscription."
  @spec subscribe(pid(), String.t()) ::
          {:ok, Snapshot.t() | {:replay, [Event.t()]}, String.t()} | {:error, error()}
  def subscribe(conn, session),
    do: request(conn, "subscribe", %{"session" => session, "answers" => true})

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
    GenServer.call(conn, {:request, op, params}, :infinity)
  catch
    :exit, _ended -> {:error, :closed}
  end

  @impl true
  def init({owner, socket}) do
    Process.monitor(owner)

    # `waiting` maps the id of a request to its op and `{from, timer}`: its
    # caller and its deadline timer, `:late` after the timer, or
    # `{:unsubscribe, sub}` for the end of a subscription that a late reply
    # made. `subs` maps a subscription to `:live`, or to `:dropped` for one
    # that a late reply made.
    {:ok,
     %{
       owner: owner,
       socket: socket,
       buffer: "",
       joined: nil,
       parts: nil,
       next: 1,
       waiting: %{},
       subs: %{}
     }}
  end

  @impl true
  def handle_call({:request, _op, _params}, _from, state)
      when map_size(state.waiting) >= @max_waiting,
      do: {:reply, {:error, :busy}, state}

  def handle_call({:request, op, params}, from, state) do
    # An id is never used again, so a late reply is told apart.
    id = Integer.to_string(state.next)
    timer = Process.send_after(self(), {:deadline, id}, Ops.deadline(op) + @margin_ms)
    send_request(state, id, op, params, {from, timer})
  end

  @impl true
  def handle_info(:read, state), do: active(state)

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    case Reader.read(state.buffer <> data, state.joined) do
      {:ok, messages, buffer, joined} ->
        messages(messages, %{state | buffer: buffer, joined: joined})

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
    if state.subs[sub] == :live,
      do: send_frame(%{"type" => "ack", "sub" => sub, "seq" => seq}, state),
      else: {:noreply, state}
  end

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

  defp message({:ping, payload}, state),
    do: sent(Wire.send_frame(state.socket, 10, payload), state)

  defp message({:close, <<code::16, _reason::binary>>}, state), do: closed(code, state)
  defp message({:close, _payload}, state), do: closed(nil, state)

  defp message({:text, text}, state) do
    case Frame.decode(text, state.parts) do
      {:more, parts} -> {:noreply, %{state | parts: parts}}
      {:close, _code} -> broken(state)
      {_whole, frame} -> frame(frame, %{state | parts: nil})
    end
  end

  # Every reply is checked, a late one too.
  defp frame(%{"type" => "res", "id" => id} = res, state) when is_map_key(state.waiting, id) do
    {{op, caller}, waiting} = Map.pop(state.waiting, id)

    case Decode.result(op, res) do
      {:ok, result} -> reply(caller, op, result, %{state | waiting: waiting})
      :error -> broken(state)
    end
  end

  defp frame(%{"type" => "event", "sub" => sub, "event" => event}, state)
       when is_map_key(state.subs, sub) do
    case Decode.event(event) do
      {:ok, %Event{} = event} ->
        if state.subs[sub] == :live, do: send(state.owner, {:helyx_event, event})
        {:noreply, state}

      # An event of a type that this client does not know.
      {:ok, nil} ->
        {:noreply, state}

      :error ->
        broken(state)
    end
  end

  defp frame(%{"type" => "session_end", "sub" => sub, "reason" => reason}, state)
       when is_map_key(state.subs, sub) and reason in ["stopped", "crashed"] do
    {kind, subs} = Map.pop(state.subs, sub)
    reason = if reason == "stopped", do: :stopped, else: :crashed
    if kind == :live, do: send(state.owner, {:helyx_end, sub, reason})
    {:noreply, %{state | subs: subs}}
  end

  defp frame(_frame, state), do: broken(state)

  # The server makes each `sub` unique on the connection.
  defp reply(_caller, "subscribe", {:ok, _snapshot_or_replay, sub}, state)
       when is_map_key(state.subs, sub),
       do: broken(state)

  # A late reply: its caller got `timeout`. A subscription that it made
  # ends with `unsubscribe`, and its frames are dropped.
  defp reply(:late, "subscribe", {:ok, _snapshot_or_replay, sub}, state) do
    state = put_in(state.subs[sub], :dropped)
    id = Integer.to_string(state.next)
    send_request(state, id, "unsubscribe", %{"sub" => sub}, {:unsubscribe, sub})
  end

  defp reply(:late, _op, _result, state), do: {:noreply, state}

  defp reply({:unsubscribe, sub}, _op, _result, state),
    do: {:noreply, %{state | subs: Map.delete(state.subs, sub)}}

  defp reply({from, timer}, op, result, state) do
    Process.cancel_timer(timer)
    GenServer.reply(from, result)

    case {op, result} do
      {"subscribe", {:ok, _snapshot_or_replay, sub}} -> {:noreply, put_in(state.subs[sub], :live)}
      _other -> {:noreply, state}
    end
  end

  defp send_request(state, id, op, params, caller) do
    state = %{state | next: state.next + 1, waiting: Map.put(state.waiting, id, {op, caller})}
    send_frame(%{"type" => "req", "id" => id, "op" => op, "params" => params}, state)
  end

  # The texts of a frame, its parts too, go out one after the other, so no
  # pong comes between them.
  defp send_frame(frame, state) do
    frame
    |> Frame.encode()
    |> Enum.reduce(:ok, fn
      text, :ok -> Wire.send_frame(state.socket, 1, IO.iodata_to_binary(text))
      _text, error -> error
    end)
    |> sent(state)
  end

  defp sent(:ok, state), do: {:noreply, state}
  defp sent({:error, _reason}, state), do: closed(nil, state)

  defp broken(state), do: {:stop, {:shutdown, :broken}, state}
  defp closed(code, state), do: {:stop, {:shutdown, {:closed, code}}, state}
end
