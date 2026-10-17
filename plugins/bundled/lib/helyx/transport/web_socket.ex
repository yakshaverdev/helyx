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
  `:origins` lists the allowed values of the `Origin` header, none
  by default: an upgrade with an `Origin` outside the list gets HTTP 403,
  and an upgrade over the 64 connections of the server HTTP 503.
  """

  @behaviour Plug

  # The protocol number and the SHA-256 of the schema in
  # `docs/features/wire-protocol.md`; a schema change needs a new number.
  @protocol 2
  @schema_sha256 "14432dd0cb12e5dd55f5e2500575c243753af6a0efbf205efb888ab71910718d"

  @max_connections 64

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

    cond do
      not token?(token) or not origins?(origins) ->
        {:error, :invalid_options}

      token == nil and not loopback?(ip) ->
        {:error, :token_required}

      true ->
        # The key is in a closure: `inspect/1` of a closure, and so a log of
        # the options or of a process state, does not print it.
        key = token && :crypto.hash(:sha256, token)

        config = %{
          core: Keyword.fetch!(opts, :core),
          key: key && fn -> key end,
          origins: origins,
          gate: nil
        }

        start(config, ip, Keyword.fetch!(opts, :port))
    end
  end

  # A crash of the gate or of the listener ends the transport, and its
  # supervisor in the product starts both again with a new gate.
  defp start(config, ip, port) do
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_all, max_restarts: 0)

    with {:ok, gate} <-
           Supervisor.start_child(sup, {Helyx.Transport.WebSocket.Gate, @max_connections}),
         {:ok, _bandit} <- Supervisor.start_child(sup, bandit(%{config | gate: gate}, ip, port)) do
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
      thousand_island_options: [silent_terminate_on_error: true],
      websocket_options: [
        max_frame_size: Helyx.Transport.WebSocket.Frame.max_frame() + 14,
        max_fragmented_message_size: Helyx.Transport.WebSocket.Frame.max_frame(),
        # `JSON.decode/1` checks UTF-8 once; a bad text closes with 4400.
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

  defp token?(token), do: token == nil or (is_binary(token) and token != "")
  defp origins?(origins), do: is_list(origins) and Enum.all?(origins, &is_binary/1)

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_ip), do: false

  @impl Plug
  def init(config), do: config

  @impl Plug
  def call(conn, config) do
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
