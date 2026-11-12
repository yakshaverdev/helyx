defmodule Helyx.Transport.WebSocket.Runner.Connection do
  @moduledoc false
  # The client connection of a runner (`docs/features/remote-hands.md`,
  # "The connection"): TLS 1.3 to the address of the link, the certificate
  # checked against the pin before any frame, the WebSocket upgrade, and the
  # wire handshake. The frame codec is `Mint.WebSocket`, the one the TUI
  # uses; this module adds the TLS socket and the handshake.

  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.{Frame, TLS}

  # `Mint.WebSocket.recv/3` types its error with the opaque connection of
  # Mint, so Dialyzer drops the error branch of `recv_reply/5` and
  # `recv_next/3`. The branch runs: a closed socket returns the error.
  @dialyzer {:nowarn_function, [recv_reply: 5, recv_next: 3]}

  # The most lease that a registration may answer: the top of the server's
  # lease setting, `Helyx.Transport.WebSocket.hands_lease_ms/0` (120,000),
  # and a value that a timer takes.
  @max_lease_ms 120_000

  @doc "The most lease that a registration may answer, in milliseconds."
  @spec max_lease_ms() :: pos_integer()
  def max_lease_ms, do: @max_lease_ms

  @doc """
  The `lease_ms` of a registration: `{:ok, lease}` for 1 to
  `max_lease_ms/0`, else `:bad_frame`.
  """
  @spec lease_ms(term()) :: {:ok, pos_integer()} | :bad_frame
  def lease_ms(lease) when is_integer(lease) and lease in 1..@max_lease_ms,
    do: {:ok, lease}

  def lease_ms(_lease), do: :bad_frame

  @doc """
  Connects to `host:port` with TLS 1.3, checks the certificate of the peer
  against `pin`, and upgrades the connection. Gives the connection state, or
  `:bad_pin`, `:timeout`, `:closed`, or `{:http, status}`.
  """
  @spec open(term(), pos_integer(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def open(host, port, pin, timeout) do
    deadline = now() + timeout

    case connect(host, port, pin, left(deadline)) do
      {:ok, conn} -> upgrade(conn, deadline)
      {:error, reason} -> {:error, reason}
    end
  end

  # The pin is the identity: no CA check and no hostname check. The peer
  # certificate is read after the handshake and refused before any frame.
  defp connect(host, port, pin, timeout) do
    opts = [
      protocols: [:http1],
      mode: :passive,
      hostname: hostname(host),
      transport_opts: [
        verify: :verify_none,
        server_name_indication: :disable,
        versions: [:"tlsv1.3"],
        timeout: timeout,
        send_timeout: timeout,
        inet6: ipv6?(host)
      ]
    ]

    case Mint.HTTP.connect(:https, host, port, opts) do
      {:ok, conn} -> peer(conn, pin)
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp peer(conn, pin) do
    case :ssl.peercert(Mint.HTTP.get_socket(conn)) do
      {:ok, cert} ->
        case TLS.verify(cert, pin) do
          {:valid, _pin} ->
            {:ok, conn}

          {:fail, _reason} ->
            Mint.HTTP.close(conn)
            {:error, :bad_pin}
        end

      {:error, _reason} ->
        Mint.HTTP.close(conn)
        {:error, :bad_pin}
    end
  end

  defp upgrade(conn, deadline) do
    with {:ok, conn, ref} <- Mint.WebSocket.upgrade(:wss, conn, "/", []),
         {:ok, conn, status, headers, early} <- reply(conn, ref, deadline),
         {:ok, conn, ws} <- Mint.WebSocket.new(conn, ref, status, headers, mode: :active) do
      {:ok,
       %{
         conn: conn,
         ws: ws,
         ref: ref,
         socket: Mint.HTTP.get_socket(conn),
         frames: [],
         early: early
       }}
    else
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, error(reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reply(conn, ref, deadline, acc \\ {nil, [], []}) do
    case left(deadline) do
      0 ->
        Mint.HTTP.close(conn)
        {:error, :timeout}

      wait ->
        recv_reply(Mint.WebSocket.recv(conn, 0, wait), conn, ref, acc, deadline)
    end
  end

  # The reply can come in several reads: one that does not end it reads again.
  defp recv_reply({:ok, conn, responses}, _old, ref, acc, deadline) do
    case Enum.reduce(responses, acc, &response(&1, ref, &2)) do
      {:done, status, headers, early} ->
        {:ok, conn, status, headers, early}

      {:error, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}

      acc ->
        reply(conn, ref, deadline, acc)
    end
  end

  defp recv_reply({:error, conn, reason, responses}, _old, ref, acc, _deadline) do
    case Enum.reduce(responses, acc, &response(&1, ref, &2)) do
      {:done, status, headers, early} ->
        {:ok, conn, status, headers, early}

      _other ->
        Mint.HTTP.close(conn)
        {:error, error(reason)}
    end
  end

  defp response(_response, _ref, {:error, _reason} = error), do: error

  defp response({:status, ref, 101}, ref, {_status, headers, early}),
    do: {101, headers, early}

  defp response({:status, ref, status}, ref, _acc), do: {:error, {:http, status}}

  defp response({:headers, ref, headers}, ref, {status, _old, early}),
    do: {status, headers, early}

  defp response({:data, ref, data}, ref, {:done, status, headers, early}),
    do: {:done, status, headers, [early, data]}

  defp response({:data, ref, data}, ref, {status, headers, early}),
    do: {status, headers, [early, data]}

  defp response({:done, ref}, ref, {101, headers, early}),
    do: {:done, 101, headers, IO.iodata_to_binary(early)}

  defp response({:done, ref}, ref, _acc), do: {:error, :upgrade}

  defp response(_response, _ref, acc), do: acc

  @doc """
  Reads the `challenge`, sends the hello that `hello` builds from the nonce,
  and reads the `welcome`. Gives the connection after `welcome`.
  """
  @spec handshake(map(), (binary() -> map()), pos_integer()) ::
          {:ok, map()} | {:error, term(), map()}
  def handshake(state, hello, timeout) do
    deadline = now() + timeout

    with {:ok, nonce, state} <- challenge(state, deadline),
         {:ok, state} <- send_frame(state, hello.(nonce)),
         {:ok, frame, state} <- text(state, deadline) do
      welcome(frame, state)
    end
  end

  defp challenge(state, deadline) do
    case text(state, deadline) do
      {:ok, frame, state} ->
        case nonce(frame) do
          {:ok, nonce} -> {:ok, nonce, state}
          :error -> {:error, :bad_frame, state}
        end

      error ->
        error
    end
  end

  defp nonce(%{"type" => "challenge", "nonce" => nonce}) when is_binary(nonce) do
    case Base.decode64(nonce) do
      {:ok, <<_nonce::binary-size(32)>> = nonce} -> {:ok, nonce}
      _other -> :error
    end
  end

  defp nonce(_frame), do: :error

  defp welcome(%{"type" => "welcome", "protocol" => protocol}, state)
       when is_integer(protocol) do
    if protocol == WebSocket.protocol(),
      do: {:ok, state},
      else: {:error, :bad_frame, state}
  end

  defp welcome(
         %{"type" => "refused", "code" => "protocol", "server_protocol" => server},
         state
       )
       when is_integer(server),
       do: {:error, {:refused, server}, state}

  defp welcome(_frame, state), do: {:error, :bad_frame, state}

  @doc """
  Sends `hands.register {runner, folder}` and reads its answer: `{:ok,
  lease_ms, state}`, `{:error, :unauthorized, state}`, or a failure.
  """
  @spec register(map(), String.t(), String.t(), pos_integer()) ::
          {:ok, pos_integer(), map()} | {:error, term(), map()}
  def register(state, name, folder, timeout) do
    deadline = now() + timeout
    id = "hands.register"

    request = %{
      "type" => "req",
      "id" => id,
      "op" => "hands.register",
      "params" => %{"runner" => name, "folder" => folder}
    }

    with {:ok, state} <- send_frame(state, request),
         {:ok, frame, state} <- await_res(state, id, deadline) do
      case frame do
        %{"type" => "res", "id" => ^id, "ok" => true, "result" => %{"lease_ms" => lease}} ->
          lease_answer(lease, state)

        %{"type" => "res", "id" => ^id, "ok" => false, "error" => %{"code" => code}} ->
          {:error, server_error(code), state}

        _other ->
          {:error, :bad_frame, state}
      end
    end
  end

  defp lease_answer(lease, state) do
    case lease_ms(lease) do
      {:ok, lease} -> {:ok, lease, state}
      :bad_frame -> {:error, :bad_frame, state}
    end
  end

  defp await_res(state, id, deadline) do
    with {:ok, frame, state} <- text(state, deadline) do
      case frame do
        %{"type" => "res", "id" => ^id} -> {:ok, frame, state}
        _other -> await_res(state, id, deadline)
      end
    end
  end

  defp server_error("unauthorized"), do: :unauthorized
  defp server_error(code), do: {:server, code}

  @doc "Switches the upgraded socket to active mode."
  @spec activate(map()) :: {:ok, map()} | {:error, term(), map()}
  def activate(state) do
    case Mint.HTTP.set_mode(state.conn, :active) do
      {:ok, conn} -> {:ok, %{state | conn: conn}}
      {:error, _reason} -> {:error, :closed, state}
    end
  end

  @doc """
  Streams one message of the socket to the WebSocket decoder and gives its
  frames.
  """
  @spec stream(map(), term()) :: {:ok, [term()], map()} | {:error, term(), map()}
  def stream(state, message) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        decode(%{state | conn: conn}, responses)

      {:error, conn, reason, _responses} ->
        {:error, error(reason), %{state | conn: conn}}

      :unknown ->
        {:error, :bad_frame, state}
    end
  end

  defp decode(state, responses) do
    case data(responses) do
      "" ->
        {:ok, [], state}

      data ->
        case Mint.WebSocket.decode(state.ws, data) do
          {:ok, ws, frames} -> {:ok, frames, %{state | ws: ws}}
          {:error, ws, _reason} -> {:error, :bad_frame, %{state | ws: ws}}
        end
    end
  end

  @doc "Sends one wire frame as a text frame."
  @spec send_frame(map(), map()) :: {:ok, map()} | {:error, term(), map()}
  def send_frame(state, frame), do: send_ws(state, {:text, JSON.encode!(frame)})

  @doc "Answers a ping with a pong."
  @spec pong(map(), binary()) :: {:ok, map()} | {:error, term(), map()}
  def pong(state, payload), do: send_ws(state, {:pong, payload})

  defp send_ws(state, frame) do
    case Mint.WebSocket.encode(state.ws, frame) do
      {:ok, ws, bytes} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, bytes) do
          {:ok, conn} ->
            {:ok, %{state | ws: ws, conn: conn}}

          {:error, conn, reason} ->
            {:error, error(reason), %{state | ws: ws, conn: conn}}
        end

      {:error, ws, reason} ->
        {:error, error(reason), %{state | ws: ws}}
    end
  end

  @doc "Closes the connection."
  @spec close(map() | nil) :: :ok
  def close(nil), do: :ok

  def close(%{conn: conn}) do
    Mint.HTTP.close(conn)
    :ok
  end

  # The next frame of the server, in order, with a ping skipped: the caller
  # answers it, so the server keeps the connection for its idle rule.
  defp text(state, deadline) do
    case next(state, deadline) do
      {:ok, {:text, text}, state} ->
        case Frame.decode(text, nil, :outbound) do
          {:frame, frame} -> {:ok, frame, state}
          {:close, _code} -> {:error, :bad_frame, state}
        end

      {:ok, {:ping, payload}, state} ->
        with {:ok, state} <- pong(state, payload) do
          text(state, deadline)
        end

      {:ok, {:pong, _payload}, state} ->
        text(state, deadline)

      {:ok, {:close, code, _reason}, state} ->
        {:error, close_error(code), state}

      {:ok, _other, state} ->
        {:error, :bad_frame, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp next(%{frames: [frame | rest]} = state, _deadline),
    do: {:ok, frame, %{state | frames: rest}}

  defp next(%{early: early} = state, deadline) when early != "" do
    decode_next(%{state | early: ""}, deadline, early)
  end

  defp next(state, deadline) do
    case left(deadline) do
      0 -> {:error, :timeout, state}
      wait -> recv_next(Mint.WebSocket.recv(state.conn, 0, wait), state, deadline)
    end
  end

  defp recv_next({:ok, conn, responses}, state, deadline) do
    state = %{state | conn: conn}

    case data(responses) do
      "" -> next(state, deadline)
      data -> decode_next(state, deadline, data)
    end
  end

  defp recv_next({:error, conn, reason, _responses}, state, _deadline),
    do: {:error, error(reason), %{state | conn: conn}}

  defp decode_next(state, deadline, data) do
    case Mint.WebSocket.decode(state.ws, data) do
      {:ok, ws, frames} -> next(%{state | ws: ws, frames: frames}, deadline)
      {:error, ws, _reason} -> {:error, :bad_frame, %{state | ws: ws}}
    end
  end

  defp data(responses),
    do: IO.iodata_to_binary(for {:data, _ref, data} <- responses, do: data)

  defp close_error(4401), do: :unauthorized
  defp close_error(nil), do: :closed
  defp close_error(code), do: {:close, code}

  defp error(%Mint.TransportError{reason: :timeout}), do: :timeout
  defp error(%Mint.TransportError{reason: :closed}), do: :closed
  defp error(%Mint.TransportError{reason: reason}), do: {:transport, reason}
  defp error(reason), do: {:transport, reason}

  defp ipv6?(ip) when is_tuple(ip), do: tuple_size(ip) == 8
  defp ipv6?(_host), do: false

  # Mint needs a hostname when the address is a tuple, for the Host header
  # and the TLS options, though the pin is the only identity check. An IPv6
  # literal is bracketed in the Host header.
  defp hostname(host) when is_binary(host), do: host

  defp hostname(ip) when tuple_size(ip) == 8,
    do: "[" <> to_string(:inet.ntoa(ip)) <> "]"

  defp hostname(ip), do: ip |> :inet.ntoa() |> to_string()

  defp now, do: System.monotonic_time(:millisecond)
  defp left(deadline), do: max(deadline - now(), 0)
end
