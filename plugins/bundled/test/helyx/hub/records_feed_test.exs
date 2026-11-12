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

  test "a restart of Hub syncs the open asks from the session", context do
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

    # The start `sync/1` asks the session, whose Sync holds the open ask.
    Events.wait_until(fn ->
      Live.status(:sys.get_state(hub), session.id) == "waiting"
    end)

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
    assert_marker(owner)
    assert_marker(bob)
  end

  test "a start of another user is silent with no subscriber, and the first reply after it skips it",
       context do
    context = serve(context)
    {ann_id, _token, ann} = user(context, "ann")

    # A start of ann is in flight: its place, and the Live of the session,
    # while no records subscription exists.
    :ok = Hub.call(context.hub, {:start, %{user: ann_id, token: nil}, byte_size(File.cwd!())})
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    Events.wait_until(fn -> MapSet.member?(:sys.get_state(context.hub).silent, session.id) end)

    {records, _more} = subscribe(open(context.port))
    refute Enum.any?(records, &(&1["session"] == session.id))
    :gen_tcp.close(ann)
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
    assert_marker(owner)
    assert_marker(bob)
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

  # A Hub whose mailbox passed the bound lost notices: a session that it did
  # not know, and the states of the sessions that it knows. The counter of the
  # feed is above the count that the Hub read, so the next poll calls `sync/1`
  # once, and every open session answers with its full state.
  test "a drop of the feed is repaired at the next poll", context do
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
    counter = :sys.get_state(hub).feed

    # The Hub is suspended, and its mailbox fills: the notices of the next
    # session, which it does not know, are dropped and counted.
    :ok = :sys.suspend(hub)
    for _ <- 1..Helyx.Sessions.max_feed_queue(), do: send(hub, :filler)
    {:ok, unknown} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    Events.wait_until(fn -> Helyx.Sessions.dropped(counter) > 0 end)
    refute Live.running?(:sys.get_state(hub), unknown.id)
    :ok = :sys.resume(hub)

    send(hub, :wake_poll)

    Events.wait_until(fn ->
      state = :sys.get_state(hub)
      Live.running?(state, unknown.id) and Live.status(state, session.id) == "waiting"
    end)

    {records, _more} = subscribe(open(context.port))
    assert %{"status" => "waiting"} = Enum.find(records, &(&1["session"] == session.id))
    assert Enum.any?(records, &(&1["session"] == unknown.id))
  end

  test "a Sync replaces an ask set whose :ask_end was dropped", context do
    context = serve(context)

    model = "q_#{System.unique_integer([:positive])}"
    call = %Helyx.Message.ToolCall{id: "q1", name: "question", arguments: question_args()}
    :ok = Fake.script(context.core, model, [[call], ["Done."]])

    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/#{model}")
    {:ok, _snapshot, _ref} = Session.subscribe(session, answers: true)
    :ok = Session.prompt(session, "go")
    [ask] = of_type(collect_until(:ask), :ask)

    Events.wait_until(fn ->
      ask_open?(:sys.get_state(context.hub), session.id, ask.data.ask_id)
    end)

    hub = context.hub
    :ok = :sys.suspend(hub)
    for _ <- 1..Helyx.Sessions.max_feed_queue(), do: send(hub, :filler)

    # The answer ends the ask, and the Hub loses its `:ask_end`.
    :ok = Session.answer(session, ask.data.ask_id, %{"answers" => [%{"selected" => ["a"]}]})
    _ = collect_until(:turn_end)
    :ok = :sys.resume(hub)

    # The stale set is still there, and the Sync at the next poll replaces it.
    assert Live.status(:sys.get_state(hub), session.id) == "waiting"

    send(hub, :wake_poll)

    Events.wait_until(fn -> Live.status(:sys.get_state(hub), session.id) != "waiting" end)
    state = :sys.get_state(hub)
    refute ask_open?(state, session.id, ask.data.ask_id)
    assert Live.running?(state, session.id)
  end

  test "a session that the Hub did not know ends with the ask set of its Sync", context do
    context = serve(context)

    model = "q_#{System.unique_integer([:positive])}"
    call = %Helyx.Message.ToolCall{id: "q1", name: "question", arguments: question_args()}
    :ok = Fake.script(context.core, model, [[call], ["Done."]])

    # The Hub is suspended and full, so the whole life of the ask passes
    # without a notice that it keeps.
    hub = context.hub
    :ok = :sys.suspend(hub)
    for _ <- 1..Helyx.Sessions.max_feed_queue(), do: send(hub, :filler)

    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/#{model}")
    {:ok, _snapshot, _ref} = Session.subscribe(session, answers: true)
    :ok = Session.prompt(session, "go")
    [ask] = of_type(collect_until(:ask), :ask)
    :ok = Session.answer(session, ask.data.ask_id, %{"answers" => [%{"selected" => ["a"]}]})
    _ = collect_until(:turn_end)
    :ok = :sys.resume(hub)

    refute Live.running?(:sys.get_state(hub), session.id)

    send(hub, :wake_poll)

    Events.wait_until(fn -> Live.running?(:sys.get_state(hub), session.id) end)
    state = :sys.get_state(hub)
    assert Live.status(state, session.id) != "waiting"
    refute ask_open?(state, session.id, ask.data.ask_id)

    {records, _more} = subscribe(open(context.port))
    assert %{"status" => status} = Enum.find(records, &(&1["session"] == session.id))
    assert status != "waiting"
  end

  test "a records_end that races an unsubscribe answers the unsubscribe", context do
    context = serve(context)
    owner = open(context.port)
    {[], false} = subscribe(owner)

    records_pid =
      :sys.get_state(context.hub).records |> Map.values() |> hd() |> Map.fetch!(:pid)

    {:links, [conn]} = Process.info(records_pid, :links)

    on_exit(fn ->
      try do
        :erlang.resume_process(records_pid)
      catch
        _, _ -> :ok
      end
    end)

    # The record process holds the unsubscribe in its mailbox: the connection
    # took the req and the writer owes its id.
    :erlang.suspend_process(records_pid)
    Client.send_request(owner, "u", "records.unsubscribe", %{})

    Events.wait_until(fn ->
      {:messages, messages} = Process.info(records_pid, :messages)
      {:unsubscribe, "u"} in messages
    end)

    send(conn, {:records_ended, records_pid})
    Client.send_request(owner, "m", "sessions.live", %{})

    assert %{"type" => "res", "id" => "u", "ok" => true} = Client.res(owner, "u")
    assert %{"type" => "res", "id" => "m"} = Client.res(owner, "m")
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

  # The next frame of the connection is the reply of a marker request: a
  # frame of another user's record before it fails the test.
  defp assert_marker(socket) do
    Client.send_request(socket, "marker", "sessions.live", %{})
    assert {:frame, %{"type" => "res", "id" => "marker"}} = Client.recv(socket)
  end

  defp next_full(socket) do
    case next_change(socket) do
      %{"records" => _records} = full -> full
      _change -> next_full(socket)
    end
  end

  defp question_setup(context) do
    model = "q_#{System.unique_integer([:positive])}"
    call = %Helyx.Message.ToolCall{id: "q1", name: "question", arguments: question_args()}
    :ok = Fake.script(context.core, model, [[call], ["Done."]])
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/#{model}")
    {:ok, _snapshot, _ref} = Session.subscribe(session, answers: true)
    session
  end

  defp ask_open?(state, session_id, ask_id),
    do: MapSet.member?(Map.get(state.asks, session_id, MapSet.new()), ask_id)

  defp live_pid(hub, id) do
    Enum.find_value(:sys.get_state(hub).live, fn {_ref, {session_id, pid, _status}} ->
      if session_id == id, do: pid
    end)
  end

  # A child that the agent tool starts sends no `started` call, so the Hub
  # cannot tell it from a start of another user in flight: its row is silent.
  defp silent_child(context) do
    {:ok, child} =
      Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")

    Events.wait_until(fn -> MapSet.member?(:sys.get_state(context.hub).silent, child.id) end)
    child
  end

  defp place(context, ann_id),
    do: Hub.call(context.hub, {:start, %{user: ann_id, token: nil}, byte_size(File.cwd!())})

  test "a Hub that starts while a session waits on an ask shows it waiting", context do
    context =
      serve(context, [], fn context ->
        question = question_setup(context)
        :ok = Session.prompt(question, "go")
        [ask] = of_type(collect_until(:ask), :ask)
        {:ok, stuck} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
        stuck_pid = Session.pid(stuck)
        :erlang.suspend_process(stuck_pid)
        send(self(), {:asks, question.id, ask.data.ask_id, stuck.id, stuck_pid})
      end)

    assert_received {:asks, question_id, ask_id, stuck_id, stuck_pid}

    on_exit(fn ->
      try do
        :erlang.resume_process(stuck_pid)
      catch
        _, _ -> :ok
      end
    end)

    # The start of the Hub returned even though one session did not handle
    # messages, and its `sync/1` brought the open ask of the other one.
    Events.wait_until(fn ->
      state = :sys.get_state(context.hub)

      Live.status(state, question_id) == "waiting" and
        ask_open?(state, question_id, ask_id)
    end)

    assert {:ok, _users} = Hub.users(context.hub)

    # The sync message waited in the suspended session, which answers at the
    # resume.
    true = :erlang.resume_process(stuck_pid)
    Events.wait_until(fn -> Live.running?(:sys.get_state(context.hub), stuck_id) end)
  end

  test "a Sync of a dead old process does not replace the new one", context do
    context = serve(context)
    owner = open(context.port)
    %{"result" => %{"session" => id}} = start(owner)
    old_pid = Helyx.Session.pid(%Helyx.Session{id: id, core: context.core})

    %{"ok" => true} = req(owner, "stop", %{"session" => id})
    %{"result" => %{"session" => ^id}} = req(owner, "resume", %{"id" => id})
    new_pid = Helyx.Session.pid(%Helyx.Session{id: id, core: context.core})
    assert new_pid != old_pid
    Events.wait_until(fn -> live_pid(context.hub, id) == new_pid end)

    # The Sync of the old process arrives after the resume. Its pid is not the
    # pid of the sessions Registry, so the Hub skips it.
    old = %Helyx.Sessions.Sync{
      live: %Helyx.Sessions.Live{
        id: id,
        instance_id: "old",
        cwd: File.cwd!(),
        model: "fake/echo",
        status: :running,
        parent: nil
      },
      asks: []
    }

    send(context.hub, {:helyx_feed, old_pid, old})

    assert live_pid(context.hub, id) == new_pid
    assert {:ok, owner_id} = Hub.actor(context.hub, id)
    assert owner_id == :sys.get_state(context.hub).default_owner_id
    assert Live.status(:sys.get_state(context.hub), id) != "stopped"
  end

  test "a child of a start in flight reaches the default owner's feed when it ends", context do
    context = serve(context)
    {ann_id, _token, ann} = user(context, "ann")
    feed = open(context.port)
    {[], false} = subscribe(feed)

    assert :ok = place(context, ann_id)
    child = silent_child(context)

    {records, _more} = subscribe(open(context.port))
    refute Enum.any?(records, &(&1["session"] == child.id))

    # The release ends the last start that could own the row: the mark goes,
    # and the row reaches the feed of its owner, the default owner.
    assert :ok = Hub.call(context.hub, :release)

    assert %{"record" => %{"session" => child_id}} = wait_record(feed, child.id)
    assert child_id == child.id
    assert :sys.get_state(context.hub).silent == MapSet.new()
    :gen_tcp.close(ann)
  end

  test "the started call of a place clears the marks", context do
    context = serve(context)
    {ann_id, _token, ann} = user(context, "ann")
    feed = open(context.port)
    {[], false} = subscribe(feed)

    assert :ok = place(context, ann_id)
    child = silent_child(context)

    start = %{
      session_id: "s_started",
      cwd: File.cwd!(),
      model: "fake/echo",
      thread_of: nil
    }

    assert :ok = Hub.call(context.hub, {:started, %{user: ann_id, token: nil}, start, nil})

    assert %{"record" => %{"session" => child_id}} = wait_record(feed, child.id)
    assert child_id == child.id
    assert :sys.get_state(context.hub).silent == MapSet.new()
    :gen_tcp.close(ann)
  end

  test "the :DOWN of the starter of a place clears the marks", context do
    context = serve(context)
    {ann_id, _token, ann} = user(context, "ann")
    feed = open(context.port)
    {[], false} = subscribe(feed)
    parent = self()

    starter =
      spawn_link(fn ->
        :ok = place(context, ann_id)
        send(parent, :placed)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :placed
    child = silent_child(context)

    send(starter, :die)

    assert %{"record" => %{"session" => child_id}} = wait_record(feed, child.id)
    assert child_id == child.id
    assert :sys.get_state(context.hub).silent == MapSet.new()
    :gen_tcp.close(ann)
  end

  test "the expiry of a place clears the marks", context do
    context = serve(context)
    {ann_id, _token, ann} = user(context, "ann")
    feed = open(context.port)
    {[], false} = subscribe(feed)

    assert :ok = place(context, ann_id)
    child = silent_child(context)
    monitor = :sys.get_state(context.hub).reserved |> Map.fetch!(self()) |> Map.fetch!(:monitor)

    send(context.hub, {:place_expired, self(), monitor})

    assert %{"record" => %{"session" => child_id}} = wait_record(feed, child.id)
    assert child_id == child.id
    assert :sys.get_state(context.hub).silent == MapSet.new()
    :gen_tcp.close(ann)
  end
end
