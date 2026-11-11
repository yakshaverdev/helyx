defmodule Helyx.Transport.WebSocket do
  @moduledoc """
  The WebSocket server of the wire contract (ADR 0008,
  `docs/features/wire-protocol.md`). A product starts it in its own
  supervision tree; it uses only the public session and server API.

      {Helyx.Transport.WebSocket, core: MyApp.Core, port: 4040, token: token}

  Options: `:core` and `:port` are required. `:ip` is the bind address,
  loopback by default; any other address needs a `:token`, and the start
  fails with `{:error, :token_required}` without one. With a token, the
  `hello` of every connection carries the proof of the key of the token for
  the `challenge` of that connection; no frame holds the token, and no plug
  option or process state of the transport holds the token or the key as a
  binary; `child_spec/1` gives `start_link/1` the token in a closure.
  `:authority`, `{module, arg}` with `module` a
  `Helyx.Transport.WebSocket.Authority`, takes the place of `:token`: it
  decides the credential of each `hello` and the access of each request and
  subscription; a start with both gives `{:error, :invalid_options}`, and an
  address that is not loopback needs one of the two. The authority closes a
  connection with `4401` (no credential), `4503` (no answer at the `hello`),
  or `4403` (its access changed, also through `close/2`). With no authority,
  an operation whose name starts with `hub.` answers `unknown_op`. An
  authority may also export `webhook/3`: the server then answers
  `POST /hooks/<id>` with the status that the authority decides, after it
  read the body within 1,048,576 bytes; with no authority, or one without
  the callback, every path under `/hooks` answers 404
  (`docs/features/hub.md`, decision 17).
  `:origins` lists the allowed values of the `Origin` header, none
  by default: an upgrade with an `Origin` outside the list gets HTTP 403,
  and an upgrade over the 64 connections of the server HTTP 503.

  The stop takes at most 20,000 ms (`docs/features/wire-protocol.md`,
  Bounds): a connection that has not finished its upgrade closes at once,
  and each WebSocket connection gets close `1000`. After a crash of the gate
  or of the listener, every connection stops within 15,000 ms.
  """

  @behaviour Plug

  # The protocol number and the SHA-256 of the schema in
  # `docs/features/wire-protocol.md`; a schema change needs a new number.
  @protocol 9
  @schema_sha256 "84460cb0d6da9141f6cf8024f45d02af94fc5557de4b987c60e32ca880ee7e1a"

  @max_connections 64
  # The webhook endpoint of a Hub (decision 17): one request reads at most
  # one payload, and at most 16 requests handle theirs at once.
  @max_webhooks 16
  @max_payload 1_048_576

  @doc "The protocol number of the server."
  @spec protocol() :: pos_integer()
  def protocol, do: @protocol

  @doc "The SHA-256 of the wire schema of `protocol/0`, in lower-case hex."
  @spec schema_sha256() :: String.t()
  def schema_sha256, do: @schema_sha256

  # The supervisor of the product keeps the start arguments in its state and
  # its reports, so a binary token goes in a closure there; a closure stays.
  @doc false
  def child_spec(opts) do
    opts =
      Keyword.replace_lazy(opts, :token, fn
        closure when is_function(closure, 0) -> closure
        token -> fn -> token end
      end)

    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  @doc "Starts the server; see the moduledoc for the options."
  @spec start_link(keyword()) ::
          Supervisor.on_start() | {:error, :token_required | :invalid_options}
  def start_link(opts) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    token = token(Keyword.get(opts, :token))
    origins = Keyword.get(opts, :origins, [])
    authority = Keyword.get(opts, :authority)

    case options(token, origins, authority, ip) do
      {:error, _reason} = error ->
        error

      :ok ->
        # The key is in a closure: `inspect/1` of a closure, and so a log of
        # the options or of a process state, does not print it.
        key = token && :crypto.hash(:sha256, token)

        config = %{
          core: Keyword.fetch!(opts, :core),
          key: key && fn -> key end,
          origins: origins,
          authority: authority,
          gate: nil,
          webhook_gate: nil
        }

        start(config, ip, Keyword.fetch!(opts, :port))
    end
  end

  # A crash of the gate or of the listener ends the transport, and its
  # supervisor in the product starts both again with a new gate. The drain
  # starts last, so it is the first step of the stop.
  defp start(config, ip, port) do
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_all, max_restarts: 0)

    with {:ok, gate} <-
           Supervisor.start_child(sup, {Helyx.Transport.WebSocket.Gate, @max_connections}),
         {:ok, webhook_gate} <-
           Supervisor.start_child(
             sup,
             Supervisor.child_spec({Helyx.Transport.WebSocket.Gate, @max_webhooks},
               id: :webhook_gate
             )
           ),
         {:ok, bandit} <-
           Supervisor.start_child(
             sup,
             bandit(%{config | gate: gate, webhook_gate: webhook_gate}, ip, port)
           ),
         {:ok, _drain} <-
           Supervisor.start_child(sup, {Helyx.Transport.WebSocket.Drain, {bandit, gate}}) do
      {:ok, sup}
    else
      error ->
        Supervisor.stop(sup)
        error
    end
  end

  # Bandit closes a WebSocket frame over the bound with 1009 before it reads
  # the payload; 14 bytes are the frame header. A message of fragments has
  # the same bound.
  #
  # The server speaks only the one HTTP/1.1 upgrade of a connection, so a
  # refused upgrade closes and the bytes after it are not read as the next
  # request, and it logs no protocol error.
  defp bandit(config, ip, port) do
    {
      Bandit,
      plug: {__MODULE__, config},
      ip: ip,
      port: port,
      startup_log: false,
      http_1_options: [max_requests: 1],
      http_2_options: [enabled: false],
      http_options: [log_protocol_errors: false],
      thousand_island_options: [
        # A stop on an error logs no crash report, which would hold the bytes
        # of the frame; a socket error that comes as a message still logs one.
        silent_terminate_on_error: true,
        # Thousand Island stops its acceptor groups one after another, each
        # within the shutdown of its connections, so one group gives the stop
        # one bound (`docs/features/wire-protocol.md`, Bounds).
        num_acceptors: 1,
        shutdown_timeout: 15_000
      ],
      websocket_options: [
        max_frame_size: Helyx.Transport.WebSocket.Frame.max_frame() + 14,
        max_fragmented_message_size: Helyx.Transport.WebSocket.Frame.max_frame(),
        # The decode of `Frame` checks UTF-8 once; a bad text closes with 4400.
        validate_text_frames: false,
        log_protocol_errors: false
      ]
    }
  end

  @doc "The port that the server listens on, for a start with port 0."
  @spec port(Supervisor.supervisor()) :: :inet.port_number()
  def port(transport) do
    [bandit] = for {_id, pid, :supervisor, _} <- Supervisor.which_children(transport), do: pid
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    port
  end

  # The token of `child_spec/1` comes in a closure.
  defp token(closure) when is_function(closure, 0), do: closure.()
  defp token(token), do: token

  defp options(token, origins, authority, ip) do
    cond do
      not valid?(token, origins, authority) ->
        {:error, :invalid_options}

      token == nil and authority == nil and not loopback?(ip) ->
        {:error, :token_required}

      true ->
        :ok
    end
  end

  # One credential rule: the server token or the authority, not both.
  defp valid?(token, origins, authority),
    do:
      token?(token) and origins?(origins) and authority?(authority) and
        (token == nil or authority == nil)

  defp token?(token), do: token == nil or (is_binary(token) and token != "")
  defp origins?(origins), do: is_list(origins) and Enum.all?(origins, &is_binary/1)

  defp authority?(nil), do: true

  defp authority?({mod, _arg}) when is_atom(mod) do
    Code.ensure_loaded?(mod) and
      Helyx.Transport.WebSocket.Authority in List.flatten(
        Keyword.get_values(mod.module_info(:attributes), :behaviour)
      )
  end

  defp authority?(_authority), do: false

  @doc """
  Closes a connection with `code` 4403, after the frames that it took
  before: the authority calls it when the access of the user of the
  connection changes (`docs/features/hub.md`, decision 13).
  """
  @spec close(pid(), 4403) :: :ok
  def close(connection, 4403 = code) when is_pid(connection) do
    send(connection, {:close, code})
    :ok
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_ip), do: false

  @impl Plug
  def init(config), do: config

  @impl Plug
  def call(conn, config) do
    if webhook_path?(conn) do
      webhook(conn, config)
    else
      websocket(conn, config)
    end
  end

  # The endpoint of an event subscription (decision 17): `POST /hooks/<id>`
  # goes to the authority, which owns the signature, the prompt, and the
  # delivery. Anything else on the path is 404, and so is the whole path
  # under an authority without the callback.
  defp webhook(conn, config) do
    with "POST" <- conn.method,
         ["hooks", id] <- conn.path_info,
         true <- byte_size(id) in 1..64,
         {:ok, authority} <- webhook_authority(config),
         :ok <- Helyx.Transport.WebSocket.Gate.enter(config.webhook_gate) do
      answer(authority, id, read_body(conn))
    else
      :full ->
        conn |> Plug.Conn.send_resp(503, "") |> Plug.Conn.halt()

      _ ->
        conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt()
    end
  end

  defp webhook_path?(%Plug.Conn{path_info: ["hooks" | _]}), do: true
  defp webhook_path?(%Plug.Conn{}), do: false

  defp webhook_authority(%{authority: {mod, _arg} = authority}) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :webhook, 3),
      do: {:ok, authority},
      else: :error
  end

  defp webhook_authority(_config), do: :error

  # The body within the payload bound; a longer one is 413 before the
  # authority sees it.
  defp read_body(conn) do
    case Plug.Conn.read_body(conn,
           length: @max_payload,
           read_length: @max_payload,
           read_timeout: 30_000
         ) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:over, conn}
      {:error, _reason} -> {:error, conn}
    end
  end

  defp answer({mod, arg}, id, {:ok, body, read}) do
    request = %{headers: read.req_headers, body: body}

    try do
      case mod.webhook(arg, id, request) do
        {:ok, status, text} when status in 200..599 -> respond(read, status, text)
        _other -> respond(read, 503, "")
      end
    catch
      :exit, _reason -> respond(read, 503, "")
    end
  end

  defp answer(_authority, _id, {:over, read}), do: respond(read, 413, "")
  defp answer(_authority, _id, {:error, read}), do: respond(read, 400, "")

  defp respond(conn, status, text) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, text)
    |> Plug.Conn.halt()
  end

  defp websocket(conn, config) do
    cond do
      not origin?(Plug.Conn.get_req_header(conn, "origin"), config.origins) ->
        conn |> Plug.Conn.send_resp(403, "") |> Plug.Conn.halt()

      Helyx.Transport.WebSocket.Gate.enter(config.gate) != :ok ->
        conn |> Plug.Conn.send_resp(503, "") |> Plug.Conn.halt()

      true ->
        conn
        |> Plug.Conn.upgrade_adapter(
          :websocket,
          {Helyx.Transport.WebSocket.Connection, config, []}
        )
        |> Plug.Conn.halt()
    end
  end

  defp origin?([], _origins), do: true
  defp origin?([origin], origins), do: origin in origins
  defp origin?(_two_or_more, _origins), do: false
end
