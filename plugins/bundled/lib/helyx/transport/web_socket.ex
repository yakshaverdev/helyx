defmodule Helyx.Transport.WebSocket do
  @moduledoc """
  The WebSocket server of the wire contract (ADR 0008,
  `docs/features/wire-protocol.md`). A product starts it in its own
  supervision tree; it uses only the public session and server API.

      {Helyx.Transport.WebSocket, core: MyApp.Core, port: 4040, token: token}

  Options: `:core` and `:port` are required. `:ip` is the bind address,
  loopback by default; any other address needs a `:token`, and the start
  fails with `{:error, :token_required}` without one. A configured token is
  needed in the `hello` of every connection. `:origins` lists the allowed
  values of the `Origin` header, none by default: an upgrade with an
  `Origin` outside the list gets HTTP 403, and an upgrade over the 64
  connections of the server HTTP 503.
  """

  @behaviour Plug

  # The protocol number and the SHA-256 of the schema in
  # `docs/features/wire-protocol.md`; a schema change needs a new number.
  @protocol 1
  @schema_sha256 "774b5fc5404dd75e9e3996110e54c5bdf1dc06845531a497706c59924692fe16"

  @max_connections 64

  @doc "The protocol number of the server."
  @spec protocol() :: pos_integer()
  def protocol, do: @protocol

  @doc "The SHA-256 of the wire schema of `protocol/0`, in lower-case hex."
  @spec schema_sha256() :: String.t()
  def schema_sha256, do: @schema_sha256

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

  @doc "Starts the server; see the moduledoc for the options."
  @spec start_link(keyword()) ::
          Supervisor.on_start() | {:error, :token_required | :invalid_options}
  def start_link(opts) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    token = Keyword.get(opts, :token)
    origins = Keyword.get(opts, :origins, [])

    cond do
      not token?(token) or not origins?(origins) ->
        {:error, :invalid_options}

      token == nil and not loopback?(ip) ->
        {:error, :token_required}

      true ->
        config = %{core: Keyword.fetch!(opts, :core), token: token, origins: origins, gate: nil}
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
  defp bandit(config, ip, port) do
    {Bandit,
     plug: {__MODULE__, config},
     ip: ip,
     port: port,
     startup_log: false,
     websocket_options: [
       max_frame_size: Helyx.Transport.WebSocket.Frame.max_frame() + 14,
       max_fragmented_message_size: Helyx.Transport.WebSocket.Frame.max_frame()
     ]}
  end

  @doc "The port that the server listens on, for a start with port 0."
  @spec port(Supervisor.supervisor()) :: :inet.port_number()
  def port(transport) do
    [bandit] = for {_id, pid, :supervisor, _} <- Supervisor.which_children(transport), do: pid
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    port
  end

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
