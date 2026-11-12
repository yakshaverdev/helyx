defmodule Helyx.Hub.Store.SQLiteTest do
  use ExUnit.Case, async: true

  alias Helyx.Hub.Store.SQLite

  @moduletag :tmp_dir

  defp user(name),
    do: %{id: name <> String.duplicate("x", 12 - byte_size(name)), name: name, created_at: 1}

  defp token(id, user_id),
    do: %{id: id, user_id: user_id, name: "t", key: :crypto.hash(:sha256, id), created_at: 1}

  defp peer(name, kind \\ "hands", key \\ nil) do
    %{name: name, kind: kind, public_key: key || :crypto.strong_rand_bytes(32), created_at: 1}
  end

  test "a new file gets mode 0600, schema version 4, and opens again after a close", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "hub.db")
    {:ok, db} = SQLite.open(path: path)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    :ok = SQLite.add_user(db, user("ann"), 64, :infinity)
    # WAL journal: the log exists while the store is open, with the mode of the file.
    assert Bitwise.band(File.stat!(path <> "-wal").mode, 0o777) == 0o600
    :ok = SQLite.close(db)

    {:ok, db} = SQLite.open(path: path)
    assert {:ok, [%{name: "ann"}]} = SQLite.users(db)
    :ok = SQLite.close(db)
  end

  test "a file of another schema version stops the open", %{tmp_dir: dir} do
    path = Path.join(dir, "hub.db")
    {:ok, db} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(db, "PRAGMA user_version = 5")
    :ok = Exqlite.Sqlite3.close(db)

    assert SQLite.open(path: path) == {:error, {:store_version, 5}}
  end

  test "a store of version 2 opens with its rows and gets the parents and the peers table", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "hub.db")
    version_2(path)

    {:ok, db} = SQLite.open(path: path)
    assert {:ok, [%{name: "ann"}]} = SQLite.users(db)

    assert {:ok, %{session_id: "OLDxxxxxxxxx", parent_id: nil, parent_kind: nil}} =
             SQLite.record(db, "OLDxxxxxxxxx")

    assert SQLite.peers(db) == {:ok, []}

    %{db: connection} = db
    assert {:ok, [4]} = Helyx.Hub.Store.SQLite.Query.one(connection, "PRAGMA user_version", [])

    row = %{
      session_id: "NEWxxxxxxxxx",
      owner: "ann",
      cwd: "/w",
      model: "fake/echo",
      prompt: "",
      active_at: 20,
      created_at: 20,
      parent_id: "PARENTxxxxxx",
      parent_kind: "child"
    }

    assert :ok = SQLite.seen_record(db, row, :infinity)

    assert {:ok, %{parent_id: "PARENTxxxxxx", parent_kind: "child"}} =
             SQLite.record(db, "NEWxxxxxxxxx")

    :ok = SQLite.close(db)
  end

  # A file of version 3, the schema before the peers table.
  defp version_3(path) do
    {:ok, db} = SQLite.open(path: path)
    :ok = SQLite.add_user(db, user("ann"), 64, :infinity)
    :ok = SQLite.close(db)

    {:ok, raw} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(raw, "DROP TABLE peers")
    :ok = Exqlite.Sqlite3.execute(raw, "PRAGMA user_version = 3")
    :ok = Exqlite.Sqlite3.close(raw)
  end

  test "a store of version 3 opens with its rows and gets the peers table", %{tmp_dir: dir} do
    path = Path.join(dir, "hub.db")
    version_3(path)

    {:ok, db} = SQLite.open(path: path)
    assert {:ok, [%{name: "ann"}]} = SQLite.users(db)
    assert SQLite.peers(db) == {:ok, []}

    %{db: connection} = db
    assert {:ok, [4]} = Helyx.Hub.Store.SQLite.Query.one(connection, "PRAGMA user_version", [])

    :ok = SQLite.close(db)
  end

  describe "peers" do
    test "the cap is 64 rows: one under, at, and one over" do
      {:ok, db} = SQLite.open(path: nil)

      for n <- 1..63, do: assert(:ok = SQLite.put_peer(db, peer("r#{n}"), 64, :infinity))
      assert :ok = SQLite.put_peer(db, peer("r64"), 64, :infinity)
      assert SQLite.put_peer(db, peer("r65"), 64, :infinity) == {:error, :too_many_peers}
      :ok = SQLite.close(db)
    end

    test "a pairing of a name replaces its key, and a kind is its own row" do
      {:ok, db} = SQLite.open(path: nil)
      new_key = :crypto.strong_rand_bytes(32)

      assert :ok = SQLite.put_peer(db, peer("mac"), 64, :infinity)
      assert :ok = SQLite.put_peer(db, peer("mac", "hands", new_key), 64, :infinity)
      assert {:ok, %{public_key: ^new_key, kind: "hands"}} = SQLite.peer(db, "hands", "mac")

      assert :ok = SQLite.put_peer(db, peer("mac", "client"), 64, :infinity)
      assert {:ok, peers} = SQLite.peers(db)
      assert length(peers) == 2

      assert :ok = SQLite.delete_peer(db, "hands", "mac", :infinity)
      assert SQLite.peer(db, "hands", "mac") == {:error, :not_found}
      assert SQLite.delete_peer(db, "hands", "mac", :infinity) == {:error, :not_found}
      :ok = SQLite.close(db)
    end

    test "a name of 64 bytes is stored, and a name at the cap does not push a row out" do
      {:ok, db} = SQLite.open(path: nil)
      name = String.duplicate("a", 64)

      assert :ok = SQLite.put_peer(db, peer(name), 1, :infinity)
      assert SQLite.put_peer(db, peer("b"), 1, :infinity) == {:error, :too_many_peers}
      assert {:ok, %{name: ^name}} = SQLite.peer(db, "hands", name)
      :ok = SQLite.close(db)
    end
  end

  # A store of version 2, the schema before the parent columns of a record.
  defp version_2(path) do
    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(db, """
      PRAGMA user_version = 2;
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL
      ) STRICT;
      CREATE TABLE records (
        session_id TEXT PRIMARY KEY,
        owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        project_id TEXT,
        title TEXT NOT NULL DEFAULT '',
        cwd TEXT NOT NULL,
        model TEXT NOT NULL,
        prompt TEXT NOT NULL DEFAULT '',
        active_at INTEGER NOT NULL,
        visibility TEXT NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'hub')),
        archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      ) STRICT;
      INSERT INTO users VALUES ('ann', 'ann', 1);
      INSERT INTO records (session_id, owner, cwd, model, active_at, created_at, updated_at)
        VALUES ('OLDxxxxxxxxx', 'ann', '/w', 'fake/echo', 10, 10, 10);
      """)

    :ok = Exqlite.Sqlite3.close(db)
  end

  test "a store in memory ends with its connection" do
    {:ok, db} = SQLite.open(path: nil)
    :ok = SQLite.add_user(db, user("ann"), 64, :infinity)
    :ok = SQLite.close(db)
    {:ok, db} = SQLite.open(path: nil)
    assert SQLite.users(db) == {:ok, []}
    :ok = SQLite.close(db)
  end

  test "a query that cannot run answers :failed" do
    {:ok, db} = SQLite.open(path: nil)
    %{db: connection} = db
    :ok = Exqlite.Sqlite3.execute(connection, "DROP TABLE tokens")
    assert SQLite.tokens(db, "u") == {:error, :failed}
    assert SQLite.add_token(db, token("t1", "u"), 2, :infinity) == {:error, :failed}
    :ok = SQLite.close(db)
  end

  test "a write that ends at or past its deadline rolls back and answers :timeout" do
    {:ok, db} = SQLite.open(path: nil)
    past = System.monotonic_time(:millisecond)
    assert SQLite.add_user(db, user("ann"), 64, past) == {:error, :timeout}
    assert SQLite.users(db) == {:ok, []}

    :ok = SQLite.add_user(db, user("ann"), 64, past + 60_000)
    assert SQLite.add_token(db, token("t1", user("ann").id), 16, past) == {:error, :timeout}
    assert SQLite.tokens(db, user("ann").id) == {:ok, []}
    :ok = SQLite.add_token(db, token("t1", user("ann").id), 16, :infinity)
    assert SQLite.revoke_token(db, :any, "t1", past) == {:error, :timeout}
    assert SQLite.remove_user(db, user("ann").id, past) == {:error, :timeout}
    assert {:ok, %{id: "t1"}} = SQLite.token(db, "t1")
    :ok = SQLite.close(db)
  end

  test "the user cap and the unique name hold in one step" do
    {:ok, db} = SQLite.open(path: nil)
    :ok = SQLite.add_user(db, user("a"), 2, :infinity)
    assert SQLite.add_user(db, %{user("b") | name: "a"}, 2, :infinity) == {:error, :name_taken}
    :ok = SQLite.add_user(db, user("b"), 2, :infinity)
    assert SQLite.add_user(db, user("c"), 2, :infinity) == {:error, :too_many_users}
  end

  test "the token cap, a token of an unknown user, and a revoke scoped to its user" do
    {:ok, db} = SQLite.open(path: nil)
    :ok = SQLite.add_user(db, user("a"), 64, :infinity)
    :ok = SQLite.add_user(db, user("b"), 64, :infinity)
    a = user("a").id
    b = user("b").id

    assert SQLite.add_token(db, token("t1", "nobody"), 2, :infinity) == {:error, :unknown_user}
    :ok = SQLite.add_token(db, token("t1", a), 2, :infinity)
    :ok = SQLite.add_token(db, token("t2", a), 2, :infinity)
    assert SQLite.add_token(db, token("t3", a), 2, :infinity) == {:error, :too_many_tokens}

    assert {:ok, %{user_id: ^a, key: key}} = SQLite.token(db, "t1")
    assert key == :crypto.hash(:sha256, "t1")
    assert {:ok, [%{id: "t1"}, %{id: "t2"}] = infos} = SQLite.tokens(db, a)
    refute Enum.any?(infos, &Map.has_key?(&1, :key))

    # Oldest first, in the order of insert within one second.
    :ok = SQLite.add_token(db, token("zz", b), 4, :infinity)
    :ok = SQLite.add_token(db, token("aa", b), 4, :infinity)
    assert {:ok, [%{id: "zz"}, %{id: "aa"}]} = SQLite.tokens(db, b)

    assert SQLite.revoke_token(db, b, "t1", :infinity) == {:error, :not_found}
    assert SQLite.revoke_token(db, b, "missing", :infinity) == {:error, :not_found}
    assert SQLite.revoke_token(db, a, "t1", :infinity) == :ok
    assert SQLite.token(db, "t1") == {:error, :not_found}
    assert SQLite.revoke_token(db, :any, "t2", :infinity) == :ok
    assert SQLite.revoke_token(db, :any, "t2", :infinity) == {:error, :not_found}
  end

  test "a removed user takes its tokens" do
    {:ok, db} = SQLite.open(path: nil)
    :ok = SQLite.add_user(db, user("a"), 64, :infinity)
    :ok = SQLite.add_token(db, token("t1", user("a").id), 16, :infinity)
    assert SQLite.remove_user(db, user("a").id, :infinity) == :ok
    assert SQLite.token(db, "t1") == {:error, :not_found}
    assert SQLite.remove_user(db, user("a").id, :infinity) == {:error, :not_found}
  end

  @tag :slow
  test "a second store on a held file in this node fails after the busy wait", %{tmp_dir: dir} do
    path = Path.join(dir, "hub.db")
    {:ok, db} = SQLite.open(path: path)
    assert SQLite.open(path: path) == {:error, :store_locked}
    :ok = SQLite.close(db)
    {:ok, db} = SQLite.open(path: path)
    :ok = SQLite.close(db)
  end

  # The open that loses waits the 5,000 ms of the open.
  @tag :slow
  test "two opens that wait for a lock: one takes it when the holder lets go", %{tmp_dir: dir} do
    path = Path.join(dir, "hub.db")
    {:ok, db} = SQLite.open(path: path)
    :ok = SQLite.close(db)

    # A writer of another program holds the file for a moment.
    {:ok, holder} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(holder, "BEGIN IMMEDIATE")
    opens = for _ <- 1..2, do: Task.async(fn -> SQLite.open(path: path) end)
    Process.sleep(200)
    :ok = Exqlite.Sqlite3.execute(holder, "ROLLBACK")
    :ok = Exqlite.Sqlite3.close(holder)

    results = Task.await_many(opens, 10_000)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)
    assert Enum.count(results, &(&1 == {:error, :store_locked})) == 1
    for {:ok, db} <- results, do: SQLite.close(db)
  end

  @tag :slow
  test "a file that another OS process holds fails the open", %{tmp_dir: dir} do
    path = Path.join(dir, "hub.db")

    # The holder is a second VM with the code paths of this one. It opens the
    # store, says so, and holds it until its stdin closes.
    paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])

    script =
      "{:ok, _} = Helyx.Hub.Store.SQLite.open(path: #{inspect(path)}); " <>
        "IO.puts(\"held\"); IO.read(:line)"

    elixir = System.find_executable("elixir")

    port =
      Port.open({:spawn_executable, elixir}, [
        :binary,
        :exit_status,
        args: paths ++ ["-e", script]
      ])

    held(port, "")

    assert SQLite.open(path: path) == {:error, :store_locked}

    Port.close(port)
  end

  # A POSIX lock of a file belongs to the OS process, so any open and close of
  # `hub.db` in this VM drops the lock that SQLite holds on it: the `read` tool
  # on the path is enough. The store's lock is an `flock` on another file,
  # which a close of a descriptor of the database does not drop.
  @tag :slow
  test "an open and close of the file in this VM does not drop the lock", %{tmp_dir: dir} do
    path = Path.join(dir, "hub.db")
    {:ok, db} = SQLite.open(path: path)

    File.close(File.open!(path, [:read, :binary]))

    assert open_elsewhere(path) == :store_locked

    :ok = SQLite.close(db)
    assert open_elsewhere(path) == :opened
  end

  # The store of a second OS process, which takes the lock of the path: its
  # answer is the one that a held file gives.
  defp open_elsewhere(path) do
    paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])

    script = """
    case Helyx.Hub.Store.SQLite.open(path: #{inspect(path)}) do
      {:ok, _store} -> IO.puts("opened")
      {:error, :store_locked} -> IO.puts("store_locked")
      other -> IO.puts(inspect(other))
    end
    """

    {out, 0} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
        stderr_to_stdout: true
      )

    case out |> String.split("\n", trim: true) |> List.last() do
      "opened" -> :opened
      "store_locked" -> :store_locked
    end
  end

  # The output of the holder can come in parts; it holds the lock once it says so.
  defp held(port, seen) do
    if seen =~ "held\n" do
      :ok
    else
      assert_receive {^port, {:data, data}}, 30_000
      held(port, seen <> data)
    end
  end

  describe "the row of a session of the feed" do
    defp record(session_id, owner, overrides \\ %{}) do
      Map.merge(
        %{
          session_id: session_id,
          owner: owner,
          cwd: "/w",
          model: "fake/echo",
          prompt: "",
          active_at: 10,
          created_at: 10
        },
        overrides
      )
    end

    test "seen_record inserts a default-owner row and moves model and active_at only" do
      {:ok, db} = SQLite.open(path: nil)
      :ok = SQLite.add_user(db, user("ann"), 64, :infinity)
      :ok = SQLite.add_user(db, user("bob"), 64, :infinity)
      ann = user("ann").id

      link = %{parent_id: "PARENTxxxxxx", parent_kind: "child"}
      first = Map.merge(record("SEENxxxxxxxx", ann), link)
      assert :ok = SQLite.seen_record(db, first, :infinity)

      assert {:ok, row} = SQLite.record(db, "SEENxxxxxxxx")
      assert %{owner: ^ann, cwd: "/w", model: "fake/echo", prompt: "", active_at: 10} = row
      assert row.created_at == 10
      assert %{parent_id: "PARENTxxxxxx", parent_kind: "child"} = row

      :ok = SQLite.update_record(db, "SEENxxxxxxxx", %{title: "mine", labels: ["l"]}, :infinity)

      moved =
        record("SEENxxxxxxxx", user("bob").id, %{model: "b/two", active_at: 20, created_at: 20})

      assert :ok = SQLite.seen_record(db, moved, :infinity)

      assert {:ok, row} = SQLite.record(db, "SEENxxxxxxxx")
      assert %{owner: ^ann, cwd: "/w", model: "b/two", prompt: "", active_at: 20} = row
      assert %{title: "mine", created_at: 10} = row
      # The parent of the row stays.
      assert %{parent_id: "PARENTxxxxxx", parent_kind: "child"} = row
      assert SQLite.labels(db, ["SEENxxxxxxxx"]) == {:ok, %{"SEENxxxxxxxx" => ["l"]}}
      :ok = SQLite.close(db)
    end

    test "the parent pair is set together: a child, a start with a thread, and neither" do
      {:ok, db} = SQLite.open(path: nil)
      :ok = SQLite.add_user(db, user("ann"), 64, :infinity)
      ann = user("ann").id
      %{db: connection} = db

      child =
        Map.merge(record("CHILDxxxxxxx", ann), %{parent_id: "PARENTxxxxxx", parent_kind: "child"})

      :ok = SQLite.seen_record(db, child, :infinity)

      assert {:ok, %{parent_id: "PARENTxxxxxx", parent_kind: "child"}} =
               SQLite.record(db, "CHILDxxxxxxx")

      thread =
        Map.merge(record("THREADxxxxxx", ann), %{parent_id: "SESSIONxxxxx", parent_kind: "thread"})

      :ok = SQLite.put_record(db, thread, 10_000, :infinity)

      assert {:ok, %{parent_id: "SESSIONxxxxx", parent_kind: "thread"}} =
               SQLite.record(db, "THREADxxxxxx")

      plain = record("PLAINxxxxxxx", ann)
      :ok = SQLite.seen_record(db, plain, :infinity)
      assert {:ok, %{parent_id: nil, parent_kind: nil}} = SQLite.record(db, "PLAINxxxxxxx")

      # The schema refuses a pair of one: the store code never writes one.
      assert {:error, _} =
               Exqlite.Sqlite3.execute(
                 connection,
                 "INSERT INTO records (session_id, owner, cwd, model, active_at, created_at, " <>
                   "updated_at, parent_id) VALUES ('HALFxxxxxxxx', '#{ann}', '/w', 'fake/echo', " <>
                   "1, 1, 1, 'PARENTxxxxxx')"
               )

      :ok = SQLite.close(db)
    end

    test "ensure_records inserts the rows that are missing and changes no row that exists" do
      {:ok, db} = SQLite.open(path: nil)
      :ok = SQLite.add_user(db, user("ann"), 64, :infinity)
      ann = user("ann").id
      a = record("Axxxxxxxxxxx", ann, %{cwd: "/a", prompt: "pa"})
      b = record("Bxxxxxxxxxxx", ann, %{cwd: "/b", prompt: "pb", active_at: 20, created_at: 20})

      assert :ok = SQLite.ensure_records(db, [a], :infinity)
      :ok = SQLite.update_record(db, "Axxxxxxxxxxx", %{title: "t"}, :infinity)

      changed = %{a | prompt: "other", model: "b/two", active_at: 99}
      assert :ok = SQLite.ensure_records(db, [changed, b], :infinity)

      assert {:ok, row} = SQLite.record(db, "Axxxxxxxxxxx")
      assert %{prompt: "pa", model: "fake/echo", active_at: 10, title: "t"} = row
      assert {:ok, %{prompt: "pb", active_at: 20, cwd: "/b"}} = SQLite.record(db, "Bxxxxxxxxxxx")
      :ok = SQLite.close(db)
    end

    test "put_record after the feed row of the same start sets the owner of the start" do
      {:ok, db} = SQLite.open(path: nil)
      :ok = SQLite.add_user(db, user("ann"), 64, :infinity)
      :ok = SQLite.add_user(db, user("own"), 64, :infinity)
      ann = user("ann").id
      owner = user("own").id

      # The feed row of the start comes first.
      assert :ok = SQLite.seen_record(db, record("RACExxxxxxxx", owner), :infinity)
      start = record("RACExxxxxxxx", ann, %{active_at: 20, created_at: 20})
      assert :ok = SQLite.put_record(db, start, 10_000, :infinity)

      assert {:ok, %{owner: ^ann, cwd: "/w", model: "fake/echo"}} =
               SQLite.record(db, "RACExxxxxxxx")

      :ok = SQLite.close(db)
    end
  end
end
