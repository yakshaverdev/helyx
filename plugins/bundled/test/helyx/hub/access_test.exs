defmodule Helyx.Hub.AccessTest do
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Provider.Fake
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  @server_token "the server token"
  # A session id with no session and no file.
  @missing "AAAAAAAAAAAA"

  defp serve(%{tmp_dir: dir}, hub_opts \\ []) do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake]}, id: :core)

    opts =
      Keyword.merge(
        [
          core: core,
          default_owner: "owner",
          path: Path.join(dir, "hub.db"),
          server_token: fn -> @server_token end
        ],
        hub_opts
      )
      # A nil option is one that the Hub does not get.
      |> Enum.reject(fn {_key, value} -> value == nil end)

    hub = start_supervised!(Supervisor.child_spec({Hub, opts}, id: :hub))
    transport = start_supervised!({WebSocket, core: core, port: 0, authority: Hub.authority(hub)})
    {:ok, [%{id: owner}]} = Hub.users(hub)
    %{hub: hub, port: WebSocket.port(transport), owner: owner, core: core}
  end

  # A connection that proved `token` (a token text), or the server token.
  defp connect(port, token \\ nil) do
    {:ok, socket} = Client.upgrade(port)
    nonce = Client.challenge(socket)
    Client.send_frame(socket, hello(nonce, token))
    socket
  end

  defp open(port, token \\ nil) do
    socket = connect(port, token)
    {:frame, %{"type" => "welcome"}} = Client.recv(socket)
    socket
  end

  defp hello(nonce, nil), do: Client.hello(nonce, @server_token)

  defp hello(nonce, token),
    do: Map.put(Client.hello(nonce, token), "token", hd(String.split(token, ".")))

  defp user(hub, name) do
    {:ok, %{id: id}} = Hub.add_user(hub, name)
    {:ok, token} = Hub.create_token(hub, id, "laptop")
    {id, token}
  end

  defp start_session(socket, id) do
    start = %{"cwd" => File.cwd!(), "model" => "fake/echo"}
    %{"result" => %{"session" => session}} = Client.request(socket, id, "start", start)
    session
  end

  describe "the hello through the authority" do
    setup :serve

    test "the server token proves the default owner; a token proves its user", context do
      socket = open(context.port)

      assert %{"result" => %{"user" => %{"id" => owner, "name" => "owner"}}} =
               Client.request(socket, "1", "hub.me", %{})

      assert owner == context.owner

      {ann, token} = user(context.hub, "ann")
      socket = open(context.port, token)

      assert %{"result" => %{"user" => %{"id" => ^ann, "name" => "ann"}}} =
               Client.request(socket, "1", "hub.me", %{})
    end

    test "an unknown id, a revoked token, no proof, and a wrong proof close with 4401",
         context do
      {_ann, token} = user(context.hub, "ann")
      {_bob, revoked} = user(context.hub, "bob")
      :ok = Hub.revoke_token(context.hub, hd(String.split(revoked, ".")))

      hellos = [
        fn nonce -> hello(nonce, "AAAAAAAAAAAA." <> String.duplicate("x", 43)) end,
        fn nonce -> hello(nonce, revoked) end,
        fn nonce -> Map.delete(hello(nonce, token), "proof") end,
        fn nonce -> Map.put(hello(nonce, token), "proof", Client.proof(nonce, "wrong")) end,
        fn nonce -> Map.put(Client.hello(nonce, nil), "proof", Client.proof(nonce, token)) end
      ]

      for hello <- hellos do
        {:ok, socket} = Client.upgrade(context.port)
        Client.send_frame(socket, hello.(Client.challenge(socket)))
        assert {:close, 4401} = Client.recv(socket)
      end
    end

    test "a Hub with no server token closes a hello with no token with 4401", context do
      stop_supervised!(WebSocket)
      stop_supervised!(:hub)
      stop_supervised!(:core)
      context = serve(context, server_token: nil)
      socket = connect(context.port)
      assert {:close, 4401} = Client.recv(socket)
    end

    test "a server token closure that gives no text proves nothing; the Hub runs on",
         context do
      stop_supervised!(WebSocket)
      stop_supervised!(:hub)
      stop_supervised!(:core)

      for token <- [fn -> nil end, fn -> "" end] do
        context = serve(context, server_token: token)
        {:ok, socket} = Client.upgrade(context.port)
        Client.send_frame(socket, Client.hello(Client.challenge(socket), nil))
        assert {:close, 4401} = Client.recv(socket)
        assert {:ok, [_]} = Hub.users(context.hub)
        stop_supervised!(WebSocket)
        stop_supervised!(:hub)
        stop_supervised!(:core)
      end
    end

    test "a busy Hub and a Hub that is down close the hello with 4503", context do
      :erlang.suspend_process(context.hub)
      for _ <- 1..1_024, do: send(context.hub, :filler)
      socket = connect(context.port)
      assert {:close, 4503} = Client.recv(socket)

      ExUnit.CaptureLog.capture_log(fn ->
        :erlang.resume_process(context.hub)
        :sys.get_state(context.hub)
        stop_supervised!(:hub)
      end)

      socket = connect(context.port)
      assert {:close, 4503} = Client.recv(socket)
    end
  end

  describe "the credential" do
    setup :serve

    test "a revoke or a remove ends the use of a token at its next request", context do
      {ann, token} = user(context.hub, "ann")
      socket = open(context.port, token)
      :ok = Hub.revoke_token(context.hub, hd(String.split(token, ".")))
      Client.send_request(socket, "1", "sessions.live", %{})
      assert {:close, 4403} = Client.until_close(socket)

      {:ok, token} = Hub.create_token(context.hub, ann, "phone")
      socket = open(context.port, token)
      :ok = Hub.remove_user(context.hub, ann)
      Client.send_request(socket, "1", "hub.me", %{})
      assert {:close, 4403} = Client.until_close(socket)
    end
  end

  describe "the run of an op with no object" do
    setup :serve

    test "checks the credential first: a revoked one closes with 4403", context do
      for {op, params} <- [
            {"sessions.saved", %{}},
            {"hub.me", %{"x" => 1}},
            {"hub.records.get", %{"session" => @missing}}
          ] do
        {_id, token} = user(context.hub, "u#{System.unique_integer([:positive])}")
        socket = open(context.port, token)
        :ok = Hub.revoke_token(context.hub, hd(String.split(token, ".")))
        Client.send_request(socket, "1", op, params)
        assert {:close, 4403} = Client.until_close(socket), op
      end
    end
  end

  describe "tokens" do
    setup :serve

    test "list shows ids and names; a token of another user is unknown, as a missing one",
         context do
      {_ann, token} = user(context.hub, "ann")
      {_bob, bob_token} = user(context.hub, "bob")
      socket = open(context.port, token)
      id = hd(String.split(token, "."))

      assert %{"result" => %{"tokens" => [%{"id" => ^id, "name" => "laptop"} = listed]}} =
               Client.request(socket, "1", "hub.tokens.list", %{})

      assert Map.keys(listed) |> Enum.sort() == ~w(created_at id name)

      other =
        Client.request(socket, "2", "hub.tokens.revoke", %{
          "token" => hd(String.split(bob_token, "."))
        })

      missing = Client.request(socket, "3", "hub.tokens.revoke", %{"token" => @missing})
      assert other["error"] == missing["error"]
      assert %{"code" => "unknown_token"} = other["error"]

      assert %{"error" => %{"code" => "bad_params"}} =
               Client.request(socket, "4", "hub.tokens.revoke", %{"token" => 7})

      assert %{"error" => %{"code" => "bad_params"}} =
               Client.request(socket, "5", "hub.me", %{"x" => 1})
    end

    test "a revoke of the token of the connection closes it before the reply", context do
      {_ann, token} = user(context.hub, "ann")
      socket = open(context.port, token)

      Client.send_request(socket, "1", "hub.tokens.revoke", %{
        "token" => hd(String.split(token, "."))
      })

      # The close is the first frame after the request: no reply came before it.
      assert {:close, 4403} = Client.recv(socket)
    end
  end

  describe "sessions" do
    setup :serve

    test "a session of the default owner is private to it; a refusal is a missing session",
         context do
      owner = open(context.port)
      session = start_session(owner, "1")
      {_ann, token} = user(context.hub, "ann")
      ann = open(context.port, token)

      assert %{"result" => %{"sessions" => []}} = Client.request(ann, "1", "sessions.live", %{})

      for {op, params} <- [
            {"subscribe", %{}},
            {"history", %{"instance_id" => "x", "before" => "y"}},
            {"prompt", %{"text" => "hi"}},
            {"steer", %{"text" => "hi"}},
            {"follow_up", %{"text" => "hi"}},
            {"compact", %{}},
            {"answer", %{"ask_id" => "a", "answer" => %{}}},
            {"abort", %{}},
            {"set_model", %{"model" => "fake/echo"}},
            {"stop", %{}}
          ] do
        refused = Client.request(ann, "r", op, Map.put(params, "session", session))
        missing = Client.request(ann, "m", op, Map.put(params, "session", @missing))
        assert refused["error"] == missing["error"], op
        assert refused["error"]["code"] == "session_not_found"
      end

      refused = Client.request(ann, "2", "resume", %{"id" => session})
      missing = Client.request(ann, "3", "resume", %{"id" => @missing})
      assert refused["error"] == missing["error"]
      assert %{"code" => "not_found"} = refused["error"]

      assert %{"result" => %{"sessions" => [%{"id" => ^session}]}} =
               Client.request(owner, "2", "sessions.live", %{})
    end

    test "a start of a user writes its record: the user owns the session", context do
      {_ann, token} = user(context.hub, "ann")
      ann = open(context.port, token)
      session = start_session(ann, "1")
      owner = open(context.port)

      assert %{"result" => %{"sessions" => [%{"id" => ^session}]}} =
               Client.request(ann, "2", "sessions.live", %{})

      assert %{"result" => %{"sessions" => []}} = Client.request(owner, "1", "sessions.live", %{})

      assert %{"error" => %{"code" => "session_not_found"}} =
               Client.request(owner, "2", "abort", %{"session" => session})

      assert %{"ok" => true} = Client.request(ann, "3", "abort", %{"session" => session})
    end

    test "a start of a user with a cwd of 0 or over 4,096 bytes is bad_params", context do
      {_ann, token} = user(context.hub, "ann")
      ann = open(context.port, token)

      for cwd <- ["", "/" <> String.duplicate("d", 4_096)] do
        assert %{"error" => %{"code" => "bad_params"}} =
                 Client.request(ann, "1", "start", %{"cwd" => cwd, "model" => "fake/echo"})
      end
    end

    test "the first text sets the prompt of the record, cut to 1,024 bytes", context do
      {_ann, token} = user(context.hub, "ann")
      ann = open(context.port, token)
      a = &String.duplicate("a", &1)

      # The text, and the prompt that the record keeps.
      cases = [
        {a.(1_024), a.(1_024)},
        {a.(1_025), a.(1_024)},
        {a.(1_023) <> "é and more", a.(1_023)},
        {a.(1_022) <> "€", a.(1_022)},
        {a.(1_021) <> "😀", a.(1_021)},
        {a.(1_020) <> "😀", a.(1_020) <> "😀"}
      ]

      sessions =
        for {{text, _}, n} <- Enum.with_index(cases) do
          session = start_session(ann, "s#{n}")
          Client.request(ann, "p#{n}", "prompt", %{"session" => session, "text" => text})
          Client.request(ann, "q#{n}", "steer", %{"session" => session, "text" => "second"})
          session
        end

      stop_supervised!(WebSocket)
      stop_supervised!(:hub)
      {:ok, db} = Helyx.Hub.Store.SQLite.open(path: Path.join(context.tmp_dir, "hub.db"))

      for {session, {_text, prompt}} <- Enum.zip(sessions, cases) do
        assert {:ok, %{prompt: ^prompt, model: "fake/echo"}} =
                 Helyx.Hub.Store.SQLite.record(db, session)
      end

      :ok = Helyx.Hub.Store.SQLite.close(db)
    end
  end
end
