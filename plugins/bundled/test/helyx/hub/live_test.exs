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

  test "a resume refused at the cap moves nothing; the resume of a folder of a running session attaches",
       context do
    context = serve(context, 1)
    owner = open(context.port)
    %{"result" => %{"session" => first}} = start(owner)
    %{"ok" => true} = req(owner, "hub.records.update", %{"session" => first, "title" => "t"})
    %{"ok" => true} = req(owner, "stop", %{"session" => first})
    Events.wait_until(fn -> not Live.running?(:sys.get_state(context.hub), first) end)
    %{"result" => %{"session" => _second}} = start(owner)
    # An old time on the row, so a touch would show: written on the
    # connection of the store while the Hub waits for its next call.
    %{db: db} = :sys.get_state(context.hub)

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "UPDATE records SET active_at = 1 WHERE session_id = '#{first}'"
      )

    assert %{"error" => %{"code" => "too_many_sessions"}} = req(owner, "resume", %{"id" => first})
    assert stored_active_at(owner, first) == 1

    # The resume of its folder, whose newest session it is, moves nothing either.
    assert %{"error" => %{"code" => "too_many_sessions"}} =
             req(owner, "resume", %{"cwd" => File.cwd!()})

    assert stored_active_at(owner, first) == 1

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

    test "of a new process of a session replaces the entry of the old one", %{state: state} do
      old = spawn_link(fn -> Process.sleep(:infinity) end)
      new = spawn_link(fn -> Process.sleep(:infinity) end)
      state = state |> Live.seed([{"s1", old}]) |> Live.started(self(), "s1", new)

      assert Map.values(state.live) == ["s1"]
      {:monitors, monitors} = Process.info(self(), :monitors)
      assert {:process, new} in monitors
      refute {:process, old} in monitors
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
