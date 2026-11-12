defmodule Helyx.Transport.WebSocket.Runner.ConnectionTest do
  use ExUnit.Case, async: true

  alias Helyx.Transport.WebSocket.Runner.Connection
  alias Helyx.Transport.WebSocket.TLS

  @moduletag :tmp_dir

  # The pause between the two parts of the reply, so that the client reads
  # the first part alone. A client that reads both at once still passes.
  @split_ms 50

  test "an upgrade reply that comes in two reads opens the connection", %{tmp_dir: dir} do
    {:ok, tls} = TLS.ensure(dir)

    {:ok, listen} =
      :ssl.listen(0,
        certfile: tls.certfile,
        keyfile: tls.keyfile,
        versions: [:"tlsv1.3"],
        mode: :binary,
        active: false,
        ip: {127, 0, 0, 1}
      )

    {:ok, {_ip, port}} = :ssl.sockname(listen)

    server =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listen)
        {:ok, socket} = :ssl.handshake(socket)
        request = read_request(socket, "")
        [_all, key] = Regex.run(~r/sec-websocket-key: (\S+)/i, request)
        accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

        :ok = :ssl.send(socket, "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\n")
        Process.sleep(@split_ms)
        :ok = :ssl.send(socket, "connection: upgrade\r\nsec-websocket-accept: #{accept}\r\n\r\n")
        # The socket stays open until the client has its answer.
        _ = :ssl.recv(socket, 0)
      end)

    assert {:ok, state} = Connection.open("127.0.0.1", port, tls.pin, 5_000)
    :ssl.close(state.socket)
    Task.await(server)
  end

  defp read_request(socket, acc) do
    if String.ends_with?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, more} = :ssl.recv(socket, 0)
      read_request(socket, acc <> more)
    end
  end
end
