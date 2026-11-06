defmodule Helyx.Hub.Store.SQLite do
  @moduledoc """
  The SQLite store of `Helyx.Hub` (`docs/features/hub.md`, decision 9 and
  "Store schema"), with `exqlite`.

  A file store holds the SQLite write lock from its open to its close
  (`locking_mode = EXCLUSIVE`), so a second store on the file, in this node
  or in another OS process, fails its open with `{:error, :store_locked}`
  after the busy wait of 5,000 ms. The file and the WAL, SHM, and journal
  files beside it have mode 0600; each is a regular file with one name or
  nothing, else the open gives `{:error, {:invalid_option, :path}}`. The
  journal is WAL. With no `:path` the store is a database in memory that ends with its
  connection.
  """

  @behaviour Helyx.Hub.Store

  alias Exqlite.Sqlite3
  alias Helyx.Hub.Store.SQLite.Disk

  @version 1
  # The busy wait of every query and of the lock at the open (Bounds).
  @busy_ms 5_000

  @schema """
  CREATE TABLE users (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL
  ) STRICT;

  CREATE TABLE tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    key BLOB NOT NULL,
    created_at INTEGER NOT NULL
  ) STRICT;
  CREATE INDEX tokens_user ON tokens (user_id);

  CREATE TABLE projects (
    id TEXT PRIMARY KEY,
    owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    UNIQUE (owner, name)
  ) STRICT;

  CREATE TABLE records (
    session_id TEXT PRIMARY KEY,
    owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
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
  CREATE INDEX records_owner ON records (owner, updated_at);
  CREATE INDEX records_visibility ON records (visibility, updated_at);
  CREATE INDEX records_owner_active ON records (owner, cwd, active_at);
  CREATE INDEX records_visibility_active ON records (visibility, cwd, active_at);

  CREATE TABLE labels (
    session_id TEXT NOT NULL REFERENCES records(session_id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    PRIMARY KEY (session_id, label)
  ) STRICT;

  CREATE TABLE schedules (
    id TEXT PRIMARY KEY,
    owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_id TEXT NOT NULL,
    prompt TEXT NOT NULL,
    at INTEGER NOT NULL,
    every INTEGER,
    run INTEGER NOT NULL DEFAULT 0,
    delivery_id TEXT,
    due_at INTEGER,
    next_try_at INTEGER,
    last_at INTEGER,
    last_outcome TEXT CHECK (last_outcome IN ('delivered', 'missed', 'refused', 'unconfirmed')),
    created_at INTEGER NOT NULL
  ) STRICT;
  CREATE INDEX schedules_at ON schedules (at);
  CREATE INDEX schedules_next_try ON schedules (next_try_at);
  CREATE INDEX schedules_session ON schedules (session_id);
  """

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
    with {:ok, db} <- prepare(path) do
      started(db, [
        &settings/1,
        &lock/1,
        &version/1,
        fn _db -> Disk.own(path) end,
        &exec(&1, "PRAGMA journal_mode = WAL"),
        &schema/1
      ])
    end
  end

  defp prepare(path) do
    created =
      case Disk.check(path) do
        :missing -> Disk.create(path)
        other -> other
      end

    with :ok <- created do
      case Sqlite3.open(path, mode: :readwrite) do
        {:ok, db} -> {:ok, db}
        {:error, _} -> {:error, {:invalid_option, :path}}
      end
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
  # file.
  defp lock(db) do
    with :ok <- exec(db, "PRAGMA locking_mode = EXCLUSIVE"),
         :ok <- locked(exec(db, "BEGIN EXCLUSIVE")) do
      exec(db, "ROLLBACK")
    end
  end

  defp locked({:error, :busy}), do: {:error, :store_locked}
  defp locked(other), do: other

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
    with :ok <- exec(db, @schema), do: exec(db, "PRAGMA user_version = #{@version}")
  end

  @impl true
  def close(db) do
    :ok = Sqlite3.close(db)
  end

  @impl true
  def users(db) do
    with {:ok, rows} <- all(db, "SELECT id, name, created_at FROM users ORDER BY name", []) do
      {:ok, Enum.map(rows, &info/1)}
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

  defp insert_user(db, row, false, false),
    do: run(db, "INSERT INTO users (id, name, created_at) VALUES (?1, ?2, ?3)", row)

  @impl true
  def remove_user(db, user_id, deadline) do
    delete(db, deadline, "DELETE FROM users WHERE id = ?1", [user_id])
  end

  @impl true
  def token(db, token_id) do
    sql = "SELECT id, user_id, name, key, created_at FROM tokens WHERE id = ?1"

    case one(db, sql, [token_id]) do
      {:ok, [id, user_id, name, key, at]} ->
        {:ok, %{id: id, user_id: user_id, name: name, key: key, created_at: at}}

      {:ok, nil} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def tokens(db, user_id) do
    sql = "SELECT id, name, created_at FROM tokens WHERE user_id = ?1 ORDER BY created_at, rowid"

    with {:ok, rows} <- all(db, sql, [user_id]) do
      {:ok, Enum.map(rows, &info/1)}
    end
  end

  defp info([id, name, at]), do: %{id: id, name: name, created_at: at}

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

  defp insert_token(db, t) do
    run(
      db,
      "INSERT INTO tokens (id, user_id, name, key, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
      [t.id, t.user_id, t.name, {:blob, t.key}, t.created_at]
    )
  end

  @impl true
  def revoke_token(db, :any, token_id, deadline),
    do: delete(db, deadline, "DELETE FROM tokens WHERE id = ?1", [token_id])

  def revoke_token(db, user_id, token_id, deadline),
    do:
      delete(db, deadline, "DELETE FROM tokens WHERE id = ?1 AND user_id = ?2", [
        token_id,
        user_id
      ])

  # A delete and its count of rows in one step; no row is :not_found.
  defp delete(db, deadline, sql, args) do
    transaction(db, deadline, fn ->
      with :ok <- run(db, sql, args), do: changed(db)
    end)
  end

  defp changed(db) do
    case Sqlite3.changes(db) do
      {:ok, 0} -> {:error, :not_found}
      {:ok, _} -> :ok
      {:error, _} -> {:error, :failed}
    end
  end

  # One step: the body and its writes commit together or not at all. Any
  # answer but :ok or {:ok, _} rolls back, and so does a body that ends at or
  # past the deadline of its Hub call, so its caller, which waits the
  # deadline and a margin, gets the answer of every write that committed.
  defp transaction(db, deadline, body) do
    case exec(db, "BEGIN IMMEDIATE") do
      :ok -> finish(db, deadline, body.())
      {:error, _} -> {:error, :failed}
    end
  end

  defp finish(db, deadline, :ok), do: commit(db, deadline, :ok)
  defp finish(db, deadline, {:ok, _} = result), do: commit(db, deadline, result)
  defp finish(db, _deadline, result), do: rollback(db, result)

  defp commit(db, deadline, result) do
    if deadline != :infinity and System.monotonic_time(:millisecond) >= deadline do
      rollback(db, {:error, :timeout})
    else
      case exec(db, "COMMIT") do
        :ok -> result
        {:error, _} -> rollback(db, {:error, :failed})
      end
    end
  end

  defp rollback(db, result) do
    _ = exec(db, "ROLLBACK")
    result
  end

  defp exec(db, sql) do
    case Sqlite3.execute(db, sql) do
      :ok -> :ok
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp run(db, sql, args) do
    with {:ok, _} <- all(db, sql, args), do: :ok
  end

  defp one(db, sql, args) do
    with {:ok, rows} <- all(db, sql, args), do: {:ok, List.first(rows)}
  end

  defp all(db, sql, args) do
    case Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        try do
          with :ok <- Sqlite3.bind(stmt, args),
               {:ok, _rows} = ok <- Sqlite3.fetch_all(db, stmt) do
            ok
          else
            {:error, reason} -> {:error, error(reason)}
          end
        after
          Sqlite3.release(db, stmt)
        end

      {:error, reason} ->
        {:error, error(reason)}
    end
  end

  # SQLite names a held lock "database is locked"; the rest is a failed query.
  defp error("database is locked" <> _), do: :busy
  defp error(_), do: :failed
end
