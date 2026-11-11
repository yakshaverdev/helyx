defmodule Helyx.Test.TlsClient do
  @moduledoc false
  # A WebSocket client over TLS for the tests of the public listener
  # (`docs/features/remote-hands.md`, "Pairing and the public listener"): the
  # upgrade, masked text frames, and the frames of the server. It accepts
  # only a certificate with the pin that `connect/3` gets, as a peer does.

  alias Helyx.Test.Events
  alias Helyx.Test.WireClient

  def connect(port, pin, timeout \\ 5_000) do
    {:ok, _apps} = Application.ensure_all_started(:ssl)

    verify =
      if pin do
        [
          verify: :verify_peer,
          cacerts: [],
          server_name_indication: :disable,
          verify_fun: {Helyx.Transport.WebSocket.TLS.verify_fun(), pin}
        ]
      else
        [verify: :verify_none]
      end

    :ssl.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line] ++ verify, timeout)
  end

  def upgrade(port, pin, headers \\ []) do
    with {:ok, socket} <- connect(port, pin) do
      :ok = :ssl.send(socket, WireClient.upgrade_request(headers))

      {:ok, "HTTP/1.1 " <> <<status::binary-size(3), _::binary>>} = read(socket, 0)
      :ok = skip_head(socket)
      :ok = :ssl.setopts(socket, packet: :raw)

      if status == "101", do: {:ok, socket}, else: {:http, String.to_integer(status)}
    end
  end

  # A client that got the challenge and sent `hello`, then read the answer.
  def open(port, pin, hello) do
    {:ok, socket} = upgrade(port, pin)
    nonce = challenge(socket)
    send_frame(socket, hello.(nonce))
    {socket, recv(socket)}
  end

  defp skip_head(socket) do
    case read(socket, 0) do
      {:ok, "\r\n"} -> :ok
      {:ok, _header} -> skip_head(socket)
    end
  end

  def challenge(socket) do
    {:frame, %{"type" => "challenge", "nonce" => nonce}} = recv(socket)
    nonce
  end

  def send_frame(socket, frame),
    do: :ssl.send(socket, WireClient.masked_frame(1, 1, JSON.encode!(frame)))

  def send_text(socket, text), do: :ssl.send(socket, WireClient.masked_frame(1, 1, text))

  def request(socket, id, op, params) do
    send_frame(socket, %{"type" => "req", "id" => id, "op" => op, "params" => params})
    res(socket, id)
  end

  def res(socket, id) do
    case recv(socket) do
      {:frame, %{"type" => "res", "id" => ^id} = res} -> res
      {:ping, _payload} -> res(socket, id)
      {:frame, _other} -> res(socket, id)
      other -> other
    end
  end

  def recv(socket) do
    with {:ok, <<_fin::1, _::3, opcode::4, 0::1, len::7>>} <- read(socket, 2),
         {:ok, size} <- size(socket, len),
         {:ok, payload} <- payload(socket, size) do
      case opcode do
        1 -> {:frame, JSON.decode!(payload)}
        8 -> {:close, close_code(payload)}
        9 -> {:ping, payload}
        _ -> recv(socket)
      end
    end
  end

  def until_close(socket) do
    case recv(socket) do
      {tag, _frame} when tag in [:frame, :ping] -> until_close(socket)
      other -> other
    end
  end

  defp size(_socket, len) when len < 126, do: {:ok, len}
  defp size(socket, 126), do: with({:ok, <<size::16>>} <- read(socket, 2), do: {:ok, size})
  defp size(socket, 127), do: with({:ok, <<size::64>>} <- read(socket, 8), do: {:ok, size})

  defp payload(_socket, 0), do: {:ok, ""}
  defp payload(socket, size), do: read(socket, size)

  defp read(socket, size), do: :ssl.recv(socket, size, Events.wait_ms())

  defp close_code(<<code::16, _reason::binary>>), do: code
  defp close_code(_payload), do: nil
end
