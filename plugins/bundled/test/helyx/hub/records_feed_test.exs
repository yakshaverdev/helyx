defmodule Helyx.Hub.RecordsFeedTest do
  # The records feed of a user over the wire (`docs/features/live-records.md`):
  # the first reply, each change, the waiting status, two users, the
  # unsubscribe, a revoked token, the cleanup, and the seed after a restart.
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Hub.Live
  alias Helyx.Provider.Fake
  alias Helyx.Session
  alias Helyx.Test.Events
  alias Helyx.Test.HubWake
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Tool.Question
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  @server_token "the server token"
  # A wait that must not see a frame: the margin is for load. A frame that
  # comes later only makes the check weaker, never fails it.
  @quiet_ms 500

  defp serve(%{tmp_dir: dir} = context, opts \\ [], before \\ fn _context -> :ok end) do
    core = :"core_#{System.unique_integer([:positive])}"
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)

    start_supervised!(
      {Helyx.Core, name: core, plugins: [Fake, Question], sessions_dir: data},
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
    {id, token, open(context.port, token)}
  end

  defp req(socket, op, params), do: Client.request(socket, "r", op, params)

  defp subscribe(socket) do
    %{"result" => %{"records" => records, "more" => more}} =
      req(socket, "records.subscribe", %{})

    {records, more}
  end

  # The next change of a record, or the full list of a slow subscriber.
  defp next_change(socket) do
    case Client.recv(socket) do
      {:frame, %{"type" => "record", "change" => change}} -> change
      {:frame, %{"type" => "records"} = frame} -> frame
      {:ping, _payload} -> next_change(socket)
      other -> flunk("an unexpected frame: #{inspect(other)}")
    end
  end

  # The change or full list that names `id`. The tests send a poll of Hub after
  # each change, so a coalesced change goes too.
  defp wait_record(socket, id) do
    case next_change(socket) do
      %{"record" => %{"session" => ^id}} = change ->
        change

      %{"session" => ^id} = change ->
        change

      %{"records" => records} = full ->
        if Enum.any?(records, &(&1["session"] == id)), do: full, else: wait_record(socket, id)

      _other ->
        wait_record(socket, id)
    end
  end

  defp poll(hub), do: send(hub, :wake_poll)

  defp start(socket), do: req(socket, "start", %{"cwd" => File.cwd!(), "model" => "fake/echo"})

  test "the first reply is empty, and the records are ordered by the rule", context do
    context = serve(context)
    owner = open(context.port)
    feed = open(context.port)
    assert {[], false} = subscribe(feed)

    %{"result" => %{"session" => first}} = start(owner)
    %{"result" => %{"session" => second}} = start(owner)
    poll(context.hub)

    {records, false} = subscribe(open(context.port))

    order =
      Enum.sort_by(records, fn record ->
        {record["status"] != "waiting", -record["active_at"], record["session"]}
      end)

    assert Enum.map(records, & &1["session"]) == Enum.map(order, & &1["session"])
    assert Enum.sort(Enum.map(records, & &1["session"])) == Enum.sort([first, second])

    assert %{
             "owner" => %{"name" => "owner"},
             "cwd" => cwd,
             "model" => "fake/echo",
             "status" => "idle",
             "parent" => nil
           } = Enum.find(records, &(&1["session"] == first))

    assert cwd == File.cwd!()
    :gen_tcp.close(feed)
  end

  test "a start is new, a prompt moves the record, a model change and a stop are changes",
       context do
    context = serve(context)
    owner = open(context.port)
    feed = open(context.port)
    {[], false} = subscribe(feed)

    %{"result" => %{"session" => id}} = start(owner)
    poll(context.hub)

    assert %{"kind" => kind, "record" => %{"session" => ^id, "status" => "idle"}} =
             wait_record(feed, id)

    assert kind in ["new", "changed"]

    %{"ok" => true} = req(owner, "prompt", %{"session" => id, "text" => "hello there"})
    poll(context.hub)
    changes = changes_until(feed, id, fn record -> record["prompt"] == "hello there" end)
    assert %{"record" => %{"prompt" => "hello there", "active_at" => at}} = List.last(changes)
    assert is_integer(at)

    %{"ok" => true} = req(owner, "set_model", %{"session" => id, "model" => "fake/system"})
    poll(context.hub)
    _ = changes_until(feed, id, fn record -> record["model"] == "fake/system" end)

    %{"ok" => true} = req(owner, "stop", %{"session" => id})
    poll(context.hub)
    _ = changes_until(feed, id, fn record -> record["status"] == "stopped" end)
  end

  # The changes of `id` until `done?` accepts one; a full list counts for the
  # record that it holds.
  defp changes_until(socket, id, done?) do
    case wait_record(socket, id) do
      %{"records" => records} ->
        if Enum.any?(records, &(&1["session"] == id and done?.(&1))),
          do: [%{"record" => Enum.find(records, &(&1["session"] == id))}],
          else: changes_until(socket, id, done?)

      %{"record" => record} = change ->
        if done?.(record), do: [change], else: changes_until(socket, id, done?)
    end
  end

  test "a record that a user deletes is removed", context do
    context = serve(context)
    owner = open(context.port)
    feed = open(context.port)
    {[], false} = subscribe(feed)

    %{"result" => %{"session" => id}} = start(owner)
    %{"ok" => true} = req(owner, "stop", %{"session" => id})
    poll(context.hub)
    _ = changes_until(feed, id, fn record -> record["status"] == "stopped" end)

    %{"ok" => true} = req(owner, "hub.records.delete", %{"session" => id})
    poll(context.hub)
    assert %{"kind" => "removed", "session" => ^id} = wait_record(feed, id)
  end

  test "an ask makes the record wait, first in the list, and the answer ends it", context do
    context = serve(context)
    owner = open(context.port)
    feed = open(context.port)
    {[], false} = subscribe(feed)

    model = "q_#{System.unique_integer([:positive])}"
    call = %Helyx.Message.ToolCall{id: "q1", name: "question", arguments: question_args()}
    :ok = Fake.script(context.core, model, [[call], ["Done."]])

    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/#{model}")
    {:ok, _snapshot, _ref} = Session.subscribe(session, answers: true)
    :ok = Session.prompt(session, "go")
    [ask] = of_type(collect_until(:ask), :ask)

    poll(context.hub)
    _ = changes_until(feed, session.id, fn record -> record["status"] == "waiting" end)

    # One shape: the record operations carry the waiting status too.
    assert %{"result" => %{"record" => %{"status" => "waiting"}}} =
             req(owner, "hub.records.get", %{"session" => session.id})

    # The waiting record is first, before a record with a newer activity.
    %{"result" => %{"session" => newer}} = start(owner)
    poll(context.hub)
    {records, false} = subscribe(open(context.port))
    assert hd(records)["session"] == session.id
    assert Enum.any?(records, &(&1["session"] == newer))

    :ok = Session.answer(session, ask.data.ask_id, %{"answers" => [%{"selected" => ["a"]}]})
    poll(context.hub)
    _ = changes_until(feed, session.id, fn record -> record["status"] != "waiting" end)
    _ = collect_until(:turn_end)
  end

  defp question_args do
    %{
      "questions" => [
        %{
          "question" => "Which one?",
          "header" => "Pick",
          "options" => [
            %{"label" => "a", "description" => "it"},
            %{"label" => "b", "description" => "it"}
          ]
        }
      ]
    }
  end

  defp collect_until(type) do
    receive do
      {:helyx_event, %Helyx.Event{type: ^type} = event} -> [event]
      {:helyx_event, _event} -> collect_until(type)
    after
      Events.wait_ms() -> flunk("no #{type} event")
    end
  end

  defp of_type(events, type), do: Enum.filter(events, &(&1.type == type))

  test "the records of another user never reach a client", context do
    context = serve(context)
    {adm_id, _adm_token, admin} = user(context, "ann")

    %{"result" => %{"session" => id}} = start(admin)

    assert %{"result" => %{"record" => %{"owner" => %{"id" => ^adm_id}}}} =
             req(admin, "hub.records.get", %{"session" => id})

    bob = open(context.port)
    assert {[], false} = subscribe(bob)

    # A change of the record of Ann reaches no client of Bob.
    %{"ok" => true} = req(admin, "prompt", %{"session" => id, "text" => "hello"})
    poll(context.hub)

    assert {[], false} = subscribe(open(context.port))
  end

  test "a second subscription on one connection is refused, and an unsubscribe ends it",
       context do
    context = serve(context)
    owner = open(context.port)
    assert {[], false} = subscribe(owner)

    assert %{"error" => %{"code" => "too_many_subscriptions"}} =
             req(owner, "records.subscribe", %{})

    assert %{"ok" => true, "result" => %{}} = req(owner, "records.unsubscribe", %{})

    assert %{"error" => %{"code" => "unknown_sub"}} =
             req(owner, "records.unsubscribe", %{})

    # A new subscription goes after the old one ended.
    assert {[], false} = subscribe(owner)
  end

  test "the Hub holds no subscriber after the connection closes", context do
    context = serve(context)
    owner = open(context.port)
    assert {[], false} = subscribe(owner)

    :ok = :gen_tcp.close(owner)

    Events.wait_until(fn -> :sys.get_state(context.hub).records == %{} end)
  end

  test "a revoked token ends the subscription with 4403", context do
    context = serve(context)
    {_id, token, socket} = user(context, "ann")
    assert {[], false} = subscribe(socket)

    token_id = token |> String.split(".") |> hd()
    :ok = Hub.revoke_token(context.hub, token_id)
    assert {:close, 4403} = Client.until_close(socket)
  end

  test "a restart of Hub seeds the open asks from the session", context do
    context = serve(context)
    owner = open(context.port)
    assert {[], false} = subscribe(owner)

    model = "q_#{System.unique_integer([:positive])}"
    call = %Helyx.Message.ToolCall{id: "q1", name: "question", arguments: question_args()}
    :ok = Fake.script(context.core, model, [[call], ["Done."]])

    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/#{model}")
    {:ok, _snapshot, _ref} = Session.subscribe(session, answers: true)
    :ok = Session.prompt(session, "go")
    [ask] = of_type(collect_until(:ask), :ask)
    poll(context.hub)
    _ = changes_until(owner, session.id, fn record -> record["status"] == "waiting" end)

    # The Hub and the transport stop, and the session keeps its ask.
    :gen_tcp.close(owner)
    stop_supervised!(:hub)
    stop_supervised!(WebSocket)

    hub = start_supervised!(Supervisor.child_spec({Hub, hub_opts(context)}, id: :hub))

    transport =
      start_supervised!({WebSocket, core: context.core, port: 0, authority: Hub.authority(hub)})

    again = open(WebSocket.port(transport))
    {records, false} = subscribe(again)
    assert %{"status" => "waiting"} = Enum.find(records, &(&1["session"] == session.id))

    :ok = Session.answer(session, ask.data.ask_id, %{"answers" => [%{"selected" => ["a"]}]})
    poll(hub)
    assert %{"record" => %{"status" => status}} = wait_record(again, session.id)
    assert status != "waiting"
  end

  defp hub_opts(context) do
    [
      core: context.core,
      default_owner: "owner",
      path: Path.join(context.tmp_dir, "hub.db"),
      server_token: fn -> @server_token end
    ]
  end

  test "the Hub builds no record view with no subscriber", context do
    context = serve(context)
    state = :sys.get_state(context.hub)
    assert state.records == %{}

    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    poll(context.hub)
    Events.wait_until(fn -> Live.running?(:sys.get_state(context.hub), session.id) end)
    # The live set holds the session; the record feed holds no view and no
    # pending change.
    assert :sys.get_state(context.hub).records == %{}
  end

  # A start of another user writes its row while its reserved place is in
  # flight, and the place names no session: no client of another user may be
  # told of the id, in either order of the Live and the start's result.
  test "a start of another user reaches no other user's feed", context do
    context = serve(context)
    owner = open(context.port)
    {_bob, _bob_token, bob} = user(context, "bob")
    {_ann, _ann_token, ann} = user(context, "ann")
    assert {[], false} = subscribe(owner)
    assert {[], false} = subscribe(bob)

    # Twenty starts so the race of the Live and the result is met both ways.
    for _ <- 1..20 do
      assert %{"result" => %{"session" => _id}} = start(ann)
    end

    poll(context.hub)
    quiet(owner, "the default owner")
    quiet(bob, "bob")
  end

  test "a record delete names the id only to the feed of its owner", context do
    context = serve(context)
    owner = open(context.port)
    {_ann, _ann_token, ann} = user(context, "ann")

    %{"result" => %{"session" => id}} = start(ann)
    %{"ok" => true} = req(ann, "stop", %{"session" => id})

    # The subscriptions start after the start, so the delete alone is checked.
    bob = open(context.port)
    assert {[], false} = subscribe(owner)
    assert {[], false} = subscribe(bob)

    %{"ok" => true} = req(ann, "hub.records.delete", %{"session" => id})
    poll(context.hub)
    quiet(owner, "the default owner")
    quiet(bob, "bob")
  end

  test "a get that writes a row tells the feed", context do
    context = serve(context)
    owner = open(context.port)

    %{"result" => %{"session" => id}} = start(owner)
    %{"ok" => true} = req(owner, "stop", %{"session" => id})
    %{"ok" => true} = req(owner, "hub.records.delete", %{"session" => id})

    feed = open(context.port)
    {[], false} = subscribe(feed)

    assert %{"result" => %{"record" => _}} = req(owner, "hub.records.get", %{"session" => id})
    poll(context.hub)
    assert %{"kind" => "new", "record" => %{"session" => ^id}} = wait_record(feed, id)
  end

  test "a project delete tells the feed of the records that lose it", context do
    context = serve(context)
    owner = open(context.port)

    %{"result" => %{"project" => %{"id" => project}}} =
      req(owner, "hub.projects.create", %{"name" => "work"})

    %{"result" => %{"session" => id}} = start(owner)
    %{"ok" => true} = req(owner, "hub.records.update", %{"session" => id, "project" => project})

    feed = open(context.port)
    {_records, _more} = subscribe(feed)

    %{"ok" => true} = req(owner, "hub.projects.delete", %{"project" => project})
    poll(context.hub)
    assert %{"records" => records} = next_full(feed)
    assert Enum.find(records, &(&1["session"] == id))["project"] == nil
  end

  test "a resume of a folder tells the feed of the rows that its scan wrote", context do
    context = serve(context)
    owner = open(context.port)

    %{"result" => %{"session" => a}} = start(owner)
    %{"result" => %{"session" => b}} = start(owner)
    %{"ok" => true} = req(owner, "prompt", %{"session" => a, "text" => "a"})
    %{"ok" => true} = req(owner, "prompt", %{"session" => b, "text" => "b"})
    %{"ok" => true} = req(owner, "stop", %{"session" => a})
    %{"ok" => true} = req(owner, "stop", %{"session" => b})
    %{"ok" => true} = req(owner, "hub.records.delete", %{"session" => a})
    %{"ok" => true} = req(owner, "hub.records.delete", %{"session" => b})

    feed = open(context.port)
    {[], false} = subscribe(feed)

    %{"result" => %{"session" => resumed}} = req(owner, "resume", %{"cwd" => File.cwd!()})
    poll(context.hub)

    %{"records" => records} = next_full(feed)
    assert Enum.any?(records, &(&1["session"] == resumed))

    # The scan writes the row of the other file too.
    assert Enum.any?(records, &(&1["session"] in [a, b] and &1["session"] != resumed))
  end

  test "the first reply keeps a live record beside a full page", context do
    context = serve(context)
    state = :sys.get_state(context.hub)
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    Events.wait_until(fn -> match?({:ok, _row}, state.store.record(state.db, session.id)) end)

    # A live record older than a full page of newer records.
    :ok = state.store.touch_record(state.db, session.id, 0, nil, :infinity)

    for n <- 1..300 do
      record = %{
        session_id: "r#{n}",
        owner: state.default_owner_id,
        cwd: "/tmp",
        model: "fake/echo",
        prompt: "",
        active_at: n,
        created_at: n,
        project_id: nil,
        title: "",
        visibility: "private",
        archived: false,
        parent_id: nil,
        parent_kind: nil
      }

      :ok = state.store.put_record(state.db, record, :none, :infinity)
    end

    {records, true} = subscribe(open(context.port))

    assert Enum.any?(records, &(&1["session"] == session.id))
    assert length(records) == Helyx.Hub.RecordFeed.page() + 1
  end

  test "a wake-up that the session took moves its record", context do
    context = HubWake.serve(context, server_token: fn -> @server_token end)
    feed = open(context.port)
    {[], false} = subscribe(feed)

    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    _schedule = HubWake.due(context, context.owner, session.id)

    poll(context.hub)
    _ = changes_until(feed, session.id, fn record -> record["prompt"] == "wake up" end)
  end

  test "a Hub that restarts ends the feed, and a subscribe on the connection works", context do
    context = serve_named(context)
    owner = open(context.port)
    {[], false} = subscribe(owner)

    stop_supervised!(:hub)
    assert {:frame, %{"type" => "records_end"}} = Client.recv(owner)

    _hub =
      start_supervised!(Supervisor.child_spec({Hub, hub_opts(context) ++ [name: :hub]}, id: :hub))

    assert {[], false} = subscribe(owner)
  end

  @tag :slow
  test "a seed that fails keeps the asks and the count, and the next poll reads again",
       context do
    context = serve(context)
    owner = open(context.port)
    {[], false} = subscribe(owner)

    model = "q_#{System.unique_integer([:positive])}"
    call = %Helyx.Message.ToolCall{id: "q1", name: "question", arguments: question_args()}
    :ok = Fake.script(context.core, model, [[call], ["Done."]])

    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/#{model}")
    {:ok, _snapshot, _ref} = Session.subscribe(session, answers: true)
    :ok = Session.prompt(session, "go")
    _ask = of_type(collect_until(:ask), :ask)
    poll(context.hub)
    _ = changes_until(owner, session.id, fn record -> record["status"] == "waiting" end)

    hub = context.hub

    # A notice of the feed is dropped, so the next poll reads the live sessions.
    counter = :sys.get_state(hub).feed
    :ok = :sys.suspend(hub)
    for _ <- 1..Helyx.Sessions.max_feed_queue(), do: send(hub, :filler)
    {:ok, _other} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")

    # The feed drops the notice while the Hub is suspended; the counter is
    # evidence of the drop, and the Hub process is not needed to read it.
    Events.wait_until(fn -> Helyx.Sessions.dropped(counter) > 0 end)
    :ok = :sys.resume(hub)

    # The session of the ask does not answer the snapshot, so the read fails.
    session_pid = Session.pid(session)
    :ok = :sys.suspend(session_pid)
    send(hub, :wake_poll)
    state = :sys.get_state(hub, 15_000)

    assert state.feed_dropped == 0
    assert Map.has_key?(state.asks, session.id)

    :ok = :sys.resume(session_pid)
    send(hub, :wake_poll)
    state = :sys.get_state(hub, 15_000)

    assert state.feed_dropped > 0

    {records, _more} = subscribe(open(context.port))
    assert %{"status" => "waiting"} = Enum.find(records, &(&1["session"] == session.id))
  end

  # A server whose Hub has a registered name, so its authority finds the new
  # Hub after a restart (hub.md, decision 5).
  defp serve_named(%{tmp_dir: dir} = context) do
    core = :"core_#{System.unique_integer([:positive])}"
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)

    start_supervised!(
      {Helyx.Core, name: core, plugins: [Fake, Question], sessions_dir: data},
      id: :core
    )

    context = Map.merge(context, %{core: core, data: data})

    _hub =
      start_supervised!(Supervisor.child_spec({Hub, hub_opts(context) ++ [name: :hub]}, id: :hub))

    transport =
      start_supervised!({WebSocket, core: core, port: 0, authority: Hub.authority(:hub)})

    Map.merge(context, %{port: WebSocket.port(transport)})
  end

  # No frame in a margin: the frames are those of the feed alone, so any bytes
  # are a change that another user must not see.
  defp quiet(socket, name) do
    case :gen_tcp.recv(socket, 0, @quiet_ms) do
      {:error, :timeout} -> :ok
      other -> flunk("#{name}: an unexpected frame: #{inspect(other)}")
    end
  end

  defp next_full(socket) do
    case next_change(socket) do
      %{"records" => _records} = full -> full
      _change -> next_full(socket)
    end
  end
end
