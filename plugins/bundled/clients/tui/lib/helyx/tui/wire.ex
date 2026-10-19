defmodule Helyx.TUI.Wire do
  @moduledoc """
  The wire client of the TUI: a WebSocket connection to `helyx serve` over
  TCP and the handshake of `docs/features/wire-protocol.md` (O1). The rules
  of the client are in `docs/features/tui-attach.md`.
  """

  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.Frame

  # RFC 6455, section 1.3: the suffix of the key in `Sec-WebSocket-Accept`.
  @accept_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  # The HTTP head of the upgrade reply: each line and the count of headers.
  @max_line 8_192
  @max_headers 64

  @typedoc """
  `{:refused, server_protocol}` for a server of another protocol, `:broken`
  for a frame that the handshake does not allow, or a text: the server
  cannot be reached yet or closed the connection.
  """
  @type error :: {:refused, non_neg_integer()} | :broken | String.t()

  @doc """
  Connects to the server at `ip` and `port`, upgrades the connection, and
  passes the handshake with the proof of the token that `token` returns,
  all within `timeout` milliseconds. Returns the socket after `welcome`,
  passive and owned by the caller. A failure up to the `101` reply, a close
  of the server, and the timeout give a text; the socket is closed on every
  error. No error holds the token.
  """
  @spec connect(:inet.ip_address(), :inet.port_number(), (-> binary()), pos_integer()) ::
          {:ok, :gen_tcp.socket()} | {:error, error()}
  def connect(ip, port, token, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    opts = [
      :binary,
      active: false,
      packet: :http_bin,
      packet_size: @max_line,
      send_timeout: timeout
    ]

    case :gen_tcp.connect(ip, port, opts, timeout) do
      {:ok, socket} ->
        case handshake(socket, ip, port, token, deadline) do
          :ok ->
            {:ok, socket}

          error ->
            :gen_tcp.close(socket)
            result(error, timeout)
        end

      error ->
        result(error, timeout)
    end
  end

  # A socket error, the timeout among them, as its text.
  defp result({:error, :broken} = error, _timeout), do: error

  defp result({:error, reason}, timeout) when is_atom(reason),
    do: {:error, error_text(reason, timeout)}

  defp result(result, _timeout), do: result

  defp handshake(socket, ip, port, token, deadline) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    with :ok <- :gen_tcp.send(socket, upgrade(ip, port, key)),
         :ok <- upgraded(socket, key, deadline),
         :ok <- :inet.setopts(socket, packet: :raw),
         {:ok, nonce} <- challenge(socket, deadline),
         :ok <- send_frame(socket, hello(nonce, token)) do
      welcome(socket, deadline)
    end
  end

  defp upgrade(ip, port, key) do
    host = if tuple_size(ip) == 4, do: :inet.ntoa(ip), else: [?[, :inet.ntoa(ip), ?]]

    [
      "GET / HTTP/1.1\r\nHost: ",
      host,
      ":#{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
      "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ",
      key,
      "\r\n\r\n"
    ]
  end

  # The `101` reply with the headers of RFC 6455, section 4.1. Any other
  # reply is no server of this data folder yet: the port of a stale file
  # can be in use by another program (#777).
  defp upgraded(socket, key, deadline) do
    with {:ok, {:http_response, _version, 101, _reason}} <- recv(socket, 0, deadline),
         {:ok, headers} <- headers(socket, deadline, %{}),
         "websocket" <- String.downcase(Map.get(headers, "upgrade", "")),
         true <- "upgrade" in tokens(Map.get(headers, "connection", "")),
         true <- headers["sec-websocket-accept"] == accept(key) do
      :ok
    else
      {:ok, {:http_response, _version, status, _reason}} ->
        {:error, "the upgrade got HTTP #{status}"}

      {:error, _} = error ->
        error

      _ ->
        {:error, "the reply to the upgrade is not a WebSocket upgrade"}
    end
  end

  # The headers by their lower-case names, at most `@max_headers` lines.
  defp headers(socket, deadline, headers, lines \\ 0) do
    case recv(socket, 0, deadline) do
      {:ok, :http_eoh} ->
        {:ok, headers}

      {:ok, {:http_header, _, _, name, value}} when lines < @max_headers ->
        headers(socket, deadline, Map.put(headers, String.downcase(name), value), lines + 1)

      {:error, _} = error ->
        error

      _ ->
        {:error, "the reply to the upgrade is not a WebSocket upgrade"}
    end
  end

  defp tokens(value),
    do: value |> String.downcase() |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp accept(key), do: Base.encode64(:crypto.hash(:sha, key <> @accept_guid))

  defp challenge(socket, deadline) do
    with {:ok, %{"type" => "challenge", "nonce" => nonce}} when is_binary(nonce) <-
           frame(socket, deadline),
         {:ok, <<_::binary-size(32)>> = bytes} <- Base.decode64(nonce) do
      {:ok, bytes}
    else
      {:error, _} = error -> error
      _ -> {:error, :broken}
    end
  end

  # The proof is the HMAC-SHA256 of the nonce with the SHA-256 of the token
  # as the key (wire-protocol.md, O1); the token stays in its closure.
  defp hello(nonce, token) do
    proof = :crypto.mac(:hmac, :sha256, :crypto.hash(:sha256, token.()), nonce)
    %{"type" => "hello", "protocol" => WebSocket.protocol(), "proof" => Base.encode64(proof)}
  end

  defp welcome(socket, deadline) do
    protocol = WebSocket.protocol()

    case frame(socket, deadline) do
      {:ok, %{"type" => "welcome", "protocol" => ^protocol}} ->
        :ok

      {:ok, %{"type" => "refused", "code" => "protocol", "server_protocol" => server}}
      when is_integer(server) and server >= 0 ->
        {:error, {:refused, server}}

      {:error, _} = error ->
        error

      {:ok, _other} ->
        {:error, :broken}
    end
  end

  # The next frame of the server, decoded with the codec and the decode
  # bounds of the transport. A close is an error with its code; a part is
  # a contract break in the handshake.
  defp frame(socket, deadline) do
    with {:ok, text} <- text(socket, deadline, nil),
         {:frame, frame} <- Frame.decode(text, nil) do
      {:ok, frame}
    else
      {:error, _} = error -> error
      _ -> {:error, :broken}
    end
  end

  # The next text message, its fragments joined, at most the frame bound of
  # the wire; `joined` is nil before its first fragment. A ping or a pong
  # between them is skipped. A server does not mask (RFC 6455, section 5.1)
  # and sets no reserved bit.
  defp text(socket, deadline, joined) do
    with {:ok, <<fin::1, 0::3, opcode::4, 0::1, len::7>>} <- recv(socket, 2, deadline),
         {:ok, size} <- size(socket, len, deadline),
         :ok <- check(opcode, fin, size, joined),
         {:ok, payload} <- payload(socket, size, deadline) do
      case {opcode, fin} do
        {8, _} -> {:error, closed(payload)}
        {control, _} when control in [9, 10] -> text(socket, deadline, joined)
        {_text, 1} -> {:ok, (joined || "") <> payload}
        {_text, 0} -> text(socket, deadline, (joined || "") <> payload)
      end
    else
      {:ok, _bad_header} -> {:error, :broken}
      error -> error
    end
  end

  # A control frame is whole and at most 125 bytes; a text starts with
  # opcode 1, and its fragments go on with opcode 0. `Helyx.TUI.Wire.Reader`
  # checks each frame after the handshake with it too.
  @doc false
  def check(opcode, 1, size, _joined) when opcode in [8, 9, 10] and size <= 125, do: :ok
  def check(1, _fin, size, nil), do: within(size, "")
  def check(0, _fin, size, joined) when is_binary(joined), do: within(size, joined)
  def check(_opcode, _fin, _size, _joined), do: {:error, :broken}

  defp within(size, joined) do
    if byte_size(joined) + size <= Frame.max_frame(), do: :ok, else: {:error, :broken}
  end

  defp closed(<<code::16, _reason::binary>>), do: "the server closed the connection with #{code}"
  defp closed(_payload), do: "the server closed the connection"

  defp size(_socket, len, _deadline) when len < 126, do: {:ok, len}

  defp size(socket, 126, deadline) do
    with {:ok, <<size::16>>} <- recv(socket, 2, deadline), do: {:ok, size}
  end

  defp size(socket, 127, deadline) do
    with {:ok, <<size::64>>} <- recv(socket, 8, deadline), do: {:ok, size}
  end

  defp payload(_socket, 0, _deadline), do: {:ok, ""}
  defp payload(socket, size, deadline), do: recv(socket, size, deadline)

  # The deadline is checked before each read, so bytes that wait in the
  # socket do not keep the handshake past it. A read that gives fewer bytes
  # than it asked for ends at a close of the server.
  defp recv(socket, size, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      wait when wait > 0 ->
        case :gen_tcp.recv(socket, size, wait) do
          {:ok, data} when size > 0 and byte_size(data) != size -> {:error, :closed}
          result -> result
        end

      _past ->
        {:error, :timeout}
    end
  end

  defp send_frame(socket, frame), do: send_frame(socket, 1, JSON.encode!(frame))

  # A whole frame of the client with `opcode`, masked (RFC 6455, section
  # 5.3): a text, or the pong of `Helyx.TUI.Wire.Connection`.
  @doc false
  def send_frame(socket, opcode, payload) do
    size = byte_size(payload)
    mask = :crypto.strong_rand_bytes(4)
    masked = :crypto.exor(payload, binary_part(:binary.copy(mask, div(size, 4) + 1), 0, size))
    :gen_tcp.send(socket, [<<1::1, 0::3, opcode::4>>, payload_length(size), mask, masked])
  end

  defp payload_length(size) when size < 126, do: <<1::1, size::7>>
  defp payload_length(size) when size < 65_536, do: <<1::1, 126::7, size::16>>
  defp payload_length(size), do: <<1::1, 127::7, size::64>>

  defp error_text(:timeout, timeout), do: "no welcome from the server in #{timeout} ms"
  defp error_text(:closed, _timeout), do: "the server closed the connection"
  defp error_text(reason, _timeout), do: to_string(:inet.format_error(reason))
end
