defmodule Helyx.TUI.WireFixturesTest do
  # The server frames and the folds of the conformance fixtures against the
  # client of the TUI (`test/fixtures/wire/README.md`).
  use ExUnit.Case, async: true

  import Helyx.Test.WireClient,
    only: [fake_server: 1, fake_upgrade: 1, fake_challenge: 1, server_frame: 3, client_frame: 1]

  alias Helyx.{Event, Message}
  alias Helyx.Session.Snapshot
  alias Helyx.Test.{Events, WireFixtures}
  alias Helyx.Transport.WebSocket
  alias Helyx.TUI.{ViewModel, Wire}
  alias Helyx.TUI.Wire.Connection

  @loopback {127, 0, 0, 1}

  setup_all do
    %{frames: WireFixtures.load("server_frames.json")}
  end

  defp text(frame), do: server_frame(1, 1, JSON.encode!(frame))

  test "each handshake gets its result", %{frames: frames} do
    for handshake <- frames["handshake"] do
      %{"name" => name, "frames" => [first | rest], "expect" => expect} =
        WireFixtures.keys!(handshake, ~w(name frames expect), [])

      port =
        fake_server(fn socket ->
          fake_upgrade(socket)
          :ok = :gen_tcp.send(socket, text(first))
          # The hello, or the close of a client that refused the first frame.
          _hello_or_closed = :gen_tcp.recv(socket, 0, Events.wait_ms())
          _sent_or_closed = :gen_tcp.send(socket, Enum.map(rest, &text/1))
          Process.sleep(:infinity)
        end)

      result = Wire.connect(@loopback, port, fn -> "token" end, Events.wait_ms())

      case expect do
        "welcome" -> assert {:ok, _socket} = result, name
        "broken" -> assert {:error, :broken} = result, name
        %{"refused" => protocol} -> assert {:error, {:refused, ^protocol}} = result, name
      end
    end
  end

  # A fake server that passes the handshake, reads one request, and sends
  # `frames`, each `res` with the id of that request; a connection of the
  # test to it.
  defp served(frames) do
    port =
      fake_server(fn socket ->
        fake_upgrade(socket)
        fake_challenge(socket)
        _hello = client_frame(socket)
        :ok = :gen_tcp.send(socket, text(%{type: "welcome", protocol: WebSocket.protocol()}))
        %{"id" => id} = client_frame(socket)
        :ok = :gen_tcp.send(socket, Enum.map(frames, &text(with_id(&1, id))))
        Process.sleep(:infinity)
      end)

    {:ok, socket} = Wire.connect(@loopback, port, fn -> "token" end, Events.wait_ms())
    Connection.open(socket)
  end

  defp with_id(%{"type" => "res"} = res, id), do: %{res | "id" => id}
  defp with_id(frame, _id), do: frame

  # The request of `op` that the client of the TUI sends.
  defp request(conn, "subscribe", %{"result" => %{"replay" => _}}),
    do: Connection.subscribe(conn, "s1", after: %{instance_id: "i1", seq: 4})

  defp request(conn, "subscribe", _res), do: Connection.subscribe(conn, "s1")
  defp request(conn, "start", _res), do: Connection.start(conn, cwd: "/", model: "fake/echo")
  defp request(conn, "resume", _res), do: Connection.resume(conn, id: "AAAAAAAAAAAA")
  defp request(conn, "sessions.saved", _res), do: Connection.list_saved(conn)
  defp request(conn, "steer", _res), do: Connection.steer(conn, "s1", "hi")

  defp assert_broken(conn, ref, name) do
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, :broken}}, Events.wait_ms(), name
  end

  test "each reply is taken or is a contract break", %{frames: frames} do
    for res <- frames["res"] do
      %{"name" => name, "op" => op, "frame" => frame, "expect" => expect} =
        WireFixtures.keys!(res, ~w(name op frame expect), [])

      {:ok, conn, ref} = served([frame])
      result = request(conn, op, frame)

      case expect do
        "valid" ->
          refute result == {:error, :closed}, name
          assert Process.alive?(conn), name

        "broken" ->
          assert result == {:error, :closed}, name
          assert_broken(conn, ref, name)
      end

      Process.exit(conn, :kill)
    end
  end

  # The subscribe reply of each event and session_end case: the first valid
  # snapshot of the fixtures, whose sub is "0".
  defp snapshot_res(frames) do
    Enum.find(
      frames["res"],
      &match?(%{"expect" => "valid", "frame" => %{"result" => %{"snapshot" => _}}}, &1)
    )["frame"]
  end

  test "each event is taken, ignored, or a contract break", %{frames: frames} do
    for event <- frames["event"] do
      %{"name" => name, "frame" => frame, "expect" => expect} =
        WireFixtures.keys!(event, ~w(name frame expect), [])

      ended = %{"type" => "session_end", "sub" => "0", "reason" => "stopped"}
      {:ok, conn, ref} = served([snapshot_res(frames), frame, ended])
      assert {:ok, %Snapshot{}, "0"} = Connection.subscribe(conn, "s1"), name

      case expect do
        "valid" ->
          assert_receive {:helyx_event, %Event{}}, Events.wait_ms(), name
          assert_receive {:helyx_end, "0", :stopped}, Events.wait_ms(), name

        # The session_end after it shows that the connection took it.
        "ignored" ->
          assert_receive {:helyx_end, "0", :stopped}, Events.wait_ms(), name
          refute_received {:helyx_event, _event}, name

        "broken" ->
          assert_broken(conn, ref, name)
          refute_received {:helyx_event, _event}, name
      end

      Process.exit(conn, :kill)
    end
  end

  test "each session_end ends its subscription or is a contract break", %{frames: frames} do
    for session_end <- frames["session_end"] do
      %{"name" => name, "frame" => frame, "expect" => expect} =
        WireFixtures.keys!(session_end, ~w(name frame expect), [])

      {:ok, conn, ref} = served([snapshot_res(frames), frame])
      assert {:ok, %Snapshot{}, sub} = Connection.subscribe(conn, "s1"), name

      case expect do
        "valid" ->
          reason = String.to_existing_atom(frame["reason"])
          assert_receive {:helyx_end, ^sub, ^reason}, Events.wait_ms(), name

        "broken" ->
          assert_broken(conn, ref, name)
      end

      Process.exit(conn, :kill)
    end
  end

  test "each fold leaves the state of its expect steps" do
    for fold <- WireFixtures.load("folds.json")["cases"] do
      %{"name" => name, "steps" => steps} = WireFixtures.keys!(fold, ~w(name steps), [])
      state = run_fold(name, steps, %{results: %{}, vm: nil, instance: nil, conn: nil, ref: nil})
      if state.conn, do: Process.exit(state.conn, :kill)
    end
  end

  # Each connection of a fold serves the steps up to its close, or to the
  # end: a close step ends the connection, and the next step opens another.
  defp run_fold(_name, [], state), do: state

  defp run_fold(name, steps, %{conn: nil} = state) do
    {segment, rest} = Enum.split_while(steps, &(not Map.has_key?(&1, "close")))
    {:ok, conn, ref} = fake_fold(segment ++ Enum.take(rest, 1))
    run_fold(name, steps, %{state | conn: conn, ref: ref})
  end

  defp run_fold(name, [step | rest], state) do
    assert map_size(step) == 1, name
    run_fold(name, rest, fold_step(name, step, state))
  end

  # A fake server that reads each request of the steps and gives it to the
  # test, sends each server frame, a reply with the id of its request, and
  # closes at a close step.
  defp fake_fold(steps) do
    test = self()

    port =
      fake_server(fn socket ->
        fake_upgrade(socket)
        fake_challenge(socket)
        _hello = client_frame(socket)
        :ok = :gen_tcp.send(socket, text(%{type: "welcome", protocol: WebSocket.protocol()}))
        _ids = Enum.reduce(steps, %{}, &fake_step({socket, test}, &1, &2))
        Process.sleep(:infinity)
      end)

    {:ok, socket} = Wire.connect(@loopback, port, fn -> "token" end, Events.wait_ms())
    Connection.open(socket)
  end

  defp fake_step({socket, test}, %{"client" => %{"id" => id}}, ids) do
    frame = client_frame(socket)
    send(test, {:client_frame, frame})
    Map.put(ids, id, frame["id"])
  end

  defp fake_step({socket, _test}, %{"server" => frame}, ids) do
    frame =
      if frame["type"] == "res", do: %{frame | "id" => Map.fetch!(ids, frame["id"])}, else: frame

    :ok = :gen_tcp.send(socket, text(frame))
    ids
  end

  defp fake_step({socket, _test}, %{"close" => nil}, ids) do
    :ok = :gen_tcp.close(socket)
    ids
  end

  defp fake_step({socket, _test}, %{"close" => code}, ids) do
    :ok = :gen_tcp.send(socket, server_frame(1, 8, <<code::16>>))
    ids
  end

  defp fake_step(_peer, %{"expect" => _}, ids), do: ids

  # A subscribe with after names the instance and the seq of the last event
  # that the client applied. The call returns at its reply, which the
  # reply step applies.
  defp fold_step(
         name,
         %{"client" => %{"id" => id, "op" => "subscribe", "params" => params} = client},
         state
       ) do
    opts =
      case params["after"] do
        nil ->
          []

        after_ ->
          assert after_ == %{"instance_id" => state.instance, "seq" => state.vm.seq}, name
          [after: %{instance_id: after_["instance_id"], seq: after_["seq"]}]
      end

    result = Connection.subscribe(state.conn, params["session"], opts)
    # A reply came: no close and no deadline of the client.
    refute result in [{:error, :closed}, {:error, :timeout}], name
    # The request on the wire is the step, its id mapped.
    assert_receive {:client_frame, frame}, Events.wait_ms(), name
    assert WireFixtures.matches?(Map.delete(client, "id"), Map.delete(frame, "id")), name
    %{state | results: Map.put(state.results, id, result)}
  end

  defp fold_step(_name, %{"server" => %{"type" => "res", "id" => id}}, state) do
    case Map.fetch!(state.results, id) do
      {:ok, %Snapshot{} = snapshot, _sub} ->
        %{state | vm: ViewModel.from_snapshot(snapshot), instance: snapshot.instance_id}

      {:ok, {:replay, events}, _sub} ->
        %{state | vm: Enum.reduce(events, state.vm, &ViewModel.apply(&2, &1))}

      {:error, _code} ->
        state
    end
  end

  defp fold_step(name, %{"server" => %{"type" => "event", "event" => %{"seq" => seq}}}, state) do
    assert_receive {:helyx_event, %Event{} = event}, Events.wait_ms(), name
    assert event.seq == seq, name
    %{state | vm: ViewModel.apply(state.vm, event)}
  end

  defp fold_step(name, %{"server" => %{"type" => "session_end", "reason" => reason}}, state) do
    reason = String.to_existing_atom(reason)
    assert_receive {:helyx_end, _sub, ^reason}, Events.wait_ms(), name
    state
  end

  defp fold_step(name, %{"close" => code}, %{conn: conn, ref: ref} = state) do
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, {:closed, ^code}}},
                   Events.wait_ms(),
                   name

    %{state | conn: nil, ref: nil}
  end

  defp fold_step(name, %{"expect" => expect}, state) do
    actual = %{
      "instance_id" => state.instance,
      "seq" => state.vm.seq,
      "model" => state.vm.model,
      "running" => state.vm.running?,
      "queue" => Map.new(state.vm.queue, fn {key, count} -> {Atom.to_string(key), count} end),
      "messages" => state.vm |> ViewModel.cells() |> Enum.flat_map(&ids/1),
      "asks" => Enum.map(state.vm.asks, & &1.ask_id)
    }

    assert WireFixtures.matches?(expect, actual), "#{name}: #{inspect(actual)}"
    state
  end

  # The messages of the transcript: a message cell, and the result of a
  # tool cell.
  defp ids(%Message{id: id}), do: [id]
  defp ids({:tool, _call, _line, %Message{id: id}}), do: [id]
  defp ids(_cell), do: []
end
