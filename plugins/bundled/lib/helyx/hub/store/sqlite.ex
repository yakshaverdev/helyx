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
    path = Keyword.get(opts, :path)

    with :ok <- prepare_file(path),
         {:ok, db} <- Sqlite3.open(path || ":memory:") do
      case setup(db, path) do
        :ok ->
          {:ok, db}

        {:error, _} = error ->
          :ok = Sqlite3.close(db)
          error
      end
    end
  end

  # The path and the files that SQLite keeps beside it are each a regular
  # file with one name, or nothing: a link could put a file in a folder that
  # others can write, and a chmod through it would change its target. A new
  # file is made in a folder of mode 0700, set to 0600 there, and linked into
  # place, which fails when the name exists, so no other user can open it
  # while it has the mode of the umask, and no start replaces a file that
  # another store holds. SQLite gives a new WAL file the mode of the database.
  @sidecars ["-wal", "-shm", "-journal"]

  defp prepare_file(nil), do: :ok

  defp prepare_file(path) do
    main = with :missing <- private_file(path), do: create(path)
    with :ok <- main, do: sidecars(path)
  end

  defp sidecars(path) do
    Enum.reduce_while(@sidecars, :ok, fn suffix, :ok ->
      case private_file(path <> suffix) do
        {:error, _} = error -> {:halt, error}
        _ok_or_missing -> {:cont, :ok}
      end
    end)
  end

  # :ok when the file is a regular file with one name, now of mode 0600.
  defp private_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1}} -> chmod(path)
      {:error, :enoent} -> :missing
      _ -> {:error, {:invalid_option, :path}}
    end
  end

  defp create(path) do
    private =
      Path.join(Path.dirname(path), ".hub-" <> Base.url_encode64(:crypto.strong_rand_bytes(9)))

    file = Path.join(private, "hub.db")

    try do
      with :ok <- File.mkdir(private),
           :ok <- File.chmod(private, 0o700),
           :ok <- File.touch(file),
           :ok <- File.chmod(file, 0o600) do
        link(file, path)
      else
        _ -> {:error, {:invalid_option, :path}}
      end
    after
      File.rm_rf(private)
    end
  end

  # A file that came at the path after the lstat is the file of a store that
  # starts at the same moment.
  defp link(file, path) do
    case File.ln(file, path) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :store_locked}
      {:error, _} -> {:error, {:invalid_option, :path}}
    end
  end

  defp chmod(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, _} -> {:error, {:invalid_option, :path}}
    end
  end

  defp setup(db, path) do
    with :ok <- Sqlite3.set_busy_timeout(db, @busy_ms),
         :ok <- exec(db, "PRAGMA foreign_keys = ON"),
         :ok <- lock(db, path) do
      schema(db)
    end
  end

  # The write lock taken here stays until the connection closes.
  defp lock(_db, nil), do: :ok

  defp lock(db, _path) do
    with :ok <- exec(db, "PRAGMA locking_mode = EXCLUSIVE"),
         :ok <- locked(exec(db, "PRAGMA journal_mode = WAL")),
         :ok <- locked(exec(db, "BEGIN EXCLUSIVE")) do
      exec(db, "COMMIT")
    end
  end

  defp locked({:error, :busy}), do: {:error, :store_locked}
  defp locked(other), do: other

  defp schema(db) do
    case one(db, "PRAGMA user_version", []) do
      {:ok, [@version]} -> :ok
      {:ok, [0]} -> transaction(db, fn -> create_schema(db) end)
      {:ok, [n]} -> {:error, {:store_version, n}}
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
  def add_user(db, %{id: id, name: name, created_at: at}, max) do
    sql = "SELECT count(*), count(*) FILTER (WHERE name = ?1) FROM users"

    transaction(db, fn ->
      with {:ok, [count, taken]} <- one(db, sql, [name]),
           do: insert_user(db, [id, name, at], count >= max, taken > 0)
    end)
  end

  defp insert_user(_db, _row, true = _full, _taken), do: {:error, :too_many_users}
  defp insert_user(_db, _row, false, true = _taken), do: {:error, :name_taken}

  defp insert_user(db, row, false, false),
    do: run(db, "INSERT INTO users (id, name, created_at) VALUES (?1, ?2, ?3)", row)

  @impl true
  def remove_user(db, user_id) do
    delete(db, "DELETE FROM users WHERE id = ?1", [user_id])
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
  def add_token(db, token, max) do
    sql =
      "SELECT (SELECT count(*) FROM users WHERE id = ?1), " <>
        "(SELECT count(*) FROM tokens WHERE user_id = ?1)"

    transaction(db, fn ->
      with {:ok, [user, count]} <- one(db, sql, [token.user_id]),
           do: add_token(db, token, user > 0, count >= max)
    end)
  end

  defp add_token(_db, _token, false = _user?, _full), do: {:error, :unknown_user}
  defp add_token(_db, _token, true, true = _full), do: {:error, :too_many_tokens}
  defp add_token(db, token, true, false), do: insert_token(db, token)

  defp insert_token(db, t) do
    run(
      db,
      "INSERT INTO tokens (id, user_id, name, key, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
      [t.id, t.user_id, t.name, {:blob, t.key}, t.created_at]
    )
  end

  @impl true
  def revoke_token(db, :any, token_id),
    do: delete(db, "DELETE FROM tokens WHERE id = ?1", [token_id])

  def revoke_token(db, user_id, token_id),
    do: delete(db, "DELETE FROM tokens WHERE id = ?1 AND user_id = ?2", [token_id, user_id])

  # A delete and its count of rows in one step; no row is :not_found.
  defp delete(db, sql, args) do
    transaction(db, fn ->
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
  # answer but :ok or {:ok, _} rolls back.
  defp transaction(db, body) do
    case exec(db, "BEGIN IMMEDIATE") do
      :ok -> finish(db, body.())
      {:error, _} -> {:error, :failed}
    end
  end

  defp finish(db, :ok), do: commit(db, :ok)
  defp finish(db, {:ok, _} = result), do: commit(db, result)
  defp finish(db, result), do: rollback(db, result)

  defp commit(db, result) do
    case exec(db, "COMMIT") do
      :ok -> result
      {:error, _} -> rollback(db, {:error, :failed})
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
