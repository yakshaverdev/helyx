defmodule Helyx.Hub.LiveTest do
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Hub.Live
  alias Helyx.Hub.Store.SQLite
  alias Helyx.Provider.Fake
  alias Helyx.Test.Events
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  @server_token "the server token"

  defp serve(%{tmp_dir: dir}, cap, before \\ fn _core -> :ok end) do
    core = :"core_#{System.unique_integer([:positive])}"
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)
    start_supervised!({Helyx.Core, name: core, plugins: [Fake], sessions_dir: data}, id: :core)
    before.(core)

    opts = [
      core: core,
      default_owner: "owner",
      path: Path.join(dir, "hub.db"),
      server_token: fn -> @server_token end,
      max_live_sessions: cap
    ]

    hub = start_supervised!(Supervisor.child_spec({Hub, opts}, id: :hub))
    transport = start_supervised!({WebSocket, core: core, port: 0, authority: Hub.authority(hub)})
    # The Hub handled its start read, so no message of it comes later.
    Events.wait_until(fn -> :sys.get_state(hub).live_read == nil end)
    %{hub: hub, port: WebSocket.port(transport), core: core, tmp_dir: dir}
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
    open(context.port, token)
  end

  defp req(socket, id \\ "r", op, params), do: Client.request(socket, id, op, params)

  defp start(socket, model \\ "fake/echo"),
    do: req(socket, "start", %{"cwd" => File.cwd!(), "model" => model})

  test "the cap of live sessions of a user; a resume of a running session needs no place",
       context do
    context = serve(context, 2)
    ann = user(context, "ann")
    bob = user(context, "bob")
    %{"result" => %{"session" => first}} = start(ann)
    %{"result" => %{"session" => _second}} = start(ann)

    assert %{"error" => %{"code" => "too_many_sessions"}} = start(ann)
    # The sessions of another user do not count.
    assert %{"ok" => true} = start(bob)
    # A resume of a running session attaches.
    assert %{"result" => %{"session" => ^first}} = req(ann, "resume", %{"id" => first})

    # The end of a session frees its place.
    %{"ok" => true} = req(ann, "stop", %{"session" => first})
    # The `:DOWN` of the session reaches the Hub after the stop answered.
    Events.wait_until(fn -> not Live.running?(:sys.get_state(context.hub), first) end)
    assert %{"ok" => true} = start(ann)
  end

  test "two starts at the last place: one gets it", context do
    context = serve(context, 1)
    ann = user(context, "ann")
    # The Hub handled its start, so no message of it comes later.
    :sys.get_state(context.hub)
    :erlang.suspend_process(context.hub)

    for id <- ~w(a b),
        do: Client.send_request(ann, id, "start", %{"cwd" => File.cwd!(), "model" => "fake/echo"})

    Events.wait_until(fn ->
      Process.info(context.hub, :message_queue_len) == {:message_queue_len, 2}
    end)

    :erlang.resume_process(context.hub)

    answers = replies(ann, MapSet.new(~w(a b)), [])
    assert Enum.count(answers, & &1["ok"]) == 1
    assert Enum.count(answers, &(&1["error"]["code"] == "too_many_sessions")) == 1
  end

  test "a resume refused at the cap moves nothing; a folder resume attaches to a running session and is refused for a stopped one",
       context do
    context = serve(context, 1)
    owner = open(context.port)
    %{"result" => %{"session" => first}} = start(owner)
    %{"ok" => true} = req(owner, "hub.records.update", %{"session" => first, "title" => "t"})
    %{"ok" => true} = req(owner, "stop", %{"session" => first})
    Events.wait_until(fn -> not Live.running?(:sys.get_state(context.hub), first) end)
    %{"result" => %{"session" => second}} = start(owner)
    # An old time on the row, so a touch would show: written on the
    # connection inside the handle of the store, while the Hub waits for its
    # next call.
    %{db: %{db: db}} = :sys.get_state(context.hub)

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "UPDATE records SET active_at = 1 WHERE session_id = '#{first}'"
      )

    assert %{"error" => %{"code" => "too_many_sessions"}} = req(owner, "resume", %{"id" => first})
    assert stored_active_at(owner, first) == 1

    # The resume of its folder takes the newest record, the running `second`
    # session that the feed wrote, and attaches to it: no place, no touch.
    assert %{"result" => %{"session" => ^second}} = req(owner, "resume", %{"cwd" => File.cwd!()})
    assert stored_active_at(owner, first) == 1

    # A folder resume refused at the cap moves nothing: the newest record of
    # the folder is a stopped session, and another session holds the place.
    # `serve({:newest, ...})` takes the place before the touch.
    %{"ok" => true} = req(owner, "stop", %{"session" => second})
    Events.wait_until(fn -> not Live.running?(:sys.get_state(context.hub), second) end)
    %{"result" => %{"session" => third}} = start(owner)

    # The stopped `second` stays the newest record of the folder.
    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "UPDATE records SET active_at = 9999999999 WHERE session_id = '#{second}'"
      )

    assert %{"error" => %{"code" => "too_many_sessions"}} =
             req(owner, "resume", %{"cwd" => File.cwd!()})

    assert stored_active_at(owner, second) == 9_999_999_999
    assert Live.running?(:sys.get_state(context.hub), third)
    refute Live.running?(:sys.get_state(context.hub), second)

    # A session that runs outside the live set, the newest of its folder.
    folder = Path.join(context.tmp_dir, "elsewhere") |> tap(&File.mkdir_p!/1)
    {:ok, other} = Helyx.Sessions.start(context.core, cwd: folder, model: "fake/echo")
    :ok = Helyx.Session.prompt(other, "hi")

    Events.wait_until(fn ->
      Path.wildcard(Path.join([context.tmp_dir, "data", "*", other.id <> ".jsonl"])) != []
    end)

    other_id = other.id
    assert %{"result" => %{"session" => ^other_id}} = req(owner, "resume", %{"cwd" => folder})
  end

  defp stored_active_at(socket, id) do
    %{"result" => %{"items" => items}} = req(socket, "sessions.saved", %{"limit" => 256})

    Enum.find_value(items, &(&1["id"] == id && &1["mtime"]))
  end

  test "a start whose Core call fails gives its place back", context do
    context = serve(context, 1)
    ann = user(context, "ann")
    assert %{"ok" => false} = start(ann, "nope/none")
    assert %{"ok" => true} = start(ann)
  end

  test "the sessions of the Core at the start of Hub count for the default owner", context do
    context =
      serve(context, 1, fn core ->
        {:ok, _session} = Helyx.Sessions.start(core, cwd: File.cwd!(), model: "fake/echo")
      end)

    owner = open(context.port)
    assert %{"error" => %{"code" => "too_many_sessions"}} = start(owner)
    ann = user(context, "ann")
    assert %{"ok" => true} = start(ann)
  end

  # A Hub state on a store in memory, with a cap of one live session.
  defp state(_context) do
    {:ok, db} = SQLite.open(path: nil)
    :ok = SQLite.add_user(db, %{id: "owner", name: "owner", created_at: 1}, 64, :infinity)
    on_exit(fn -> SQLite.close(db) end)
    %{state: Live.init(%{store: SQLite, db: db, default_owner_id: "owner", max_live: 1})}
  end

  describe "an entry of the live set" do
    setup :state

    test "of a new process of a session replaces the entry of the old one, and a Live of the same pid keeps the starter",
         %{state: state} do
      old = spawn_link(fn -> Process.sleep(:infinity) end)
      new = spawn_link(fn -> Process.sleep(:infinity) end)

      state =
        state
        |> Live.watch("s1", old, "idle")
        |> Live.started(self(), "s1", new, "owner")

      assert Map.values(state.live) == [{"s1", new, "idle"}]
      assert Live.status(state, "s1") == "idle"
      assert Live.status(state, "other") == "stopped"
      {:monitors, monitors} = Process.info(self(), :monitors)
      assert {:process, new} in monitors
      refute {:process, old} in monitors

      # The Live of the same process keeps the starter and moves the status.
      running = Live.watch(state, "s1", new, "running")
      assert Live.starter(running, "s1") == "owner"
      assert Map.values(running.live) == [{"s1", new, "running"}]

      # A Live of another process of the id drops it.
      other = spawn_link(fn -> Process.sleep(:infinity) end)
      replaced = Live.watch(state, "s1", other, "idle")
      assert Live.starter(replaced, "s1") == nil
      assert Map.values(replaced.live) == [{"s1", other, "idle"}]
    end
  end

  describe "a place" do
    setup :state

    test "ends at the :DOWN of its caller", %{state: state} do
      caller = spawn(fn -> Process.sleep(:infinity) end)
      other = spawn_link(fn -> Process.sleep(:infinity) end)
      {:ok, state} = Live.reserve(state, "owner", caller, false)
      assert Live.reserve(state, "owner", other, false) == {:error, :too_many_sessions}
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ref, :process, ^caller, _}
      state = Live.down(state, ref, caller)
      assert {:ok, _} = Live.reserve(state, "owner", other, false)
    end

    test "ends when its timer fires, and a stale timer changes nothing", %{state: state} do
      caller = spawn_link(fn -> Process.sleep(:infinity) end)
      {:ok, state} = Live.reserve(state, "owner", caller, false)
      %{monitor: monitor} = state.reserved[caller]
      assert Live.expired(state, caller, make_ref()) == state
      state = Live.expired(state, caller, monitor)
      assert state.reserved == %{}
    end
  end

  # The replies of the ids, in any order.
  defp replies(socket, ids, acc) do
    if MapSet.size(ids) == 0 do
      acc
    else
      case Client.recv(socket) do
        {:frame, %{"type" => "res", "id" => id} = res} ->
          replies(socket, MapSet.delete(ids, id), [res | acc])

        {_tag, _frame} ->
          replies(socket, ids, acc)
      end
    end
  end
end
