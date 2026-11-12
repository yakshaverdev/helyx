defmodule Helyx.Hub.FeedTest do
  # The row that a Hub writes at each start and status change of a session of
  # its Core, and the scan as the repair path (`docs/features/hub.md`,
  # decisions 7, 8, and 14; `docs/features/session-feed.md`).
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Hub.Live
  alias Helyx.Provider.Fake
  alias Helyx.Test.Events
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  @server_token "the server token"

  defp serve(%{tmp_dir: dir} = context, opts \\ [], before \\ fn _context -> :ok end) do
    core = :"core_#{System.unique_integer([:positive])}"
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)
    start_supervised!({Helyx.Core, name: core, plugins: [Fake], sessions_dir: data}, id: :core)
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

  defp start(socket),
    do: req(socket, "start", %{"cwd" => File.cwd!(), "model" => "fake/echo"})

  # Polls the search of the user until it lists the row of `id`.
  defp wait_listed(socket, id) do
    Events.wait_until(fn ->
      %{"result" => %{"items" => items}} = req(socket, "hub.records.search", %{"limit" => 256})
      Enum.any?(items, &(&1["session"] == id and &1["stored"] == true))
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
               "record" => %{"stored" => true, "owner" => %{"name" => "owner"}}
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

    assert %{"title" => "", "stored" => true} =
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
    # session can send its notice after `start/2` returns, so the Hub stays
    # suspended until the drop.
    Events.wait_until(fn -> Helyx.Sessions.dropped(counter) > 0 end)
    :ok = :sys.resume(hub)
    refute Live.running?(:sys.get_state(hub), session.id)

    # The poll reads the live sessions again, as the start of Hub does.
    send(hub, :wake_poll)
    Events.wait_until(fn -> Live.running?(:sys.get_state(hub), session.id) end)
    wait_listed(owner, session.id)
  end
end
