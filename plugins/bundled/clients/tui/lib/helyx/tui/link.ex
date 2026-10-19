defmodule Helyx.TUI.Link do
  @moduledoc false
  # The session of the TUI (docs/features/tui-attach.md, slice 3): a
  # session of Core in the node, or this struct, a session of the server
  # over the wire (`Helyx.TUI.Wire.Connection`). Each operation of the TUI
  # on its session goes through here and gives the result of Core for both.
  # The wire adds the errors of `wire_error?/1`, which `error_text/1` names.
  # Over the wire the quit aborts nothing: the session runs on in the
  # server, and the connection ends with the TUI (decision 8).

  alias Helyx.Session
  alias Helyx.Session.File.Scan
  alias Helyx.TUI.Wire.Connection

  @enforce_keys [:conn, :id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{conn: pid(), id: String.t()}
  @type session :: Session.t() | t()

  # A frame over the bound of the server closes the connection (4413), so
  # a text over the bound of Core gets the answer of Core here: 4 MiB of
  # text is at most 24 MiB of JSON, under the 25 MiB of a frame of parts.
  @max_text_bytes Session.max_text_bytes()

  # The errors of a request of the wire that no call of Core gives.
  defguard wire_error?(reason) when reason in [:timeout, :busy, :closed, :failed]

  # The texts of the wire errors, at most 27 bytes: the footer shows them
  # as a reason too (docs/features/coding-agent.md, "TUI").
  @spec error_text(atom()) :: String.t()
  def error_text(:timeout), do: "no answer from the server"
  def error_text(:busy), do: "too many requests wait"
  def error_text(:closed), do: "no connection to the server"
  def error_text(:failed), do: "the server failed"

  # The TUI process takes the connection that the caller of
  # `Helyx.TUI.run/1` opened, and monitors it: its `:DOWN` ends the TUI.
  @spec own(session()) :: session()
  def own(%__MODULE__{conn: conn} = session) do
    _ref = Connection.take(conn)
    session
  end

  def own(%Session{} = session), do: session

  # The subscription with the asks: `{:ok, snapshot, ref}` with the monitor
  # of the session in the node, or with the sub over the wire.
  @spec subscribe(session()) ::
          {:ok, Session.Snapshot.t(), reference() | String.t()} | {:error, term()}
  def subscribe(%Session{} = session), do: Session.subscribe(session, answers: true)
  def subscribe(%__MODULE__{conn: conn, id: id}), do: Connection.subscribe(conn, id)

  @spec ack(session(), reference() | String.t(), Helyx.Event.t()) :: :ok
  def ack(%Session{} = session, _ref, event), do: Session.ack(session, event)
  def ack(%__MODULE__{conn: conn}, sub, event), do: Connection.ack(conn, sub, event)

  # The end reason of a session: of the `:DOWN` of a session of Core
  # (`Helyx.Session.end_reason/1`), or of a `session_end` of the wire.
  @spec end_reason(term()) :: :stopped | :crashed
  def end_reason({:session_end, reason}), do: reason
  def end_reason(reason), do: Session.end_reason(reason)

  # A steer, or a follow-up with `follow_up?`: `:ok`, or the reason that
  # the footer shows. A rejected message stays in the composer.
  @spec send_text(session(), String.t(), boolean()) :: :ok | {:reject, String.t()}
  def send_text(session, text, follow_up?) do
    result =
      case session do
        %Session{} when follow_up? -> Session.follow_up(session, text)
        %Session{} -> Session.steer(session, text)
        %__MODULE__{} when byte_size(text) > @max_text_bytes -> {:error, :text_too_large}
        %__MODULE__{} when follow_up? -> Connection.follow_up(session.conn, session.id, text)
        %__MODULE__{} -> Connection.steer(session.conn, session.id, text)
      end

    with {:error, reason} <- result, do: {:reject, not_sent(reason)}
  end

  # ExRatatui gives event text as a Rust `String`, so the composer holds
  # only valid UTF-8 and the session never answers `:invalid_utf8`.
  defp not_sent(:queue_full), do: "not sent: the queue is full"
  # A paste has no size bound of its own (`Session.max_text_bytes/0`).
  defp not_sent(:text_too_large), do: "not sent: over 4 MiB"
  # The end signal of the session ends the TUI next.
  defp not_sent(:session_not_found), do: "not sent: the session ended"
  defp not_sent(reason) when wire_error?(reason), do: error_text(reason)

  @spec abort(session()) :: :ok | {:error, term()}
  def abort(%Session{} = session), do: Session.abort(session)
  def abort(%__MODULE__{conn: conn, id: id}), do: Connection.abort(conn, id)

  # The abort of Escape, in a Task, so the frame loop does not wait. A wire
  # error comes back to the caller as `{Link, :abort, text}` for the footer.
  @spec abort_async(session()) :: {:ok, pid()}
  def abort_async(session) do
    tui = self()

    Task.start(fn ->
      with {:error, reason} when wire_error?(reason) <- abort(session),
           do: send(tui, {__MODULE__, :abort, error_text(reason)})
    end)
  end

  # The turn of the current session at the quit: it aborts in the node,
  # before Core stops, and runs on in the server.
  @spec quit(session()) :: :ok | {:error, term()}
  def quit(%Session{} = session), do: abort(session)
  def quit(%__MODULE__{}), do: :ok

  @spec set_model(session(), String.t()) :: :ok | {:error, term()}
  def set_model(%Session{} = session, ref), do: Session.set_model(session, ref)

  def set_model(%__MODULE__{}, ref) when byte_size(ref) > @max_text_bytes,
    do: {:error, {:invalid_model_ref, ref}}

  def set_model(%__MODULE__{conn: conn, id: id}, ref), do: Connection.set_model(conn, id, ref)

  @spec compact(session(), String.t()) :: :ok | {:error, term()}
  def compact(%Session{} = session, text), do: Session.compact(session, text)

  def compact(%__MODULE__{}, text) when byte_size(text) > @max_text_bytes,
    do: {:error, :text_too_large}

  def compact(%__MODULE__{conn: conn, id: id}, text), do: Connection.compact(conn, id, text)

  @spec answer(session(), String.t(), map()) :: :ok | {:error, term()}
  def answer(%Session{} = session, ask_id, answer), do: Session.answer(session, ask_id, answer)

  def answer(%__MODULE__{conn: conn, id: id}, ask_id, answer),
    do: Connection.answer(conn, id, ask_id, answer)

  # The open of a switch (`Helyx.TUI.Switch`), in the place of `session`:
  # a new session of `opts.cwd` with `opts.model`, or the resume of `id`.
  # The server saves in its own data folder.
  @spec open(session(), :new | {:resume, String.t()}, map()) ::
          {:ok, session()} | {:error, term()}
  def open(%Session{core: core}, :new, opts),
    do: Session.start(core, model: opts.model, cwd: opts.cwd, sessions_dir: opts.sessions_dir)

  def open(%Session{core: core}, {:resume, id}, opts),
    do: Session.resume(core, sessions_dir: opts.sessions_dir, cwd: opts.cwd, id: id)

  def open(%__MODULE__{conn: conn}, target, opts) do
    result =
      case target do
        :new -> Connection.start(conn, model: opts.model, cwd: opts.cwd)
        {:resume, id} -> Connection.resume(conn, id: id)
      end

    with {:ok, id} <- result, do: {:ok, %__MODULE__{conn: conn, id: id}}
  end

  # The end of the session that a switch leaves: its turn aborts first. A
  # session that ended first gives `:ok` too; a wire error fails the switch.
  @spec stop(session()) :: :ok | {:error, term()}
  def stop(session) do
    case stop_call(session) do
      {:error, reason} when wire_error?(reason) -> {:error, reason}
      _stopped_or_gone -> :ok
    end
  end

  defp stop_call(%Session{} = session), do: Helyx.Sessions.stop(session)
  defp stop_call(%__MODULE__{conn: conn, id: id}), do: Connection.stop(conn, id)

  # The saved sessions of `cwd` for `/resume`, all of them: a scan reads at
  # most 256 files (`Scan.list/2`), and 256 is the largest page of the wire.
  @spec saved(session(), Path.t(), Path.t()) :: {:ok, [Scan.Summary.t()]} | {:error, atom()}
  def saved(%Session{}, dir, cwd), do: {:ok, Scan.list(dir, cwd)}

  def saved(%__MODULE__{conn: conn}, _dir, cwd) do
    with {:ok, items, _next} <- Connection.list_saved(conn, cwd: cwd, limit: 256),
         do: {:ok, items}
  end

  # The line of the exit `{:connection_down, reason}` of the TUI: the end
  # of its connection (`Helyx.TUI.Wire.Connection`), or a subscribe that
  # the wire refused (`Helyx.TUI.Switch.bind/3`).
  @spec down_text(term()) :: String.t()
  def down_text({:shutdown, :broken}), do: "the server broke the wire contract"
  # A slow client: past its credits, its outbound queue, or its silence
  # (wire-protocol.md, "Close codes").
  def down_text({:shutdown, {:closed, 4408}}), do: "the server closed a slow connection"
  def down_text({:shutdown, {:closed, _code}}), do: "the server closed the connection"

  def down_text(reason) when wire_error?(reason),
    do: "could not subscribe to the session: " <> error_text(reason)

  # A connection that ended before the take, or crashed.
  def down_text(_reason), do: "the connection to the server ended"
end
