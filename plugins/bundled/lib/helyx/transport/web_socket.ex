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
  an operation whose name starts with `hub.` and the records feed's
  `records.subscribe` answer `unknown_op`, and `records.unsubscribe` answers
  `unknown_sub` (no subscription exists). An
  authority may also export `webhook/3`: the server then answers
  `POST /hooks/<id>` with the status that the authority decides, after it
  read the body within 1,048,576 bytes; with no authority, or one without
  the callback, every path under `/hooks` answers 404
  (`docs/features/hub.md`, decision 17).
  `:origins` lists the allowed values of the `Origin` header, none
  by default: an upgrade with an `Origin` outside the list gets HTTP 403,
  and an upgrade over the 64 connections of the server HTTP 503.

  `:public` is a second listener of the same wire, with TLS on every
  interface (`docs/features/remote-hands.md`, "Pairing and the public
  listener"): `[ip: ip, port: port, address: "host:port"]`, where
  `address` is the text a pairing link carries. It needs `:tls`, the value
  of `Helyx.Transport.WebSocket.TLS.ensure/1`, and `:pairing`, the Hub
  whose store holds the peers; the start fails with
  `{:error, :pairing_required}` without a Hub. The public listener accepts
  no server token: a `hello` there proves a pairing link or a paired key of
  a runner or a client, and a `hello` with the proof of the server token
  closes with `4401`. A paired client acts as the default owner of the Hub.
  The loopback listener serves `pair.create`, `pair.revoke`, and `pair.list`;
  without `:public` they answer `no_public_listener`. `:hands_lease_ms` is
  the lease of a hands connection, from 30,000 to 120,000 ms, default
  `hands_lease_ms/0`.

  The stop takes at most 20,000 ms (`docs/features/wire-protocol.md`,
  Bounds): a connection that has not finished its upgrade closes at once,
  and each WebSocket connection gets close `1000`. After a crash of the gate
  or of the listener, every connection stops within 15,000 ms.
  """

  @behaviour Plug

  # The protocol number and the SHA-256 of the schema in
  # `docs/features/wire-protocol.md`; a schema change needs a new number.
  @protocol 15
  @schema_sha256 "21275cebe45ee80ed963b2e1feb4d91f023f246484db3157dbef0de89123deb3"

  @max_connections Helyx.Transport.WebSocket.Bounds.get("connections")
  # The webhook endpoint of a Hub (decision 17): one request reads at most
  # one payload, and at most 16 requests handle theirs at once.
  @max_webhooks 16
  @max_payload 1_048_576

  # The default lease of a hands connection, and the range of its option
  # (`docs/features/remote-hands.md`, "The lease setting").
  @lease_ms 45_000
  @min_lease_ms 30_000
  @max_lease_ms 120_000

  @doc "The most connections of the server, shared by both listeners."
  @spec max_connections() :: pos_integer()
  def max_connections, do: @max_connections

  @doc """
  The most TCP connections that one listener admits before the upgrade: the
  connections in the gate and one that the gate refuses with HTTP 503.
  """
  @spec tcp_connections() :: pos_integer()
  def tcp_connections, do: @max_connections + 1

  @doc "The lease of a hands connection by default, in milliseconds."
  @spec hands_lease_ms() :: pos_integer()
  def hands_lease_ms, do: @lease_ms

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
          Supervisor.on_start() | {:error, :token_required | :invalid_options | :pairing_required}
  def start_link(opts) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    token = token(Keyword.get(opts, :token))
    origins = Keyword.get(opts, :origins, [])
    authority = Keyword.get(opts, :authority)
    public = Keyword.get(opts, :public)
    tls = Keyword.get(opts, :tls)
    hub = Keyword.get(opts, :pairing)
    lease = Keyword.get(opts, :hands_lease_ms, @lease_ms)

    with :ok <- options(token, origins, authority, ip),
         :ok <- public_options(public, tls, hub),
         :ok <- lease_option(lease) do
      # The key is in a closure: `inspect/1` of a closure, and so a log of
      # the options or of a process state, does not print it.
      key = token && :crypto.hash(:sha256, token)

      # The public listener listens over TLS.
      if tls, do: {:ok, _apps} = Application.ensure_all_started(:ssl)

      config = %{
        core: Keyword.fetch!(opts, :core),
        key: key && fn -> key end,
        origins: origins,
        authority: authority,
        listener: :loopback,
        pairing: nil,
        lease_ms: lease,
        gate: nil,
        webhook_gate: nil
      }

      start(config, ip, Keyword.fetch!(opts, :port), public, tls, hub)
    end
  end

  # A crash of the gate or of the listener ends the transport, and its
  # supervisor in the product starts both again with a new gate. The drain
  # starts last, so it is the first step of the stop.
  defp start(config, ip, port, public, tls, hub) do
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_all, max_restarts: 0)

    started =
      with {:ok, pairing} <- start_pairing(sup, config, public, tls, hub),
           {:ok, gate} <-
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
               listener(
                 %{config | gate: gate, webhook_gate: webhook_gate, pairing: pairing},
                 ip,
                 port,
                 :listener
               )
             ),
           {:ok, public_parts} <- public_parts(sup, config, public, tls, pairing, gate) do
        {:ok, bandit, gate, public_parts}
      end

    case started do
      {:ok, bandit, gate, public_parts} ->
        for {public_bandit, public_gate} <- public_parts do
          Supervisor.start_child(
            sup,
            Supervisor.child_spec({Helyx.Transport.WebSocket.Drain, {public_bandit, public_gate}},
              id: :public_drain
            )
          )
        end

        Supervisor.start_child(
          sup,
          Supervisor.child_spec({Helyx.Transport.WebSocket.Drain, {bandit, gate}}, id: :drain)
        )

        {:ok, sup}

      error ->
        Supervisor.stop(sup)
        error
    end
  end

  defp start_pairing(_sup, _config, nil, _tls, _hub), do: {:ok, nil}

  defp start_pairing(sup, config, public, tls, hub) do
    Supervisor.start_child(
      sup,
      {Helyx.Transport.WebSocket.Pairing,
       hub: hub, address: public[:address], pin: tls.pin, lease_ms: config.lease_ms}
    )
  end

  # Each listener has its own gate of `max_connections/0`
  # (`docs/features/remote-hands.md`, "Public listener"): a public connection
  # never takes a place of the loopback listener, in any state.
  defp public_parts(_sup, _config, nil, _tls, _pairing, _gate), do: {:ok, []}

  defp public_parts(sup, config, public, tls, pairing, _gate) do
    with {:ok, gate} <-
           Supervisor.start_child(
             sup,
             Supervisor.child_spec({Helyx.Transport.WebSocket.Gate, @max_connections},
               id: :public_gate
             )
           ),
         {:ok, bandit} <-
           Supervisor.start_child(
             sup,
             listener(
               %{config | listener: :public, pairing: pairing, gate: gate},
               public[:ip],
               public[:port],
               :public,
               tls
             )
           ) do
      {:ok, [{bandit, gate}]}
    end
  end

  # Bandit closes a WebSocket frame over the bound with 1009 before it reads
  # the payload; 14 bytes are the frame header. A message of fragments has
  # the same bound.
  #
  # The server speaks only the one HTTP/1.1 upgrade of a connection, so a
  # refused upgrade closes and the bytes after it are not read as the next
  # request, and it logs no protocol error.
  defp listener(config, ip, port, id, tls \\ nil) do
    options = [
      plug: {__MODULE__, config},
      ip: ip,
      port: port,
      startup_log: false,
      http_1_options: [max_requests: 1],
      http_2_options: [enabled: false],
      http_options: [log_protocol_errors: false],
      thousand_island_options:
        [
          # A stop on an error logs no crash report, which would hold the bytes
          # of the frame; a socket error that comes as a message still logs one.
          silent_terminate_on_error: true,
          # Thousand Island stops its acceptor groups one after another, each
          # within the shutdown of its connections, so one group gives the stop
          # one bound (`docs/features/wire-protocol.md`, Bounds).
          num_acceptors: 1,
          # A TCP connection that sends nothing before the upgrade is bounded
          # here; the gate bounds the upgraded ones.
          num_connections: tcp_connections(),
          shutdown_timeout: 15_000
        ] ++ tls_options(tls, ip) ++ read_options(tls),
      websocket_options: [
        max_frame_size: Helyx.Transport.WebSocket.Frame.max_frame() + 14,
        max_fragmented_message_size: Helyx.Transport.WebSocket.Frame.max_frame(),
        # The decode of `Frame` checks UTF-8 once; a bad text closes with 4400.
        validate_text_frames: false,
        log_protocol_errors: false
      ]
    ]

    Supervisor.child_spec({Bandit, options}, id: id)
  end

  defp tls_options(nil, _ip), do: []

  defp tls_options(tls, ip) do
    dual_stack = if tuple_size(ip) == 8, do: [ipv6_v6only: false], else: []

    [
      transport_module: Helyx.Transport.WebSocket.TLS.Transport,
      transport_options:
        [
          certfile: String.to_charlist(tls.certfile),
          keyfile: String.to_charlist(tls.keyfile),
          versions: [:"tlsv1.3"]
        ] ++ dual_stack
    ]
  end

  # The HTTP request of the upgrade gets the bound of the TLS handshake, so
  # a TLS connection that sends no request does not hold a place. The read
  # timeout of an upgraded WebSocket connection is the ping and the lease,
  # not this value (`docs/features/remote-hands.md`, "Public listener").
  defp read_options(nil), do: []

  defp read_options(_tls),
    do: [read_timeout: Helyx.Transport.WebSocket.TLS.request_ms()]

  @doc "The port of the public listener, for a start with port 0."
  @spec public_port(Supervisor.supervisor()) :: :inet.port_number()
  def public_port(transport), do: listener_port(transport, :public)

  @doc "The port that the loopback listener listens on, for a start with port 0."
  @spec port(Supervisor.supervisor()) :: :inet.port_number()
  def port(transport), do: listener_port(transport, :listener)

  defp listener_port(transport, id) do
    {^id, bandit, :supervisor, _} = List.keyfind(Supervisor.which_children(transport), id, 0)
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

  # The public listener needs its TLS files and a Hub for its peers
  # (`docs/features/remote-hands.md`, "Pairing and the public listener").
  defp public_options(nil, _tls, _hub), do: :ok

  defp public_options(_public, _tls, nil), do: {:error, :pairing_required}

  defp public_options(public, tls, _hub) when is_list(public) do
    with %{certfile: certfile, keyfile: keyfile, pin: pin} <- tls,
         true <- is_binary(certfile) and is_binary(keyfile) and is_binary(pin),
         true <- Keyword.keyword?(public) and valid_public?(public) do
      :ok
    else
      _bad -> {:error, :invalid_options}
    end
  end

  defp public_options(_public, _tls, _hub), do: {:error, :invalid_options}

  defp valid_public?(public) do
    ip = public[:ip]
    port = public[:port]
    ip?(ip) and is_integer(port) and port in 0..65_535 and is_binary(public[:address])
  end

  defp lease_option(ms) when is_integer(ms) and ms in @min_lease_ms..@max_lease_ms, do: :ok
  defp lease_option(_ms), do: {:error, :invalid_options}

  defp ip?({_, _, _, _}), do: true
  defp ip?({_, _, _, _, _, _, _, _}), do: true
  defp ip?(_ip), do: false

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

  # The public listener serves no webhook (`docs/features/remote-hands.md`,
  # "Public listener"): the endpoint of an event subscription is of the
  # loopback listener, and a public path answers 404 before any other work.
  @impl Plug
  def call(conn, %{listener: :public} = config) do
    if webhook_path?(conn) do
      conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt()
    else
      websocket(conn, config)
    end
  end

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
        # The upgraded WebSocket of the public listener keeps no read
        # timeout of the listener: its idle rule is the ping and the lease
        # (`docs/features/remote-hands.md`, "Public listener").
        options =
          if config.listener == :public, do: [timeout: :infinity], else: []

        conn
        |> Plug.Conn.upgrade_adapter(
          :websocket,
          {Helyx.Transport.WebSocket.Connection, config, options}
        )
        |> Plug.Conn.halt()
    end
  end

  defp origin?([], _origins), do: true
  defp origin?([origin], origins), do: origin in origins
  defp origin?(_two_or_more, _origins), do: false
end
