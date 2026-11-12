defmodule Helyx.Hub.RecordsTest do
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Provider.Fake
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  @server_token "the server token"
  # A session id with no session and no file.
  @missing "AAAAAAAAAAAA"

  # A Core with a data folder, so a stopped session has a file.
  setup %{tmp_dir: dir} = context do
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake], sessions_dir: data}, id: :core)

    hub_opts =
      [core: core, default_owner: "owner", server_token: fn -> @server_token end] ++
        store(context)

    hub = start_supervised!(Supervisor.child_spec({Hub, hub_opts}, id: :hub))
    transport = start_supervised!({WebSocket, core: core, port: 0, authority: Hub.authority(hub)})
    %{hub: hub, port: WebSocket.port(transport)}
  end

  defp store(%{store: store}), do: [store: store]
  defp store(_context), do: []

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

  defp start(socket) do
    start = %{"cwd" => File.cwd!(), "model" => "fake/echo"}
    %{"result" => %{"session" => id}} = Client.request(socket, "s", "start", start)
    id
  end

  defp req(socket, op, params), do: Client.request(socket, "r", op, params)

  defp update(socket, session, fields),
    do: req(socket, "hub.records.update", Map.put(fields, "session", session))

  # A store whose writes of the row of a session fail, as a busy store or a
  # deadline does. Each read works, so the Hub runs.
  defmodule NoRowWrite do
    @behaviour Helyx.Hub.Store
    alias Helyx.Hub.Store.SQLite

    for {name, arity} <-
          Helyx.Hub.Store.behaviour_info(:callbacks),
        name not in [:seen_record, :ensure_records] do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl true
      def unquote(name)(unquote_splicing(args)), do: SQLite.unquote(name)(unquote_splicing(args))
    end

    @impl true
    def seen_record(_db, _record, _deadline), do: {:error, :busy}

    @impl true
    def ensure_records(_db, _records, _deadline), do: {:error, :busy}
  end

  describe "refused equals missing (decision 8, Boundaries)" do
    test "every operation on a private session of another user, running and stopped",
         context do
      {_ann, ann} = user(context, "ann")
      running = start(ann)
      stopped = start(ann)
      %{"ok" => true} = req(ann, "stop", %{"session" => stopped})
      owner_socket = open(context.port)
      {_bob, bob} = user(context, "bob")
      big_answer = %{"a" => String.duplicate("b", Helyx.Session.max_answer_bytes())}

      cases = [
        {"subscribe", %{}},
        {"history", %{"instance_id" => "x", "before" => "y"}},
        {"prompt", %{"text" => "hi"}},
        {"prompt", %{"text" => "hi", "origin" => %{"kind" => "product", "id" => ""}}},
        {"prompt",
         %{"text" => "hi", "origin" => %{"kind" => "product", "id" => String.duplicate("o", 300)}}},
        {"steer", %{"text" => "hi"}},
        {"follow_up", %{"text" => "hi"}},
        {"abort", %{}},
        {"set_model", %{"model" => "fake/echo"}},
        {"set_model", %{"model" => "not a model ref"}},
        {"compact", %{}},
        {"answer", %{"ask_id" => "a", "answer" => %{}}},
        {"answer", %{"ask_id" => "a", "answer" => big_answer}},
        {"stop", %{}},
        {"resume", %{}},
        {"hub.records.get", %{}},
        {"hub.records.update", %{"title" => "t"}},
        {"hub.records.delete", %{}}
      ]

      for socket <- [owner_socket, bob], {op, params} <- cases, refused <- [running, stopped] do
        key = if op == "resume", do: "id", else: "session"
        got = req(socket, op, Map.put(params, key, refused))
        missing = req(socket, op, Map.put(params, key, @missing))
        assert got["error"] == missing["error"], "#{op} #{inspect(params)}"
        assert got["ok"] == false
      end
    end
  end

  describe "hub.records" do
    test "get: the record of a session of the default owner is stored, and the project only for its owner",
         context do
      {ann_id, ann} = user(context, "ann")
      session = start(ann)

      assert %{"result" => %{"record" => record}} =
               req(ann, "hub.records.get", %{"session" => session})

      assert %{"session" => ^session, "owner" => %{"id" => ^ann_id, "name" => "ann"}} = record

      assert %{"stored" => true, "visibility" => "private", "labels" => [], "title" => ""} =
               record

      owner = open(context.port)
      own = start(owner)

      # The feed wrote the row of the default owner at the start.
      assert %{
               "result" => %{
                 "record" => %{
                   "stored" => true,
                   "created_at" => created_at,
                   "owner" => %{"name" => "owner"}
                 }
               }
             } = req(owner, "hub.records.get", %{"session" => own})

      assert is_integer(created_at)
    end

    test "update: the fields and their bounds; a hub record is read by others", context do
      {_ann_id, ann} = user(context, "ann")
      {_bob_id, bob} = user(context, "bob")
      session = start(ann)
      bad = &assert(%{"error" => %{"code" => "bad_params"}} = update(ann, session, &1))

      for fields <- [
            %{},
            %{"title" => String.duplicate("t", 257)},
            %{"title" => String.duplicate("t", 255) <> "é"},
            %{"title" => "a\nb"},
            %{"title" => "a\u0085b"},
            %{"title" => "a\u007fb"},
            %{"labels" => Enum.map(1..17, &"l#{&1}")},
            %{"labels" => [String.duplicate("l", 65)]},
            %{"labels" => [""]},
            %{"labels" => "release"},
            %{"visibility" => "public"},
            %{"archived" => "yes"},
            %{"project" => 7},
            %{"other" => 1}
          ],
          do: bad.(fields)

      assert %{"result" => %{"record" => %{"title" => ""}}} =
               update(ann, session, %{"title" => ""})

      assert %{"result" => %{"record" => %{"labels" => [long]}}} =
               update(ann, session, %{"labels" => [String.duplicate("l", 62) <> "é"]})

      assert byte_size(long) == 64
      bad.(%{"labels" => [String.duplicate("l", 63) <> "é"]})

      labels = Enum.map(1..16, &"l#{&1}") ++ ["l1"]

      assert %{"result" => %{"record" => record}} =
               update(ann, session, %{
                 "title" => String.duplicate("t", 254) <> "é",
                 "labels" => labels,
                 "visibility" => "hub",
                 "archived" => true
               })

      assert length(record["labels"]) == 16
      assert %{"visibility" => "hub", "archived" => true} = record
      assert byte_size(record["title"]) == 256

      # A reader reads the record, with no project, and gets forbidden on a write.
      assert %{"result" => %{"record" => %{"project" => nil}}} =
               req(bob, "hub.records.get", %{"session" => session})

      assert %{"error" => %{"code" => "forbidden"}} = update(bob, session, %{"title" => "x"})
      assert %{"error" => %{"code" => "forbidden"}} = req(bob, "abort", %{"session" => session})

      assert %{"error" => %{"code" => "forbidden"}} =
               req(bob, "hub.records.delete", %{"session" => session})

      # A reader subscribes to the session.
      assert %{"ok" => true} = req(bob, "subscribe", %{"session" => session})
    end

    test "update with projects: own, of another user, missing, and null", context do
      {_ann_id, ann} = user(context, "ann")
      {_bob_id, bob} = user(context, "bob")
      session = start(ann)

      %{"result" => %{"project" => %{"id" => mine}}} =
        req(ann, "hub.projects.create", %{"name" => "web"})

      %{"result" => %{"project" => %{"id" => bobs}}} =
        req(bob, "hub.projects.create", %{"name" => "web"})

      assert %{"result" => %{"record" => %{"project" => ^mine}}} =
               update(ann, session, %{"project" => mine})

      other = update(ann, session, %{"project" => bobs})
      missing = update(ann, session, %{"project" => @missing})
      assert other["error"] == missing["error"]
      assert %{"code" => "unknown_project"} = other["error"]

      assert %{"result" => %{"record" => %{"project" => nil}}} =
               update(ann, session, %{"project" => nil})

      # A delete of the project clears it from its records.
      update(ann, session, %{"project" => mine})
      assert %{"ok" => true} = req(ann, "hub.projects.delete", %{"project" => mine})

      assert %{"result" => %{"record" => %{"project" => nil}}} =
               req(ann, "hub.records.get", %{"session" => session})
    end

    test "a get or update of a found session writes its row; a delete gives it back to the default owner",
         context do
      {_ann_id, ann} = user(context, "ann")
      session = start(ann)

      assert %{"result" => %{"record" => %{"title" => "mine"}}} =
               update(ann, session, %{"title" => "mine"})

      assert %{"ok" => true} = req(ann, "hub.records.delete", %{"session" => session})

      # The session has no row, so it goes back to the default owner, whose
      # next get writes the row.
      owner = open(context.port)

      assert %{"result" => %{"record" => record}} =
               req(owner, "hub.records.get", %{"session" => session})

      assert %{"stored" => true, "title" => "", "owner" => %{"name" => "owner"}} = record

      assert %{"error" => %{"code" => "session_not_found"}} =
               req(ann, "hub.records.get", %{"session" => session})
    end

    # The write of the row fails while the read works: the session exists, so
    # the answer is the record of the default owner without the stored row,
    # not a failed operation (decision 8).
    @tag store: NoRowWrite
    test "get: a found session whose row the store did not write answers the default owner's record",
         context do
      owner = open(context.port)
      session = start(owner)

      assert %{"result" => %{"record" => record}} =
               req(owner, "hub.records.get", %{"session" => session})

      assert %{
               "session" => ^session,
               "stored" => false,
               "owner" => %{"name" => "owner"},
               "title" => "",
               "labels" => [],
               "created_at" => nil,
               "updated_at" => nil
             } = record
    end
  end

  # A file of the session `id` beside the file of `real`, with only the
  # header of that file, changed by `changes`. Gives the path of the file
  # of `real`.
  defp copy_header(context, real, id, changes) do
    [path] = Path.wildcard(Path.join([context.tmp_dir, "data", "*", real <> ".jsonl"]))
    [line | _] = path |> File.read!() |> String.split("\n")
    header = line |> JSON.decode!() |> Map.merge(Map.put(changes, "id", id))
    File.write!(Path.join(Path.dirname(path), id <> ".jsonl"), JSON.encode!(header) <> "\n")
    path
  end

  describe "the existence check" do
    test "a file whose header a record cannot hold finds nothing; the Hub runs on",
         context do
      owner = open(context.port)
      # A header with a model that is not a text.
      copy_header(context, start(owner), "DAMAGEDxxxxx", %{"model" => %{}})

      missing = req(owner, "hub.records.update", %{"session" => @missing, "title" => "t"})
      damaged = req(owner, "hub.records.update", %{"session" => "DAMAGEDxxxxx", "title" => "t"})
      assert damaged["error"] == missing["error"]
      assert {:ok, [_ | _]} = Hub.users(context.hub)
    end

    test "a running session whose file is gone exists; a header model with a control character does not",
         context do
      owner = open(context.port)
      running = start(owner)
      id = "CONTROLxxxxx"
      path = copy_header(context, running, id, %{"model" => "fake/\u0007echo"})
      File.rm!(path)

      assert %{"result" => %{"record" => %{"stored" => true}}} =
               req(owner, "hub.records.get", %{"session" => running})

      assert %{"result" => %{"record" => %{"stored" => true}}} =
               update(owner, running, %{"title" => "t"})

      missing = req(owner, "hub.records.get", %{"session" => @missing})
      assert req(owner, "hub.records.get", %{"session" => id})["error"] == missing["error"]
    end

    test "a Core with no data folder: a cwd that a record cannot hold finds nothing" do
      core = :"core_#{System.unique_integer([:positive])}"
      start_supervised!({Helyx.Core, name: core, plugins: [Fake]}, id: :plain_core)
      opts = [core: core, default_owner: "owner", server_token: fn -> @server_token end]
      hub = start_supervised!(Supervisor.child_spec({Hub, opts}, id: :plain_hub))

      transport =
        start_supervised!({WebSocket, core: core, port: 0, authority: Hub.authority(hub)},
          id: :plain_transport
        )

      owner = open(WebSocket.port(transport))
      long = "/" <> String.duplicate("a", 4_096)

      %{"result" => %{"session" => id}} =
        req(owner, "start", %{"cwd" => long, "model" => "fake/echo"})

      missing = update(owner, @missing, %{"title" => "t"})
      assert update(owner, id, %{"title" => "t"})["error"] == missing["error"]

      ok = start(owner)

      assert %{"result" => %{"record" => %{"stored" => true}}} =
               update(owner, ok, %{"title" => "t"})

      assert {:ok, _} = Hub.users(hub)
    end
  end

  describe "hub.records.search" do
    test "access, filters, paging, and the bounds of its params", context do
      {_ann_id, ann} = user(context, "ann")
      {_bob_id, bob} = user(context, "bob")
      sessions = for _ <- 1..5, do: start(ann)
      [s1, s2, s3 | _] = sessions
      update(ann, s1, %{"title" => "Release Notes", "labels" => ["release"]})

      update(ann, s2, %{
        "title" => "release plan",
        "labels" => ["release", "plan"],
        "visibility" => "hub"
      })

      update(ann, s3, %{"archived" => true})
      bob_session = start(bob)
      update(bob, bob_session, %{"title" => "bob release", "visibility" => "hub"})

      ids = fn res -> Enum.map(res["result"]["items"], & &1["session"]) end
      search = &req(ann, "hub.records.search", &1)

      assert ids.(search.(%{"query" => "RELEASE"})) |> Enum.sort() ==
               Enum.sort([s1, s2, bob_session])

      assert ids.(search.(%{"query" => "release", "mine" => true})) |> Enum.sort() ==
               Enum.sort([s1, s2])

      assert ids.(search.(%{"labels" => ["release", "plan"]})) == [s2]
      assert ids.(search.(%{"archived" => true})) == [s3]

      # Bob sees ann's hub record only.
      assert ids.(req(bob, "hub.records.search", %{"query" => "release"})) |> Enum.sort() ==
               Enum.sort([s2, bob_session])

      # Paging: every readable record once, and the cursor of the last item.
      pages =
        Stream.unfold(nil, fn
          :done ->
            nil

          cursor ->
            params = if cursor, do: %{"limit" => 2, "after" => cursor}, else: %{"limit" => 2}
            %{"result" => %{"items" => items, "next" => next}} = search.(params)
            {Enum.map(items, & &1["session"]), next || :done}
        end)
        |> Enum.to_list()

      assert pages |> List.flatten() |> Enum.sort() == Enum.sort(sessions ++ [bob_session])
      assert Enum.all?(pages, &(length(&1) <= 2))

      for params <- [
            %{"limit" => 0},
            %{"limit" => 257},
            %{"after" => "x"},
            %{"after" => "1:short"},
            %{"query" => String.duplicate("q", 257)},
            %{"mine" => "yes"},
            %{"other" => 1}
          ],
          do: assert(%{"error" => %{"code" => "bad_params"}} = search.(params), inspect(params))

      assert %{"ok" => true} = search.(%{"limit" => 256, "query" => String.duplicate("q", 256)})

      assert %{"ok" => true} =
               search.(%{"limit" => 1, "query" => String.duplicate("q", 254) <> "é"})

      assert %{"error" => %{"code" => "bad_params"}} =
               search.(%{"query" => String.duplicate("q", 255) <> "é"})

      # The cursor time binds as an integer of 64 bits: one more is bad params.
      assert %{"ok" => true} = search.(%{"after" => "9223372036854775807:AAAAAAAAAAAA"})

      assert %{"error" => %{"code" => "bad_params"}} =
               search.(%{"after" => "9223372036854775808:AAAAAAAAAAAA"})

      assert {:ok, _} = Hub.users(context.hub)

      %{"result" => %{"project" => %{"id" => bobs}}} =
        req(bob, "hub.projects.create", %{"name" => "p"})

      other = search.(%{"project" => bobs})
      missing = search.(%{"project" => @missing})
      assert other["error"] == missing["error"]
      assert %{"code" => "unknown_project"} = other["error"]
    end
  end

  describe "hub.projects" do
    test "create, list, rename, delete, and their bounds", context do
      {_ann_id, ann} = user(context, "ann")
      {_bob_id, bob} = user(context, "bob")
      name = String.duplicate("p", 128)

      assert %{"result" => %{"project" => %{"id" => id, "name" => ^name}}} =
               req(ann, "hub.projects.create", %{"name" => name})

      assert %{"ok" => true} =
               req(ann, "hub.projects.create", %{"name" => String.duplicate("p", 126) <> "é"})

      for bad <- [
            String.duplicate("p", 129),
            String.duplicate("q", 127) <> "é",
            "",
            "a\tb",
            7,
            name
          ] do
        assert %{"error" => %{"code" => "bad_params"}} =
                 req(ann, "hub.projects.create", %{"name" => bad})
      end

      assert %{"result" => %{"projects" => [%{"id" => ^id}, _multibyte]}} =
               req(ann, "hub.projects.list", %{})

      assert %{"result" => %{"projects" => []}} = req(bob, "hub.projects.list", %{})

      assert %{"result" => %{"project" => %{"name" => "renamed"}}} =
               req(ann, "hub.projects.update", %{"project" => id, "name" => "renamed"})

      for op <- ~w(hub.projects.update hub.projects.delete) do
        params =
          %{"project" => id, "name" => "x"}
          |> then(&if(op =~ "delete", do: Map.delete(&1, "name"), else: &1))

        other = req(bob, op, params)
        missing = req(bob, op, %{params | "project" => @missing})
        assert other["error"] == missing["error"]
        assert %{"code" => "unknown_project"} = other["error"]
      end

      assert %{"ok" => true} = req(ann, "hub.projects.delete", %{"project" => id})
    end

    test "a user holds at most 256 projects", context do
      {_ann_id, ann} = user(context, "ann")
      for n <- 1..256, do: %{"ok" => true} = req(ann, "hub.projects.create", %{"name" => "p#{n}"})

      assert %{"error" => %{"code" => "too_many_projects"}} =
               req(ann, "hub.projects.create", %{"name" => "p257"})
    end
  end
end
