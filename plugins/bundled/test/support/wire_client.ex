defmodule Helyx.Test.WireClient do
  @moduledoc false
  # A WebSocket client on :gen_tcp for the wire tests: the upgrade, masked
  # text frames, and the frames of the server. It talks only to a server on
  # loopback.

  def upgrade(port, headers \\ []) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    :ok = :gen_tcp.send(socket, upgrade_request(headers))

    {:ok, "HTTP/1.1 " <> <<status::binary-size(3), _::binary>>} = :gen_tcp.recv(socket, 0, 5_000)
    :ok = skip_head(socket)
    :ok = :inet.setopts(socket, packet: :raw)
    if status == "101", do: {:ok, socket}, else: {:http, String.to_integer(status)}
  end

  def upgrade_request(headers, version \\ 13) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    [
      "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
      "Sec-WebSocket-Version: #{version}\r\nSec-WebSocket-Key: #{key}\r\n",
      Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end),
      "\r\n"
    ]
  end

  defp skip_head(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "\r\n"} -> :ok
      {:ok, _header} -> skip_head(socket)
    end
  end

  # A client that got the challenge, sent its hello with the proof of
  # `token`, and got the welcome.
  def open(port, token \\ nil) do
    {:ok, socket} = upgrade(port)
    send_frame(socket, hello(challenge(socket), token))
    {:frame, %{"type" => "welcome"}} = recv(socket)
    socket
  end

  # The nonce of the challenge, the first frame of the server, within the
  # auth wait.
  def challenge(socket) do
    {:frame, %{"type" => "challenge", "nonce" => nonce}} = recv(socket, 5_000)
    nonce
  end

  def hello(_nonce, nil),
    do: %{"type" => "hello", "protocol" => Helyx.Transport.WebSocket.protocol()}

  def hello(nonce, token), do: Map.put(hello(nonce, nil), "proof", proof(nonce, token))

  # The HMAC-SHA256 of the nonce with the key, the SHA-256 of the token.
  def proof(nonce, token) do
    key = :crypto.hash(:sha256, token)
    Base.encode64(:crypto.mac(:hmac, :sha256, key, Base.decode64!(nonce)))
  end

  def send_frame(socket, frame), do: send_text(socket, JSON.encode!(frame))

  def send_text(socket, text, opcode \\ 1), do: send_raw(socket, 1, opcode, text)

  # One text message as WebSocket fragments: a text frame, then
  # continuation frames, FIN on the last.
  def send_fragments(socket, texts) do
    last = length(texts) - 1

    for {text, n} <- Enum.with_index(texts) do
      :ok = send_raw(socket, if(n == last, do: 1, else: 0), if(n == 0, do: 1, else: 0), text)
    end
  end

  defp send_raw(socket, fin, opcode, text),
    do: :gen_tcp.send(socket, masked_frame(fin, opcode, text))

  # The bytes of one masked frame, for a test that sends many in one write.
  def text_frame(text), do: masked_frame(1, 1, text)

  # A zero mask leaves the payload as it is, so a log that holds the bytes of
  # the frame holds its text.
  def masked_frame(fin, opcode, text, mask \\ :crypto.strong_rand_bytes(4)) do
    size = byte_size(text)
    masked = :crypto.exor(text, binary_part(:binary.copy(mask, div(size, 4) + 1), 0, size))
    [<<fin::1, 0::3, opcode::4>>, payload_length(size), mask, masked]
  end

  defp payload_length(size) when size < 126, do: <<1::1, size::7>>
  defp payload_length(size) when size < 65_536, do: <<1::1, 126::7, size::16>>
  defp payload_length(size), do: <<1::1, 127::7, size::64>>

  # The next frame of the server: `{:frame, map}`, `{:close, code}`,
  # `{:ping, payload}`, or `{:error, reason}`.
  def recv(socket, timeout \\ 10_000) do
    with {:ok, <<_fin::1, _::3, opcode::4, 0::1, len::7>>} <- :gen_tcp.recv(socket, 2, timeout),
         {:ok, size} <- size(socket, len),
         {:ok, payload} <- payload(socket, size) do
      case opcode do
        1 -> {:frame, JSON.decode!(payload)}
        8 -> {:close, close_code(payload)}
        9 -> {:ping, payload}
        _ -> recv(socket, timeout)
      end
    end
  end

  # The frames and pings of the server are skipped until it closes.
  def until_close(socket) do
    case recv(socket) do
      {tag, _frame} when tag in [:frame, :ping] -> until_close(socket)
      other -> other
    end
  end

  # Each frame of the server until a `res` with `id`.
  def res(socket, id) do
    case recv(socket) do
      {:frame, %{"type" => "res", "id" => ^id} = res} -> res
      {:frame, _other} -> res(socket, id)
      other -> other
    end
  end

  def request(socket, id, op, params) do
    send_frame(socket, %{"type" => "req", "id" => id, "op" => op, "params" => params})
    res(socket, id)
  end

  defp size(_socket, len) when len < 126, do: {:ok, len}

  defp size(socket, 126) do
    with {:ok, <<size::16>>} <- :gen_tcp.recv(socket, 2), do: {:ok, size}
  end

  defp size(socket, 127) do
    with {:ok, <<size::64>>} <- :gen_tcp.recv(socket, 8), do: {:ok, size}
  end

  defp payload(_socket, 0), do: {:ok, ""}
  defp payload(socket, size), do: :gen_tcp.recv(socket, size, 10_000)

  defp close_code(<<code::16, _reason::binary>>), do: code
  defp close_code(_payload), do: nil
end
