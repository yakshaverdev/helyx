defmodule Helyx.Hub.FeedTest do
  # The row that a Hub writes at each start and status change of a session of
  # its Core, and the scan as the repair path (`docs/features/hub.md`,
  # decisions 7, 8, and 14; `docs/features/session-feed.md`).
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Hub.Live
  alias Helyx.Provider.Fake
  alias Helyx.Test.Events
  alias Helyx.Test.Idle
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  @server_token "the server token"

  defp serve(
         %{tmp_dir: dir} = context,
         opts \\ [],
         before \\ fn _context -> :ok end,
         core_opts \\ []
       ) do
    core = :"core_#{System.unique_integer([:positive])}"
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)

    start_supervised!(
      {Helyx.Core,
       [name: core, plugins: [Fake, Helyx.Test.Tool.Block], sessions_dir: data] ++ core_opts},
      id: :core
    )

    context = Map.merge(context, %{core: core, data: data})
    before.(context)

    hub_opts =
      [
        core: core,
        default_owner: "owner",
        path: Path.join(dir, "hub.db"),
        server_token: fn -> @server_token end
      ] ++ opts

    hub = start_supervised!(Supervisor.child_spec({Hub, hub_opts}, id: :hub))
    transport = start_supervised!({WebSocket, core: core, port: 0, authority: Hub.authority(hub)})
    Map.merge(context, %{hub: hub, port: WebSocket.port(transport)})
  end

  defp open(port, token \\ nil) do
    {:ok, socket} = Client.upgrade(port)
    nonce = Client.challenge(socket)

    hello =
      case token do
        nil -> Client.hello(nonce, @server_token)
        _ -> Map.put(Client.hello(nonce, token), "token", hd(String.split(token, ".")))
      end

    Client.send_frame(socket, hello)
    {:frame, %{"type" => "welcome"}} = Client.recv(socket)
    socket
  end

  defp user(context, name) do
    {:ok, %{id: id}} = Hub.add_user(context.hub, name)
    {:ok, token} = Hub.create_token(context.hub, id, "laptop")
    {id, open(context.port, token)}
  end

  defp req(socket, op, params), do: Client.request(socket, "r", op, params)

  defp start(socket, model \\ "fake/echo"),
    do: req(socket, "start", %{"cwd" => File.cwd!(), "model" => model})

  # Polls the search of the user until it lists the row of `id`.
  defp wait_listed(socket, id) do
    Events.wait_until(fn ->
      %{"result" => %{"items" => items}} = req(socket, "hub.records.search", %{"limit" => 256})
      Enum.any?(items, &(&1["session"] == id))
    end)
  end

  test "a session that starts with the Core API while Hub runs gets a row of the default owner",
       context do
    context = serve(context)
    owner = open(context.port)
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")

    wait_listed(owner, session.id)

    assert %{
             "result" => %{
               "record" => %{"owner" => %{"name" => "owner"}, "status" => "idle"}
             }
           } = req(owner, "hub.records.get", %{"session" => session.id})
  end

  test "a session that ran before Hub started gets its row at the seed", context do
    context =
      serve(context, [], fn context ->
        {:ok, session} =
          Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")

        send(self(), {:session, session.id})
      end)

    assert_received {:session, id}
    owner = open(context.port)
    wait_listed(owner, id)
  end

  test "a session file with no row is listed by sessions.saved and then has a row", context do
    context =
      serve(context, [], fn context ->
        {:ok, session} =
          Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")

        :ok = Helyx.Session.prompt(session, "hi")
        :ok = Helyx.Sessions.stop(session)
        send(self(), {:session, session.id})
      end)

    assert_received {:session, id}
    owner = open(context.port)

    assert %{"result" => %{"items" => items}} =
             req(owner, "sessions.saved", %{"limit" => 256})

    # The scan wrote the row: the item holds the head of the file and the
    # time of its last change.
    assert %{"prompt" => "hi", "cwd" => cwd} = Enum.find(items, &(&1["id"] == id))
    assert cwd == File.cwd!()

    assert %{"title" => ""} =
             records(owner)
             |> Enum.find(&(&1["session"] == id))
  end

  defp records(socket) do
    %{"result" => %{"items" => records}} = req(socket, "hub.records.search", %{"limit" => 256})
    records
  end

  test "a start of another user ends with that user as owner, at each of 20 starts", context do
    context = serve(context)
    {ann_id, ann} = user(context, "ann")

    # The feed row of the default owner and the row of the start race, and
    # either may come first.
    for _ <- 1..20 do
      %{"result" => %{"session" => id}} = start(ann)

      assert %{"result" => %{"record" => %{"owner" => %{"id" => ^ann_id}}}} =
               req(ann, "hub.records.get", %{"session" => id})
    end
  end

  test "a session that starts outside Hub counts for the default owner at the cap", context do
    context = serve(context, max_live_sessions: 1)
    owner = open(context.port)
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")

    # The row and the entry of the live set come in one notice.
    wait_listed(owner, session.id)

    assert %{"error" => %{"code" => "too_many_sessions"}} = start(owner)
  end

  # A session that stops for idleness leaves the live set at its `:DOWN`; its
  # row stays, and a prompt loads it again (docs/features/idle-unload.md).
  test "a session that stops for idleness keeps its row and leaves the live set", context do
    context = serve(context, [], fn _context -> :ok end, idle_stop_ms: Idle.idle_ms())
    owner = open(context.port)

    %{"result" => %{"session" => id}} = start(owner)
    Events.wait_until(fn -> not Live.running?(:sys.get_state(context.hub), id) end)
    wait_listed(owner, id)

    assert %{"result" => %{"record" => %{"status" => "stopped"}}} =
             req(owner, "hub.records.get", %{"session" => id})

    # The prompt loads the session and binds the starter of the owner; the
    # bind is visible before the loaded turn can end and stop the session.
    assert %{"ok" => true} = req(owner, "prompt", %{"session" => id, "text" => "again"})

    {:ok, users} = Helyx.Hub.users(context.hub)
    owner_id = Enum.find(users, &(&1.name == "owner")).id
    assert Helyx.Hub.actor(context.hub, id) == {:ok, owner_id}
  end

  # A text op under a Hub loads a stopped session as the wire `resume` does:
  # the place of the user's live sessions and the starter
  # (docs/features/idle-unload.md). The loaded turn is held by a blocked call,
  # so the live checks do not race the idle stop.
  test "a prompt to a stopped session takes the place of the user and binds the starter",
       context do
    # The test stops the session itself: with the idle stop of the tests, a
    # loaded session could stop again before the prompt under load.
    context = serve(context, max_live_sessions: 1)

    holder = :"block_#{System.unique_integer([:positive])}"
    Process.register(self(), holder)
    :ok = Fake.script(context.core, "block", [[block_call(holder)]])

    owner = open(context.port)
    %{"result" => %{"session" => id}} = start(owner, "fake/block")
    :ok = Helyx.Sessions.stop(%Helyx.Session{id: id, core: context.core})
    Events.wait_until(fn -> not Live.running?(:sys.get_state(context.hub), id) end)

    assert %{"ok" => true} = req(owner, "prompt", %{"session" => id, "text" => "again"})
    assert_receive {:blocked, ^id}
    assert Live.running?(:sys.get_state(context.hub), id)

    # The load took the place of the user, so a start at the cap is refused.
    assert %{"error" => %{"code" => "too_many_sessions"}} = start(owner)

    {:ok, users} = Helyx.Hub.users(context.hub)
    owner_id = Enum.find(users, &(&1.name == "owner")).id
    assert Helyx.Hub.actor(context.hub, id) == {:ok, owner_id}
  end

  # A text op under a Hub that meets the idle stop: the authority's load is
  # called by the sender of `Helyx.Send`, and it must be the shape of one
  # session (docs/features/idle-unload.md).
  test "a prompt that meets the idle stop under a Hub loads it and sends again", context do
    context = serve(context)
    holder = :"block_#{System.unique_integer([:positive])}"
    Process.register(self(), holder)

    :ok =
      Fake.script(context.core, "block", [
        [
          %Helyx.Message.ToolCall{
            id: "b1",
            name: "block",
            arguments: %{"to" => Atom.to_string(holder)}
          }
        ]
      ])

    owner = open(context.port)
    %{"result" => %{"session" => id}} = start(owner, "fake/block")
    session = %Helyx.Session{id: id, core: context.core}
    Helyx.Test.Idle.arm_timer(session)
    pid = Helyx.Session.pid(session)
    ref = Process.monitor(pid)
    :sys.suspend(pid)
    # The timer message is in the mailbox before the prompt goes.
    Events.wait_until(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 1} end)

    request = Task.async(fn -> req(owner, "prompt", %{"session" => id, "text" => "again"}) end)
    Events.wait_until(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 2} end)
    :sys.resume(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :idle}}
    assert %{"ok" => true} = Task.await(request)
    assert_receive {:blocked, ^id}
  end

  # A session that stopped before its Hub started has a file and no row; a
  # text op finds it by its file, as the wire `resume` does
  # (docs/features/idle-unload.md). Until a `sessions.saved` scan, no row
  # exists: the feed writes a row for a live session only.
  test "a text op to a stopped session with a file and no row loads it", context do
    context =
      serve(
        context,
        [max_live_sessions: 1],
        fn context ->
          {:ok, session} =
            Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")

          :ok = Helyx.Session.prompt(session, "hi")
          :ok = Helyx.Sessions.stop(session)
          send(self(), {:session, session.id})
        end
      )

    assert_received {:session, id}
    owner = open(context.port)

    # No `sessions.saved` ran, so no row exists, and the record is derived
    # from the default owner when the file fact confirms it.
    assert %{"ok" => true} = req(owner, "prompt", %{"session" => id, "text" => "again"})

    {:ok, users} = Helyx.Hub.users(context.hub)
    owner_id = Enum.find(users, &(&1.name == "owner")).id
    assert Helyx.Hub.actor(context.hub, id) == {:ok, owner_id}
  end

  defp block_call(holder) do
    %Helyx.Message.ToolCall{id: "b1", name: "block", arguments: %{"to" => Atom.to_string(holder)}}
  end

  # The tests arm no poll timer (`test_helper.exs`), so the poll of this test
  # is the only one after the start of Hub.
  test "a notice that the feed dropped is repaired at the next poll", context do
    context = serve(context)
    owner = open(context.port)
    hub = context.hub
    %{feed: counter} = :sys.get_state(hub)

    # The Hub takes no message, so its mailbox is at the bound of the feed
    # when the session starts, and the notice of the start is dropped.
    :ok = :sys.suspend(hub)
    for _ <- 1..Helyx.Sessions.max_feed_queue(), do: send(hub, :filler)
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")

    # The counter of the watch, which the session owns, counts the drop. The
    # Hub stays suspended until the drop, so the notice meets its full mailbox
    # however the session process is scheduled (#958).
    Events.wait_until(fn -> Helyx.Sessions.dropped(counter) > 0 end)
    :ok = :sys.resume(hub)
    refute Live.running?(:sys.get_state(hub), session.id)

    # The poll reads the live sessions again, as the start of Hub does.
    send(hub, :wake_poll)
    Events.wait_until(fn -> Live.running?(:sys.get_state(hub), session.id) end)
    wait_listed(owner, session.id)
  end
end
