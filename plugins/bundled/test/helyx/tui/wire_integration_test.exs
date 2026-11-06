defmodule Helyx.TUI.WireIntegrationTest do
  # The wire client against the real `Helyx.Transport.WebSocket` server: the
  # upgrade, a large text in parts, a ping and its pong, a close with 1000,
  # a close with 4400, and an abrupt close.
  use ExUnit.Case, async: true

  alias Helyx.Provider.Fake
  alias Helyx.Test.{Events, WireClient}
  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.Frame
  alias Helyx.TUI.Wire
  alias Helyx.TUI.Wire.{Connection, Reader}

  @loopback {127, 0, 0, 1}

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake]})
    transport = start_supervised!({WebSocket, core: core, port: 0})
    %{core: core, port: WebSocket.port(transport), transport: transport}
  end

  defp connect(port) do
    {:ok, socket, ws} = Wire.connect(@loopback, port, fn -> "token" end, Events.wait_ms())
    {socket, ws}
  end

  test "the upgrade passes and a text of the frame bound goes as parts", c do
    {socket, ws} = connect(c.port)
    assert {:ok, [active: false, packet: 0]} = :inet.getopts(socket, [:active, :packet])
    {:ok, conn, _ref} = Connection.open(socket, ws)

    assert {:ok, id} = Connection.start(conn, cwd: File.cwd!(), model: "fake/echo")
    assert {:ok, _snapshot, _sub} = Connection.subscribe(conn, id)
    text = String.duplicate("é", Frame.max_frame())
    assert :ok = Connection.steer(conn, id, text)

    assert_receive {:helyx_event, %Helyx.Event{type: :message_end, data: %{message: message}}}
    assert Helyx.Message.text(message) == text
  end

  test "a ping gets a pong from the real server", c do
    {socket, ws} = connect(c.port)
    assert {:ok, ws, bytes} = Mint.WebSocket.encode(ws, {:ping, "hello"})
    :ok = :gen_tcp.send(socket, bytes)

    frames = until(socket, ws, &Enum.any?(&1, fn frame -> frame == {:pong, "hello"} end))
    assert {:pong, "hello"} in frames
  end

  test "an app frame that the contract does not allow closes with 4400", c do
    {socket, ws} = connect(c.port)
    assert {:ok, ws, bytes} = Mint.WebSocket.encode(ws, {:text, "not json"})
    :ok = :gen_tcp.send(socket, bytes)

    assert {:close, 4400, _reason} = read(socket, ws)
  end

  test "a stop closes the connection with 1000", c do
    {socket, ws} = connect(c.port)
    {:ok, conn, ref} = Connection.open(socket, ws)

    :ok = stop_supervised!(WebSocket)
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, {:closed, 1000}}}, Events.wait_ms()
  end

  test "a killed server connection closes with no code", c do
    {socket, ws} = connect(c.port)
    {:ok, conn, ref} = Connection.open(socket, ws)

    [bandit] = for {_id, pid, :supervisor, _} <- Supervisor.which_children(c.transport), do: pid

    Events.wait_until(fn ->
      case ThousandIsland.connection_pids(bandit) do
        {:ok, [_ | _] = pids} ->
          Enum.each(pids, &Process.exit(&1, :kill))
          true

        _none ->
          false
      end
    end)

    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, {:closed, nil}}}, Events.wait_ms()
  end

  test "a client of another protocol is refused by the real server", c do
    {:ok, socket} = WireClient.upgrade(c.port)
    nonce = WireClient.challenge(socket)
    proof = WireClient.proof(nonce, "token")

    hello = %{
      "type" => "hello",
      "protocol" => WebSocket.protocol() + 1,
      "proof" => proof
    }

    :ok = WireClient.send_frame(socket, hello)

    assert {:frame, %{"type" => "refused", "code" => "protocol", "server_protocol" => server}} =
             WireClient.recv(socket)

    assert server == WebSocket.protocol()
    assert {:close, 4426} = WireClient.recv(socket)
  end

  # The frames of the server up to the first for which `done?` holds.
  defp until(socket, ws, done?, acc \\ []) do
    case Mint.WebSocket.decode(ws, next_bytes(socket)) do
      {:ok, ws, frames} ->
        frames = acc ++ frames
        if done?.(frames), do: frames, else: until(socket, ws, done?, frames)

      {:error, _ws, reason} ->
        flunk("the server broke the frames: #{inspect(reason)}")
    end
  end

  # The next close of the server, by `Helyx.TUI.Wire.Reader`.
  defp read(socket, ws) do
    case Reader.read(ws, next_bytes(socket)) do
      {:ok, messages, ws} ->
        case Enum.find(messages, &match?({:close, _code, _reason}, &1)) do
          nil -> read(socket, ws)
          close -> close
        end

      {:partial, _messages, _ws} ->
        flunk("the server broke the contract before its close")

      :broken ->
        flunk("the server broke the contract")
    end
  end

  defp next_bytes(socket) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, Events.wait_ms())
    bytes
  end
end
