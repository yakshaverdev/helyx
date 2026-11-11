defmodule Helyx.Hub.Store.SQLite do
  @moduledoc """
  The SQLite store of `Helyx.Hub` (`docs/features/hub.md`, decision 9 and
  "Store schema"), with `exqlite`.

  A file store holds the SQLite write lock from its open to its close
  (`locking_mode = EXCLUSIVE`), so a second store on the file, in this node
  or in another OS process, fails its open with `{:error, :store_locked}`
  when it has not taken the lock 5,000 ms after the start of the open; of
  several opens at once, one takes it. The file and the WAL, SHM, and journal
  files beside it have mode 0600; each is a regular file with one name or
  nothing, else the open gives `{:error, {:invalid_option, :path}}`. The
  journal is WAL. With no `:path` the store is a database in memory that ends with its
  connection.
  """

  @behaviour Helyx.Hub.Store

  import Helyx.Hub.Store.SQLite.Query

  alias Exqlite.Sqlite3
  alias Helyx.Hub.Store.SQLite.{Disk, Projects, Records, Schedules, Schema, Subscriptions, Tables}

  @version Schema.version()

  @users Tables.select_sql(:users)
  @tokens Tables.select_sql(:tokens)

  # The busy wait of every query, and the time an open tries the lock (Bounds).
  @busy_ms 5_000
  # The longest pause between two tries of the lock at the open.
  @lock_pause_ms 20

  @impl true
  def open(opts) do
    case Keyword.get(opts, :path) do
      nil -> open_memory()
      path -> open_file(path)
    end
  end

  defp open_memory do
    {:ok, db} = Sqlite3.open(":memory:")
    started(db, [&settings/1, &schema/1])
  end

  # The order of decision 9: every name is checked before any change, a
  # missing file is made, the lock is taken with no write, the file and its
  # version are checked again under the lock, and only then does the store
  # set the modes and write. So a refused start writes nothing.
  defp open_file(path) do
    deadline = System.monotonic_time(:millisecond) + @busy_ms

    with :ok <- prepare(path),
         {:ok, db} <- locked_open(path, deadline) do
      started(db, [
        &settings/1,
        &version/1,
        fn _db -> Disk.own(path) end,
        &exec(&1, "PRAGMA journal_mode = WAL"),
        &schema/1
      ])
    end
  end

  defp prepare(path) do
    case Disk.check(path) do
      :missing -> Disk.create(path)
      other -> other
    end
  end

  # The lock of the file, within the busy wait of the open. Each try takes
  # it with no wait on a new connection, and a try that fails closes its
  # connection: in the exclusive locking mode a connection keeps the shared
  # lock of a failed try until it closes, so two starts that waited in one
  # connection each would hold the other off to the end of the wait. A
  # random pause between tries lets one start take the lock alone.
  defp locked_open(path, deadline) do
    case Sqlite3.open(path, mode: :readwrite) do
      {:ok, db} ->
        case lock(db) do
          :ok -> {:ok, db}
          error -> retry(path, deadline, db, error)
        end

      {:error, _} ->
        {:error, {:invalid_option, :path}}
    end
  end

  defp retry(path, deadline, db, error) do
    :ok = Sqlite3.close(db)

    cond do
      error != {:error, :busy} ->
        error

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(:rand.uniform(@lock_pause_ms))
        locked_open(path, deadline)

      true ->
        {:error, :store_locked}
    end
  end

  defp started(db, steps) do
    case Enum.reduce_while(steps, :ok, &step(&1, &2, db)) do
      :ok ->
        {:ok, db}

      {:error, _} = error ->
        :ok = Sqlite3.close(db)
        error
    end
  end

  defp step(fun, :ok, db) do
    case fun.(db) do
      :ok -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp settings(db) do
    with :ok <- Sqlite3.set_busy_timeout(db, @busy_ms), do: exec(db, "PRAGMA foreign_keys = ON")
  end

  # The write lock taken here stays until the connection closes. The
  # rollback writes nothing: a commit would write the first page of an empty
  # file. `{:error, :busy}` when another connection holds a lock of the file.
  defp lock(db) do
    with :ok <- Sqlite3.set_busy_timeout(db, 0),
         :ok <- exec(db, "PRAGMA locking_mode = EXCLUSIVE"),
         :ok <- exec(db, "BEGIN EXCLUSIVE") do
      exec(db, "ROLLBACK")
    end
  end

  defp version(db) do
    case one(db, "PRAGMA user_version", []) do
      {:ok, [@version]} -> :ok
      {:ok, [0]} -> empty(db)
      {:ok, [n]} -> {:error, {:store_version, n}}
      {:error, _} = error -> error
    end
  end

  # A file of version 0 is new only when it holds no schema: a database of
  # another program is refused before the store changes it.
  defp empty(db) do
    case one(db, "SELECT count(*) FROM sqlite_schema", []) do
      {:ok, [0]} -> :ok
      {:ok, [_]} -> {:error, {:store_version, 0}}
      {:error, _} = error -> error
    end
  end

  defp schema(db) do
    case one(db, "PRAGMA user_version", []) do
      {:ok, [@version]} -> :ok
      {:ok, [0]} -> transaction(db, :infinity, fn -> create_schema(db) end)
      {:error, _} = error -> error
    end
  end

  defp create_schema(db) do
    with :ok <- exec(db, Schema.sql()), do: exec(db, "PRAGMA user_version = #{@version}")
  end

  @impl true
  def close(db) do
    :ok = Sqlite3.close(db)
  end

  @impl true
  def users(db) do
    with {:ok, rows} <- all(db, @users <> " ORDER BY name", []) do
      {:ok, Enum.map(rows, &Tables.row(:users, &1))}
    end
  end

  @impl true
  def user(db, user_id) do
    case one(db, @users <> " WHERE id = ?1", [user_id]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> {:ok, Tables.row(:users, row)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def add_user(db, %{id: id, name: name, created_at: at}, max, deadline) do
    sql = "SELECT count(*), count(*) FILTER (WHERE name = ?1) FROM users"

    transaction(db, deadline, fn ->
      with {:ok, [count, taken]} <- one(db, sql, [name]),
           do: insert_user(db, [id, name, at], count >= max, taken > 0)
    end)
  end

  defp insert_user(_db, _row, true = _full, _taken), do: {:error, :too_many_users}
  defp insert_user(_db, _row, false, true = _taken), do: {:error, :name_taken}

  defp insert_user(db, row, false, false), do: run(db, Tables.insert(:users), row)

  @impl true
  def remove_user(db, user_id, deadline) do
    delete(db, deadline, "DELETE FROM users WHERE id = ?1", [user_id])
  end

  @impl true
  def token(db, token_id) do
    case one(db, @tokens <> " WHERE id = ?1", [token_id]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> {:ok, Tables.row(:tokens, row)}
      {:error, _} = error -> error
    end
  end

  # The listing of a user's tokens leaves the key in the store: no listing
  # carries it (decision 2).
  @impl true
  def tokens(db, user_id) do
    sql = @tokens <> " WHERE user_id = ?1 ORDER BY created_at, rowid"

    with {:ok, rows} <- all(db, sql, [user_id]) do
      {:ok, Enum.map(rows, &Map.delete(Tables.row(:tokens, &1), :key))}
    end
  end

  @impl true
  def add_token(db, token, max, deadline) do
    sql =
      "SELECT (SELECT count(*) FROM users WHERE id = ?1), " <>
        "(SELECT count(*) FROM tokens WHERE user_id = ?1)"

    transaction(db, deadline, fn ->
      with {:ok, [user, count]} <- one(db, sql, [token.user_id]),
           do: checked_token(db, token, user > 0, count >= max)
    end)
  end

  defp checked_token(_db, _token, false = _user?, _full), do: {:error, :unknown_user}
  defp checked_token(_db, _token, true, true = _full), do: {:error, :too_many_tokens}
  defp checked_token(db, token, true, false), do: insert_token(db, token)

  defp insert_token(db, t),
    do: run(db, Tables.insert(:tokens), [t.id, t.user_id, t.name, {:blob, t.key}, t.created_at])

  @impl true
  def revoke_token(db, :any, token_id, deadline),
    do: delete(db, deadline, "DELETE FROM tokens WHERE id = ?1", [token_id])

  def revoke_token(db, user_id, token_id, deadline),
    do:
      delete(db, deadline, "DELETE FROM tokens WHERE id = ?1 AND user_id = ?2", [
        token_id,
        user_id
      ])

  @impl true
  defdelegate record(db, session_id), to: Records
  @impl true
  defdelegate records(db, session_ids), to: Records
  @impl true
  defdelegate count_records(db, owner), to: Records
  @impl true
  defdelegate put_record(db, record, max, deadline), to: Records
  @impl true
  defdelegate touch_record(db, session_id, at, prompt, deadline), to: Records
  @impl true
  defdelegate labels(db, session_ids), to: Records
  @impl true
  defdelegate update_record(db, session_id, new, changes, max, deadline), to: Records
  @impl true
  defdelegate delete_record(db, session_id, deadline), to: Records
  @impl true
  defdelegate search(db, user, filters), to: Records
  @impl true
  defdelegate projects(db, owner), to: Projects
  @impl true
  defdelegate project(db, owner, project_id), to: Projects
  @impl true
  defdelegate put_project(db, project, max, deadline), to: Projects
  @impl true
  defdelegate rename_project(db, owner, project_id, name, deadline), to: Projects
  @impl true
  defdelegate delete_project(db, owner, project_id, deadline), to: Projects
  @impl true
  defdelegate saved(db, user, cwd, cursor, limit), to: Records
  @impl true
  defdelegate newest(db, owner, cwd), to: Records
  @impl true
  defdelegate hub_records?(db, owner), to: Records
  @impl true
  defdelegate schedules(db, owner, session_id), to: Schedules
  @impl true
  defdelegate schedule(db, id), to: Schedules
  @impl true
  defdelegate put_schedule(db, schedule, per_session, per_user, deadline), to: Schedules
  @impl true
  defdelegate delete_schedule(db, owner, id, deadline), to: Schedules
  @impl true
  defdelegate due(db, now, limit), to: Schedules
  @impl true
  defdelegate update_schedule(db, id, expect, changes, deadline), to: Schedules
  @impl true
  defdelegate put_delivery(db, row, per_pending, per_hour, window_s, now, deadline), to: Schedules
  @impl true
  defdelegate put_subscription(db, row, per_session, per_user, deadline), to: Subscriptions
  @impl true
  defdelegate subscriptions(db, owner, session_id), to: Subscriptions
  @impl true
  defdelegate subscription(db, id), to: Subscriptions
  @impl true
  defdelegate delete_subscription(db, owner, id, deadline), to: Subscriptions
  @impl true
  defdelegate subscription_sent(db, id, at, outcome, deadline), to: Subscriptions
end
