defmodule Helyx.Hub.RefusalTest do
  # The mechanical check of the rule that an access check answers an object
  # that the caller may not reach exactly as a missing one
  # (docs/agents/review-checklist.md, "Boundaries"; docs/features/hub.md,
  # "Access tests"). Every op of the wire schema is in one class below, so
  # a new op fails here until it has its refusal case. Each op that names an
  # object runs with an object of another user and with a missing id, for
  # the default owner and for a user who is not, with valid params, with
  # the params that Core checks before its lookup, and with bad params; the
  # two answers are equal, code and text.
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Provider.Fake
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  @doc_path Path.expand("../../../../../docs/features/wire-protocol.md", __DIR__)
  @server_token "the server token"
  # An id with no session, no file, no project, and no token.
  @missing "AAAAAAAAAAAA"

  # The ops whose params name no object of a user: a list, a create, the
  # user itself, or a sub of the connection. `sessions.saved` and `resume`
  # of a folder filter by access: `saved_test.exs` checks them.
  @no_object ~w(sessions.live sessions.saved start unsubscribe hub.me hub.projects.list
                hub.projects.create hub.tokens.list
                pair.create pair.revoke pair.list
                records.subscribe records.unsubscribe)
  @session_ops ~w(subscribe history prompt steer follow_up abort set_model compact answer stop
                  hub.records.get hub.records.update hub.records.delete
                  hub.schedules.create hub.schedules.list
                  hub.subscriptions.create hub.subscriptions.list)
  @project_ops ~w(hub.projects.update hub.projects.delete hub.records.update hub.records.search)
  @token_ops ~w(hub.tokens.revoke)
  @schedule_ops ~w(hub.schedules.delete)
  @subscription_ops ~w(hub.subscriptions.delete)

  # A frame of the client is at most 1 MiB; a larger request goes as parts.
  @max_frame 1_000_000

  setup %{tmp_dir: dir} do
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake], sessions_dir: data}, id: :core)
    hub_opts = [core: core, default_owner: "owner", server_token: fn -> @server_token end]
    hub = start_supervised!(Supervisor.child_spec({Hub, hub_opts}, id: :hub))
    transport = start_supervised!({WebSocket, core: core, port: 0, authority: Hub.authority(hub)})
    %{hub: hub, port: WebSocket.port(transport)}
  end

  test "every op of the schema has its class" do
    [_, rest] = String.split(File.read!(@doc_path), "<!-- wire-schema:start -->\n")
    [_, ops] = String.split(rest, "\nop = ")
    [ops | _] = String.split(ops, "\n\n")
    schema = for [_, op] <- Regex.scan(~r/"([a-z_.]+)"/, ops), into: MapSet.new(), do: op

    classes =
      @no_object ++
        @session_ops ++
        @project_ops ++ @token_ops ++ @schedule_ops ++ @subscription_ops ++ ["resume"]

    assert MapSet.new(classes) == schema
  end

  test "the cases cover each op of its class" do
    ops = &MapSet.new(&1, fn {op, _params} -> op end)
    assert ops.(session_cases()) == MapSet.new(["resume" | @session_ops])
    assert ops.(project_cases("s")) == MapSet.new(@project_ops)
    assert ops.(token_cases()) == MapSet.new(@token_ops)
    assert ops.(schedule_cases()) == MapSet.new(@schedule_ops)
    assert ops.(subscription_cases()) == MapSet.new(@subscription_ops)
  end

  test "an object of another user answers as a missing one, for every op that names one",
       context do
    {_ann, ann} = user(context, "ann")
    owner = open(context.port)
    {_bob, bob} = user(context, "bob")

    # Private sessions of ann, running and stopped, and of the default
    # owner, with no row.
    ann_sessions = [start(ann), stopped(ann)]
    owner_sessions = [start(owner), stopped(owner)]
    project = project(ann)
    {:ok, token} = Hub.create_token(context.hub, user_id(context, "ann"), "phone")
    token_id = hd(String.split(token, "."))
    schedule = schedule(ann, hd(ann_sessions))
    subscription = subscription(ann, hd(ann_sessions))

    for {socket, refused} <- [{owner, ann_sessions}, {bob, ann_sessions ++ owner_sessions}] do
      own = start(socket)

      for id <- refused, {op, params} <- session_cases() do
        key = if op == "resume", do: "id", else: "session"
        same(socket, op, Map.put(params, key, id), Map.put(params, key, @missing))
      end

      for {op, params} <- project_cases(own) do
        same(
          socket,
          op,
          Map.put(params, "project", project),
          Map.put(params, "project", @missing)
        )
      end

      for {op, params} <- token_cases() do
        same(socket, op, Map.put(params, "token", token_id), Map.put(params, "token", @missing))
      end

      for {op, params} <- schedule_cases() do
        refused = Map.put(params, "schedule", schedule)
        same(socket, op, refused, Map.put(params, "schedule", @missing))
      end

      for {op, params} <- subscription_cases() do
        refused = Map.put(params, "subscription", subscription)
        same(socket, op, refused, Map.put(params, "subscription", @missing))
      end
    end
  end

  # The cases of an op on a session: valid params, the params that Core
  # checks before its lookup, and bad params.
  defp session_cases do
    over = String.duplicate("a", Helyx.Session.max_text_bytes() + 1)
    big_answer = %{"a" => String.duplicate("b", Helyx.Session.max_answer_bytes())}
    origin = &%{"kind" => "product", "id" => &1}

    texts =
      for op <- ~w(prompt steer follow_up),
          params <- [
            %{"text" => "hi"},
            %{"text" => over},
            %{"text" => "hi", "origin" => origin.("")},
            %{"text" => "hi", "origin" => origin.(String.duplicate("o", 300))},
            %{"text" => 1}
          ],
          do: {op, params}

    texts ++
      [
        {"subscribe", %{}},
        {"subscribe", %{"tail" => 0}},
        {"subscribe", %{"tail" => "1"}},
        {"history", %{"instance_id" => "x", "before" => "y"}},
        {"history", %{"instance_id" => "x"}},
        {"abort", %{}},
        {"abort", %{"x" => 1}},
        {"set_model", %{"model" => "fake/echo"}},
        {"set_model", %{"model" => "not a model ref"}},
        {"set_model", %{}},
        {"compact", %{}},
        {"compact", %{"text" => over}},
        {"answer", %{"ask_id" => "a", "answer" => %{}}},
        {"answer", %{"ask_id" => "a", "answer" => big_answer}},
        {"answer", %{"ask_id" => "a"}},
        {"stop", %{}},
        {"stop", %{"x" => 1}},
        {"resume", %{}},
        {"resume", %{"x" => 1}},
        {"hub.records.get", %{}},
        {"hub.records.get", %{"x" => 1}},
        {"hub.records.update", %{"title" => "t"}},
        {"hub.records.update", %{"title" => String.duplicate("t", 1_000)}},
        {"hub.records.update", %{}},
        {"hub.records.delete", %{}},
        {"hub.records.delete", %{"x" => 1}},
        {"hub.schedules.create", schedule_params()},
        {"hub.schedules.create",
         %{schedule_params() | "prompt" => String.duplicate("p", 16_385)}},
        {"hub.schedules.create", Map.put(schedule_params(), "every", 1)},
        {"hub.schedules.list", %{}},
        {"hub.schedules.list", %{"x" => 1}},
        {"hub.subscriptions.create", subscription_params()},
        {"hub.subscriptions.create",
         %{subscription_params() | "prompt" => String.duplicate("p", 16_385)}},
        {"hub.subscriptions.create", Map.put(subscription_params(), "prompt", "no placeholder")},
        {"hub.subscriptions.list", %{}},
        {"hub.subscriptions.list", %{"x" => 1}}
      ]
  end

  defp schedule_params,
    do: %{"at" => System.os_time(:second) + 600, "prompt" => "hi"}

  defp subscription_params, do: %{"prompt" => "a payload: {{payload}}"}

  defp schedule_cases,
    do: [{"hub.schedules.delete", %{}}, {"hub.schedules.delete", %{"x" => 1}}]

  defp subscription_cases,
    do: [{"hub.subscriptions.delete", %{}}, {"hub.subscriptions.delete", %{"x" => 1}}]

  defp schedule(socket, session) do
    params = Map.put(schedule_params(), "session", session)

    %{"result" => %{"schedule" => %{"id" => id}}} =
      Client.request(socket, "c", "hub.schedules.create", params)

    id
  end

  defp subscription(socket, session) do
    params = Map.put(subscription_params(), "session", session)

    %{"result" => %{"subscription" => %{"id" => id}}} =
      Client.request(socket, "c", "hub.subscriptions.create", params)

    id
  end

  # The cases of an op that names a project, with a session of the user.
  defp project_cases(own) do
    [
      {"hub.projects.update", %{"name" => "n"}},
      {"hub.projects.update", %{"name" => ""}},
      {"hub.projects.delete", %{}},
      {"hub.projects.delete", %{"x" => 1}},
      {"hub.records.update", %{"session" => own}},
      {"hub.records.update", %{"session" => own, "title" => 7}},
      {"hub.records.search", %{}},
      {"hub.records.search", %{"limit" => 0}}
    ]
  end

  defp token_cases, do: [{"hub.tokens.revoke", %{}}, {"hub.tokens.revoke", %{"x" => 1}}]

  # The answers to the two requests are equal replies, errors with a code
  # and a text, and the connection stays open.
  defp same(socket, op, refused, missing) do
    got = request(socket, op, refused)
    want = request(socket, op, missing)
    assert %{"ok" => false, "error" => %{"code" => _, "text" => _}} = got, op
    assert got == want, "#{op} #{inspect(Map.keys(refused))}: #{inspect([got, want])}"
  end

  defp request(socket, op, params) do
    json = JSON.encode!(%{"type" => "req", "id" => "r", "op" => op, "params" => params})

    if byte_size(json) > @max_frame,
      do: for(part <- Client.parts(json), do: :ok = Client.send_text(socket, part)),
      else: :ok = Client.send_text(socket, json)

    Client.res(socket, "r")
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

  defp user_id(context, name) do
    {:ok, users} = Hub.users(context.hub)
    Enum.find_value(users, &(&1.name == name && &1.id))
  end

  defp start(socket) do
    start = %{"cwd" => File.cwd!(), "model" => "fake/echo"}
    %{"result" => %{"session" => id}} = Client.request(socket, "s", "start", start)
    id
  end

  defp stopped(socket) do
    id = start(socket)
    %{"ok" => true} = Client.request(socket, "s", "stop", %{"session" => id})
    id
  end

  defp project(socket) do
    %{"result" => %{"project" => %{"id" => id}}} =
      Client.request(socket, "p", "hub.projects.create", %{"name" => "theirs"})

    id
  end
end
