defmodule Helyx.Hub.SchedulesTest do
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Provider.Fake
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  @server_token "the server token"
  # A session id with no session and no file.
  @missing "AAAAAAAAAAAA"
  @max_prompt 16_384
  @max_ahead 31_622_400

  setup %{tmp_dir: dir} do
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake], sessions_dir: data}, id: :core)
    hub_opts = [core: core, default_owner: "owner", server_token: fn -> @server_token end]
    hub = start_supervised!(Supervisor.child_spec({Hub, hub_opts}, id: :hub))
    transport = start_supervised!({WebSocket, core: core, port: 0, authority: Hub.authority(hub)})
    %{hub: hub, core: core, port: WebSocket.port(transport)}
  end

  defp open(port, token) do
    {:ok, socket} = Client.upgrade(port)
    nonce = Client.challenge(socket)
    hello = Map.put(Client.hello(nonce, token), "token", hd(String.split(token, ".")))
    Client.send_frame(socket, hello)
    {:frame, %{"type" => "welcome"}} = Client.recv(socket)
    socket
  end

  defp user(context, name) do
    {:ok, %{id: id}} = Hub.add_user(context.hub, name)
    {:ok, token} = Hub.create_token(context.hub, id, "laptop")
    {id, open(context.port, token)}
  end

  defp start(socket) do
    start = %{"cwd" => File.cwd!(), "model" => "fake/echo"}
    %{"result" => %{"session" => id}} = Client.request(socket, "s", "start", start)
    id
  end

  defp req(socket, op, params), do: Client.request(socket, "r", op, params)

  defp now, do: System.os_time(:second)

  defp create(socket, session, fields \\ %{}) do
    params = Map.merge(%{"session" => session, "at" => now() + 600, "prompt" => "hi"}, fields)
    req(socket, "hub.schedules.create", params)
  end

  defp code(%{"error" => %{"code" => code}}), do: code

  test "create, list, and delete a schedule", context do
    {_ann, ann} = user(context, "ann")
    session = start(ann)
    at = now() + 600

    assert %{"result" => %{"schedule" => schedule}} =
             create(ann, session, %{"at" => at, "every" => 3_600, "prompt" => "report"})

    assert %{
             "session" => ^session,
             "at" => ^at,
             "every" => 3_600,
             "prompt" => "report",
             "pending" => true,
             "last_at" => nil,
             "last_outcome" => nil,
             "id" => id
           } = schedule

    # The delivery id of the pending wake-up is not shown.
    assert map_size(schedule) == 8

    assert %{"result" => %{"schedules" => [^schedule]}} = req(ann, "hub.schedules.list", %{})

    assert %{"result" => %{"schedules" => [^schedule]}} =
             req(ann, "hub.schedules.list", %{"session" => session})

    assert %{"result" => %{}} = req(ann, "hub.schedules.delete", %{"schedule" => id})
    assert %{"result" => %{"schedules" => []}} = req(ann, "hub.schedules.list", %{})
    assert code(req(ann, "hub.schedules.delete", %{"schedule" => id})) == "unknown_schedule"
  end

  test "the bounds of the params, at, one under, and one over", context do
    {_ann, ann} = user(context, "ann")
    session = start(ann)
    ok = &assert(%{"ok" => true} = create(ann, session, &1))
    bad = &assert(code(create(ann, session, &1)) == "bad_params", inspect(&1))

    # `at` from now to now + 366 days. The clock moves on between the request
    # and the check, so the time just past the top has a margin of 5 s.
    ok.(%{"at" => now() + @max_ahead})
    bad.(%{"at" => now() + @max_ahead + 5})
    bad.(%{"at" => now() - 1})
    bad.(%{"at" => "soon"})

    ok.(%{"every" => 300})
    ok.(%{"every" => 2_678_400})
    bad.(%{"every" => 299})
    bad.(%{"every" => 2_678_401})
    bad.(%{"every" => nil})
    bad.(%{"every" => "daily"})

    # The prompt: 1 to 16,384 bytes, a multibyte character at the edge.
    ok.(%{"prompt" => String.duplicate("p", @max_prompt)})
    ok.(%{"prompt" => String.duplicate("p", @max_prompt - 2) <> "é"})
    bad.(%{"prompt" => ""})
    bad.(%{"prompt" => 7})

    for prompt <- [
          String.duplicate("p", @max_prompt + 1),
          String.duplicate("p", @max_prompt - 1) <> "é"
        ] do
      assert code(create(ann, session, %{"prompt" => prompt})) == "text_too_large"
    end

    bad.(%{"extra" => 1})

    assert code(req(ann, "hub.schedules.create", %{"session" => session, "prompt" => "x"})) ==
             "bad_params"

    assert code(req(ann, "hub.schedules.list", %{"session" => 1})) == "bad_params"
    assert code(req(ann, "hub.schedules.list", %{"other" => "x"})) == "bad_params"
    assert code(req(ann, "hub.schedules.delete", %{})) == "bad_params"
  end

  test "16 schedules of a session", context do
    {_ann, ann} = user(context, "ann")
    session = start(ann)
    for _ <- 1..16, do: %{"ok" => true} = create(ann, session)
    assert code(create(ann, session)) == "too_many_schedules"
    # Another session has room.
    assert %{"ok" => true} = create(ann, start(ann))
  end

  test "a session of another user: refused as a missing one, forbidden when shared", context do
    {_ann, ann} = user(context, "ann")
    {_bob, bob} = user(context, "bob")
    private = start(ann)
    shared = start(ann)

    %{"ok" => true} =
      req(ann, "hub.records.update", %{"session" => shared, "visibility" => "hub"})

    stopped = start(ann)
    %{"ok" => true} = req(ann, "stop", %{"session" => stopped})

    for session <- [private, stopped] do
      assert create(bob, session)["error"] == create(bob, @missing)["error"]
      assert code(create(bob, session)) == "session_not_found"

      assert req(bob, "hub.schedules.list", %{"session" => session})["error"] ==
               req(bob, "hub.schedules.list", %{"session" => @missing})["error"]
    end

    # The same bad params for an object of another user and a missing one.
    assert code(create(bob, private, %{"every" => 1})) == "bad_params"
    assert code(create(bob, @missing, %{"every" => 1})) == "bad_params"

    assert code(create(bob, shared)) == "forbidden"

    assert %{"result" => %{"schedules" => []}} =
             req(bob, "hub.schedules.list", %{"session" => shared})

    # A stopped session of the user takes a schedule.
    assert %{"ok" => true} = create(ann, stopped)

    %{"result" => %{"schedule" => %{"id" => id}}} = create(ann, private)
    assert code(req(bob, "hub.schedules.delete", %{"schedule" => id})) == "unknown_schedule"
    assert %{"result" => %{"schedules" => []}} = req(bob, "hub.schedules.list", %{})
    assert %{"result" => %{"schedules" => [_, _]}} = req(ann, "hub.schedules.list", %{})
  end

  test "Hub.schedule/3: the rules of hub.schedules.create for a user", context do
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    {:ok, [%{id: owner}]} = Hub.users(context.hub)
    params = %{"session" => session.id, "at" => now() + 60, "prompt" => "hi"}

    session_id = session.id

    # A session with no record belongs to the default owner (decision 8).
    assert {:ok, %{session: ^session_id, pending: true, every: nil, prompt: "hi"}} =
             Hub.schedule(context.hub, owner, params)

    {:ok, %{id: ann}} = Hub.add_user(context.hub, "ann")
    assert Hub.schedule(context.hub, ann, params) == {:error, :session_not_found}
    assert Hub.schedule(context.hub, "nobody", params) == {:error, :unknown_user}
    assert Hub.schedule(context.hub, owner, %{params | "at" => 0}) == {:error, :bad_params}

    assert Hub.schedule(context.hub, owner, %{params | "prompt" => <<0xFF>>}) ==
             {:error, :bad_params}

    big = String.duplicate("p", @max_prompt + 1)

    assert Hub.schedule(context.hub, owner, %{params | "prompt" => big}) ==
             {:error, :text_too_large}
  end
end
