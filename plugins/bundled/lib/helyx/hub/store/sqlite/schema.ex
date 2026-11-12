defmodule Helyx.Hub.Store.SQLite.Schema do
  @moduledoc false
  # The schema of the SQLite store, `user_version` 4 (`docs/features/hub.md`,
  # "Store schema"). A file of version 2 gets the parent columns of a record
  # (decision 8) and the peers table of the public listener (protocol 14;
  # both kinds since protocol 15); a file of version 3 gets the peers table;
  # a file of another version is refused.

  # The event subscriptions of decision 17, in a new file.
  @subscriptions """
  CREATE TABLE subscriptions (
    id TEXT PRIMARY KEY,
    owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_id TEXT NOT NULL,
    template TEXT NOT NULL,
    label TEXT NOT NULL DEFAULT '',
    secret TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    last_at INTEGER,
    last_outcome TEXT CHECK (last_outcome IN ('delivered', 'missed', 'refused', 'unconfirmed'))
  ) STRICT;
  CREATE INDEX subscriptions_owner ON subscriptions (owner);
  CREATE INDEX subscriptions_session ON subscriptions (session_id);
  """

  # The peers of the public listener (protocol 14, both kinds since protocol
  # 15, `docs/features/remote-hands.md`, "Peers"), in a new file and in a file
  # of version 2 or 3.
  @peers """
  CREATE TABLE peers (
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('hands', 'client')),
    public_key BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (kind, name)
  ) STRICT;
  """

  @doc false
  def version, do: 4

  @doc "The SQL of the peers table, for a new file and for the upgrade."
  @spec peers_sql() :: String.t()
  def peers_sql, do: @peers

  @doc false
  def sql do
    """
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
      updated_at INTEGER NOT NULL,
      parent_id TEXT,
      parent_kind TEXT CHECK (parent_kind IN ('child', 'thread')),
      CHECK ((parent_id IS NULL) = (parent_kind IS NULL))
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

    #{@subscriptions}

    #{@peers}

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
      created_at INTEGER NOT NULL,
      subscription_id TEXT REFERENCES subscriptions(id) ON DELETE CASCADE
    ) STRICT;
    CREATE INDEX schedules_at ON schedules (at);
    CREATE INDEX schedules_next_try ON schedules (next_try_at);
    CREATE INDEX schedules_session ON schedules (session_id);
    CREATE INDEX schedules_subscription ON schedules (subscription_id);
    """
  end
end
