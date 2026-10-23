defmodule Helyx.TUI.WireTest do
  use ExUnit.Case, async: true

  import Helyx.Test.WireClient,
    only: [
      fake_accept: 1,
      fake_challenge: 1,
      fake_server: 1,
      fake_upgrade: 1,
      fake_upgrade: 2,
      fake_upgrade: 3,
      server_frame: 3,
      client_frame: 1
    ]

  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.Frame
  alias Helyx.TUI.Wire

  @token "the-token"
  @loopback {127, 0, 0, 1}
  # The deadline of a handshake that must end at its deadline: the
  # upgrade, the challenge, and the hello pass well within it on a loaded
  # machine (a deadline of 20 ms did not, in a precommit run).
  @load_ms 500

  # Every result of a test, an error too, is checked for the token.
  defp connect(port, timeout \\ 5_000) do
    result = Wire.connect(@loopback, port, fn -> @token end, timeout)
    refute inspect(result) =~ @token
    result
  end

  defp send_text(socket, frame), do: :ok = :gen_tcp.send(socket, server_frame(1, 1, frame))

  defp welcome, do: JSON.encode!(%{type: "welcome", protocol: WebSocket.protocol()})

  # A server that passes the upgrade and the challenge, reads the hello,
  # and then runs `reply` with the socket.
  defp server(reply) do
    test = self()

    fake_server(fn socket ->
      fake_upgrade(socket)
      nonce = fake_challenge(socket)
      send(test, {:hello, nonce, client_frame(socket)})
      reply.(socket)
      Process.sleep(:infinity)
    end)
  end

  test "the hello holds the protocol and the proof of the token; a welcome gives the socket" do
    port = server(&send_text(&1, welcome()))
    assert {:ok, socket} = connect(port)

    assert_receive {:hello, nonce, hello}
    proof = :crypto.mac(:hmac, :sha256, :crypto.hash(:sha256, @token), nonce)

    assert hello == %{
             "type" => "hello",
             "protocol" => WebSocket.protocol(),
             "proof" => Base.encode64(proof)
           }

    assert {:ok, [active: false, packet: 0]} = :inet.getopts(socket, [:active, :packet])
  end

  test "refused gives the protocol of the server; any other value of it is a contract break" do
    # The decode bounds of the transport: an integer of at most 1,024 characters.
    longest = String.to_integer(String.duplicate("9", 1_024))

    for {value, result} <- [
          {99, {:refused, 99}},
          {0, {:refused, 0}},
          {longest, {:refused, longest}},
          {longest * 10 + 9, :broken},
          {"99", :broken},
          {-1, :broken},
          {1.0, :broken}
        ] do
      refused = JSON.encode!(%{type: "refused", code: "protocol", server_protocol: value})
      port = server(&send_text(&1, refused))
      assert connect(port) == {:error, result}
    end
  end

  test "a frame that the handshake does not allow is a contract break" do
    frames = [
      server_frame(1, 1, "not json"),
      server_frame(1, 1, JSON.encode!(%{type: "welcome", protocol: WebSocket.protocol() + 1})),
      server_frame(1, 1, JSON.encode!(%{type: "part", n: 0, last: true, data: ""})),
      server_frame(1, 2, welcome()),
      # A masked frame, and a reserved bit.
      [<<1::1, 0::3, 1::4, 1::1, 0::7>>, <<0::32>>],
      [<<1::1, 1::3, 1::4, 0::1, 0::7>>],
      # A continuation with no start, and a ping over 125 bytes.
      server_frame(1, 0, welcome()),
      server_frame(1, 9, String.duplicate("p", 126)),
      # A fragmented ping.
      server_frame(0, 9, "p")
    ]

    for frame <- frames do
      port = server(&(:ok = :gen_tcp.send(&1, frame)))
      assert connect(port) == {:error, :broken}
    end
  end

  test "a challenge whose nonce is not the base64 of 32 bytes is a contract break" do
    for nonce <- [
          Base.encode64(:crypto.strong_rand_bytes(31)),
          Base.encode64(:crypto.strong_rand_bytes(33)),
          "%%",
          32
        ] do
      port =
        fake_server(fn socket ->
          fake_upgrade(socket)
          send_text(socket, JSON.encode!(%{type: "challenge", nonce: nonce}))
          Process.sleep(:infinity)
        end)

      assert connect(port) == {:error, :broken}
    end
  end

  # A welcome of `size` bytes, padded with "é" in a key that the client does
  # not know, and the offset of a cut inside the first "é".
  defp padded_welcome(size) do
    prefix = ~s({"type":"welcome","protocol":#{WebSocket.protocol()},"x":")
    room = size - byte_size(prefix) - 2
    fill = String.duplicate("é", div(room, 2)) <> String.duplicate("a", rem(room, 2))
    {prefix <> fill <> ~s("}), byte_size(prefix) + 1}
  end

  test "a text of the frame bound joins from fragments cut inside a character, with a ping between them" do
    max = Frame.max_frame()

    for {size, ok?} <- [{max, true}, {max + 1, false}] do
      {text, cut} = padded_welcome(size)
      assert byte_size(text) == size

      port =
        server(fn socket ->
          <<first::binary-size(cut), rest::binary>> = text
          :ok = :gen_tcp.send(socket, server_frame(0, 1, first))
          :ok = :gen_tcp.send(socket, server_frame(1, 9, "ping"))
          # The client closes at the header of a fragment over the bound,
          # so the send of its payload can fail.
          _ = :gen_tcp.send(socket, server_frame(1, 0, rest))
        end)

      result = connect(port)
      if ok?, do: assert({:ok, _} = result), else: assert(result == {:error, :broken})
    end
  end

  test "a whole text frame of the frame bound passes; one byte more is a contract break" do
    max = Frame.max_frame()

    for {size, ok?} <- [{max - 1, true}, {max, true}, {max + 1, false}] do
      {text, _cut} = padded_welcome(size)
      # The client closes at the header of a frame over the bound, so the
      # send of its payload can fail.
      port = server(&(_ = :gen_tcp.send(&1, server_frame(1, 1, text))))
      result = connect(port)
      if ok?, do: assert({:ok, _} = result), else: assert(result == {:error, :broken})
    end
  end

  test "a close, a reply that is not an upgrade, and the timeout give a text" do
    close = server(&(:ok = :gen_tcp.send(&1, server_frame(1, 8, <<4401::16>>))))
    assert connect(close) == {:error, "the server closed the connection with 4401"}

    status =
      fake_server(fn socket ->
        fake_accept(socket)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 503 Service Unavailable\r\n\r\n")
        Process.sleep(:infinity)
      end)

    assert connect(status) == {:error, "the upgrade got HTTP 503"}

    accept =
      fake_server(fn socket ->
        fake_upgrade(socket, [], "wrong")
        Process.sleep(:infinity)
      end)

    assert connect(accept) == {:error, "the reply to the upgrade is not a WebSocket upgrade"}

    silent = fake_server(fn _socket -> Process.sleep(:infinity) end)
    assert connect(silent, 100) == {:error, "no welcome from the server in 100 ms"}
  end

  test "the head of the upgrade reply has at most 64 header lines of at most 8192 bytes" do
    # The reply has three headers of its own.
    many = for n <- 1..61, do: "X-#{n}: v"
    long = "X-Long: " <> String.duplicate("a", 8_192 - 10)

    for {headers, ok?} <- [
          {many, true},
          {["X-62: v" | many], false},
          {[long], true},
          {[long <> "a"], false}
        ] do
      # The welcome waits in the socket; a client that refused the head has
      # closed it, so the sends are not checked.
      port =
        fake_server(fn socket ->
          fake_upgrade(socket, headers)
          nonce = Base.encode64(:crypto.strong_rand_bytes(32))
          challenge = JSON.encode!(%{type: "challenge", nonce: nonce})

          _ =
            :gen_tcp.send(socket, [server_frame(1, 1, challenge), server_frame(1, 1, welcome())])

          Process.sleep(:infinity)
        end)

      result = connect(port)
      assert match?({:ok, _}, result) == ok?, inspect(result)
    end
  end

  test "a ping of 125 bytes is skipped" do
    port =
      server(fn socket ->
        :ok = :gen_tcp.send(socket, server_frame(1, 9, String.duplicate("p", 125)))
        send_text(socket, welcome())
      end)

    assert {:ok, _socket} = connect(port)
  end

  # The server sends pings until the client closes: a read past the
  # deadline would take them with no end.
  test "pings that wait in the socket do not keep the handshake past its deadline" do
    port = server(&pings/1)
    assert connect(port, @load_ms) == {:error, "no welcome from the server in #{@load_ms} ms"}
  end

  defp pings(socket) do
    with :ok <- :gen_tcp.send(socket, :binary.copy(<<0x89, 0>>, 10_000)), do: pings(socket)
  end

  test "a length field cut by a close of the server gives a text" do
    for cut <- [<<0x81, 126, 1>>, <<0x81, 127, 0, 0, 0>>] do
      port =
        server(fn socket ->
          :ok = :gen_tcp.send(socket, cut)
          :gen_tcp.close(socket)
        end)

      assert connect(port) == {:error, "the server closed the connection"}
    end
  end

  test "a refused TCP connection gives its text" do
    {:ok, listen} = :gen_tcp.listen(0, ip: @loopback)
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    assert connect(port) == {:error, "connection refused"}
  end
end
