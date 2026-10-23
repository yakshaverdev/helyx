defmodule Helyx.TUI.Link do
  @moduledoc false
  # The session of the TUI (docs/features/tui-attach.md, slice 3): a
  # session of the server over the wire (`Helyx.TUI.Wire.Connection`). Each
  # operation of the TUI on its session goes through here and gives the
  # result of the Core call of the server, with the errors of
  # `wire_error?/1`, which `error_text/1` names. The quit aborts nothing:
  # the session runs on in the server, and the connection ends with the
  # TUI (decision 8). The TUI uses only the wire (decision 12).

  alias Helyx.Session.File.Scan
  alias Helyx.TUI.Wire.Connection

  @enforce_keys [:conn, :id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{conn: pid(), id: String.t()}

  # A frame over the bound of the server closes the connection (4413), so
  # a text over the bound of Core gets the answer of Core here: 4 MiB of
  # text is at most 24 MiB of JSON, under the 25 MiB of a frame of parts.
  @max_text_bytes Helyx.Session.max_text_bytes()

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
  @spec own(t()) :: t()
  def own(%__MODULE__{conn: conn} = session) do
    _ref = Connection.take(conn)
    session
  end

  # The subscription with the asks: `{:ok, snapshot, sub}`. `after:` gives
  # a replay or a snapshot (`Connection.subscribe/3`).
  @spec subscribe(t(), keyword()) ::
          {:ok, Helyx.Session.Snapshot.t() | {:replay, [Helyx.Event.t()]}, String.t()}
          | {:error, term()}
  def subscribe(%__MODULE__{conn: conn, id: id}, opts), do: Connection.subscribe(conn, id, opts)

  # The session over a new connection on `socket` after a lost one. The
  # socket goes to the connection, which the caller owns.
  @spec reopen(t(), :gen_tcp.socket()) :: t()
  def reopen(%__MODULE__{} = session, socket) do
    {:ok, conn, _ref} = Connection.open(socket)
    %{session | conn: conn}
  end

  @spec ack(t(), String.t(), Helyx.Event.t()) :: :ok
  def ack(%__MODULE__{conn: conn}, sub, event), do: Connection.ack(conn, sub, event)

  # A steer, or a follow-up with `follow_up?`: `:ok`, or the reason that
  # the footer shows. A rejected message stays in the composer.
  @spec send_text(t(), String.t(), boolean()) :: :ok | {:reject, String.t()}
  def send_text(session, text, follow_up?) do
    result =
      cond do
        byte_size(text) > @max_text_bytes -> {:error, :text_too_large}
        follow_up? -> Connection.follow_up(session.conn, session.id, text)
        true -> Connection.steer(session.conn, session.id, text)
      end

    with {:error, reason} <- result, do: {:reject, not_sent(reason)}
  end

  # ExRatatui gives event text as a Rust `String`, so the composer holds
  # only valid UTF-8 and the session never answers `:invalid_utf8`.
  defp not_sent(:queue_full), do: "not sent: the queue is full"
  # A paste has no size bound of its own (`Helyx.Session.max_text_bytes/0`).
  defp not_sent(:text_too_large), do: "not sent: over 4 MiB"
  # The end signal of the session ends the TUI next.
  defp not_sent(:session_not_found), do: "not sent: the session ended"
  defp not_sent(reason) when wire_error?(reason), do: error_text(reason)

  # The abort of Escape, in a Task, so the frame loop does not wait. A wire
  # error comes back to the caller as `{Link, :abort, text}` for the footer.
  @spec abort_async(t()) :: {:ok, pid()}
  def abort_async(%__MODULE__{conn: conn, id: id}) do
    tui = self()

    Task.start(fn ->
      with {:error, reason} when wire_error?(reason) <- Connection.abort(conn, id),
           do: send(tui, {__MODULE__, :abort, error_text(reason)})
    end)
  end

  @spec set_model(t(), String.t()) :: :ok | {:error, term()}
  def set_model(%__MODULE__{}, ref) when byte_size(ref) > @max_text_bytes,
    do: {:error, {:invalid_model_ref, ref}}

  def set_model(%__MODULE__{conn: conn, id: id}, ref), do: Connection.set_model(conn, id, ref)

  @spec compact(t(), String.t()) :: :ok | {:error, term()}
  def compact(%__MODULE__{}, text) when byte_size(text) > @max_text_bytes,
    do: {:error, :text_too_large}

  def compact(%__MODULE__{conn: conn, id: id}, text), do: Connection.compact(conn, id, text)

  @spec answer(t(), String.t(), map()) :: :ok | {:error, term()}
  def answer(%__MODULE__{conn: conn, id: id}, ask_id, answer),
    do: Connection.answer(conn, id, ask_id, answer)

  # The open of a switch (`Helyx.TUI.Switch`), in the place of `session`:
  # a new session of `opts.cwd` with `opts.model`, or the resume of `id`.
  # The server saves in its own data folder.
  @spec open(t(), :new | {:resume, String.t()}, map()) :: {:ok, t()} | {:error, term()}
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
  @spec stop(t()) :: :ok | {:error, term()}
  def stop(%__MODULE__{conn: conn, id: id}) do
    case Connection.stop(conn, id) do
      {:error, reason} when wire_error?(reason) -> {:error, reason}
      _stopped_or_gone -> :ok
    end
  end

  # The saved sessions of `cwd` for `/resume`, all of them: a scan reads at
  # most 256 files (`Scan.list/2`), and 256 is the largest page of the wire.
  @spec saved(t(), Path.t()) :: {:ok, [Scan.Summary.t()]} | {:error, atom()}
  def saved(%__MODULE__{conn: conn}, cwd) do
    with {:ok, items, _next} <- Connection.list_saved(conn, cwd: cwd, limit: 256),
         do: {:ok, items}
  end

  # The line of the exit `{:connection_down, reason}` of the TUI: the end
  # of its connection (`Helyx.TUI.Wire.Connection`), a subscribe that the
  # wire refused (`Helyx.TUI.Switch.bind/3`), or a failed reconnect.
  @spec down_text(term()) :: String.t()
  def down_text({:shutdown, :broken}), do: "the server broke the wire contract"
  # A slow client: past its credits, its outbound queue, or its silence
  # (wire-protocol.md, "Close codes").
  def down_text({:shutdown, {:closed, 4408}}), do: "the server closed a slow connection"
  def down_text({:shutdown, {:closed, _code}}), do: "the server closed the connection"

  def down_text(reason) when wire_error?(reason),
    do: "could not subscribe to the session: " <> error_text(reason)

  # A lost connection whose reconnect failed: the line of the attach.
  def down_text({:reconnect, text}), do: "lost the connection to the server: " <> text

  # A connection that ended before the take, or crashed.
  def down_text(_reason), do: "the connection to the server ended"
end
