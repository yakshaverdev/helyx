defmodule Helyx.Hub.Store.SQLiteTest do
  use ExUnit.Case, async: true

  alias Helyx.Hub.Store.SQLite

  @moduletag :tmp_dir

  defp user(name),
    do: %{id: name <> String.duplicate("x", 12 - byte_size(name)), name: name, created_at: 1}

  defp token(id, user_id),
    do: %{id: id, user_id: user_id, name: "t", key: :crypto.hash(:sha256, id), created_at: 1}

  test "a new file gets mode 0600, schema version 2, and opens again after a close", %{
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
    :ok = Exqlite.Sqlite3.execute(db, "PRAGMA user_version = 3")
    :ok = Exqlite.Sqlite3.close(db)

    assert SQLite.open(path: path) == {:error, {:store_version, 3}}
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
end
