defmodule Helyx.Transport.WebSocketFixturesTest do
  # The client frames of the conformance fixtures against the server
  # (`test/fixtures/wire/README.md`): each case on its own connection to a
  # server with no live and no saved session.
  use ExUnit.Case, async: true

  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Test.WireFixtures
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake], sessions_dir: dir})

    open = start_supervised!({WebSocket, core: core, port: 0}, id: :open)
    token = start_supervised!({WebSocket, core: core, port: 0, token: "secret"}, id: :token)
    %{ports: %{nil => WebSocket.port(open), "secret" => WebSocket.port(token)}}
  end

  test "every client frame case gets its frames and its close", %{ports: ports} do
    for fixture <- WireFixtures.load("client_frames.json")["cases"] do
      %{"name" => name, "phase" => phase, "send" => send, "expect" => expect} =
        WireFixtures.keys!(fixture, ~w(name phase send expect), ~w(token))

      assert phase in ~w(hello open), name
      assert expect != %{} and WireFixtures.keys!(expect, [], ~w(frames close)), name

      token = fixture["token"]
      {:ok, socket} = Client.upgrade(ports[token])
      nonce = Client.challenge(socket)

      if phase == "open" do
        Client.send_frame(socket, Client.hello(nonce, token))
        assert {:frame, %{"type" => "welcome"}} = Client.recv(socket), name
      end

      for item <- send, do: :ok = Client.send_text(socket, text(item, nonce, token))

      for frame <- Map.get(expect, "frames", []) do
        received = next(socket)
        assert {:frame, actual} = received, "#{name}: #{inspect(received)}"
        assert WireFixtures.matches?(frame, actual), "#{name}: #{inspect(actual)}"
      end

      case expect do
        # The close comes next: a frame before it fails the case.
        %{"close" => code} ->
          assert {:close, ^code} = next(socket), name

        # The connection stays open: the reply of the next request comes
        # next, with no frame and no close before it.
        _open ->
          Client.send_request(socket, "next", "sessions.live", %{})
          assert {:frame, %{"type" => "res", "id" => "next", "ok" => true}} = next(socket), name
      end

      :gen_tcp.close(socket)
    end
  end

  # Open in the doc (`docs/features/wire-protocol.md`, "Conformance
  # fixtures"), so not a fixture: the id of a resume is not checked as a
  # session id at the wire.
  test "a resume of an id that is not 12 URL-safe characters gets start_failed", %{ports: ports} do
    socket = Client.open(ports[nil])

    for id <- ["missing", "AAAAAAAAAAA!"] do
      assert %{"ok" => false, "error" => %{"code" => "start_failed"}} =
               Client.request(socket, id, "resume", %{"id" => id})
    end
  end

  # A string is a text as it is; an object is encoded, with the proof of
  # the challenge in place of "$proof".
  defp text(item, _nonce, _token) when is_binary(item), do: item

  defp text(%{"proof" => "$proof"} = item, nonce, token),
    do: JSON.encode!(%{item | "proof" => Client.proof(nonce, token)})

  defp text(item, _nonce, _token), do: JSON.encode!(item)

  defp next(socket) do
    case Client.recv(socket) do
      {:ping, _payload} -> next(socket)
      other -> other
    end
  end
end
