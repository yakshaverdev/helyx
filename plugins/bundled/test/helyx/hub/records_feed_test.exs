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
end
