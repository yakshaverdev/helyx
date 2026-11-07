defmodule Helyx.Hub.Store do
  @moduledoc """
  The storage boundary of `Helyx.Hub` (ADR 0010 §4, `docs/features/hub.md`,
  decision 9). The Hub process is the only caller: every read and every
  write runs in it, so a cap check and its insert are one step.

  A query that the backend cannot run answers `{:error, :failed}`; the
  operation of the caller then answers `failed`.
  """

  @typedoc "The state of an open store."
  @type t :: term()

  @typedoc "A user row."
  @type user :: %{id: String.t(), name: String.t(), created_at: integer()}

  @typedoc """
  A token row. `key` is `SHA-256(token text)`; it leaves the Hub process
  only to the authority of the Hub, which computes the proof of a `hello`,
  and no frame carries it.
  """
  @type token :: %{
          id: String.t(),
          user_id: String.t(),
          name: String.t(),
          key: binary(),
          created_at: integer()
        }

  @typedoc """
  The deadline of a write, in `System.monotonic_time(:millisecond)`, or
  `:infinity`. A write that ends at or past it rolls back and answers
  `{:error, :timeout}`.
  """
  @type deadline :: integer() | :infinity

  @typedoc """
  A record row (`docs/features/hub.md`, "Store schema"). `prompt` is the
  first user text that Hub authorized, cut to 1,024 bytes, or `""`.
  """
  @type record :: %{
          session_id: String.t(),
          owner: String.t(),
          project_id: String.t() | nil,
          title: String.t(),
          cwd: String.t(),
          model: String.t(),
          prompt: String.t(),
          active_at: integer(),
          visibility: String.t(),
          archived: boolean(),
          created_at: integer(),
          updated_at: integer()
        }

  @typedoc "The access of a session that has a row."
  @type access :: %{owner: String.t(), visibility: String.t()}

  @typedoc "A token as a listing shows it: no key."
  @type token_info :: %{id: String.t(), name: String.t(), created_at: integer()}

  @doc """
  Opens the store. `:path` is the file, or nil for a store in memory. A
  file that another store holds gives `{:error, :store_locked}`; a file of
  another schema version `{:error, {:store_version, n}}`; a path that the
  store cannot own `{:error, {:invalid_option, :path}}`.
  """
  @callback open(opts :: keyword()) ::
              {:ok, t()} | {:error, :store_locked | {:store_version, integer()} | term()}

  @doc "Closes the store and frees its lock."
  @callback close(t()) :: :ok

  @doc "Every user, by name."
  @callback users(t()) :: {:ok, [user()]} | {:error, :failed}

  @doc "Inserts `user` unless the store holds `max` users or its name is taken."
  @callback add_user(t(), user(), max :: pos_integer(), deadline()) ::
              :ok | {:error, :too_many_users | :name_taken | :timeout | :failed}

  @doc "Deletes a user with its tokens and every row that it owns."
  @callback remove_user(t(), user_id :: String.t(), deadline()) ::
              :ok | {:error, :not_found | :timeout | :failed}

  @doc "The token row of `token_id`."
  @callback token(t(), token_id :: String.t()) :: {:ok, token()} | {:error, :not_found | :failed}

  @doc "The tokens of a user, oldest first."
  @callback tokens(t(), user_id :: String.t()) :: {:ok, [token_info()]} | {:error, :failed}

  @doc "Inserts `token` unless its user holds `max` tokens or does not exist."
  @callback add_token(t(), token(), max :: pos_integer(), deadline()) ::
              :ok | {:error, :too_many_tokens | :unknown_user | :timeout | :failed}

  @doc """
  Deletes a token. With a user id, only a token of that user goes; a token
  of another user answers `:not_found`, as a missing one.
  """
  @callback revoke_token(t(), user_id :: String.t() | :any, token_id :: String.t(), deadline()) ::
              :ok | {:error, :not_found | :timeout | :failed}

  @doc "The user of `user_id`."
  @callback user(t(), user_id :: String.t()) :: {:ok, user()} | {:error, :not_found | :failed}

  @doc "The record row of a session."
  @callback record(t(), session_id :: String.t()) ::
              {:ok, record()} | {:error, :not_found | :failed}

  @doc """
  The owner and visibility of each id of `session_ids` that has a row, at
  most 256 ids (the filter of a list).
  """
  @callback records(t(), session_ids :: [String.t()]) ::
              {:ok, %{String.t() => access()}} | {:error, :failed}

  @doc "The number of rows that `owner` owns."
  @callback count_records(t(), owner :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, :failed}

  @doc """
  Inserts a new row with `session_id`, `owner`, `cwd`, `model`, `prompt`,
  `active_at`, and `created_at`, unless its owner holds `max` rows.
  """
  @callback put_record(t(), record :: map(), max :: pos_integer(), deadline()) ::
              :ok | {:error, :too_many_records | :timeout | :failed}

  @doc """
  Sets `active_at` of the row of a session to `at`, and its `prompt` to
  `prompt` when the row has none; a session with no row is left as it is.
  """
  @callback touch_record(
              t(),
              session_id :: String.t(),
              at :: integer(),
              String.t() | nil,
              deadline()
            ) ::
              :ok | {:error, :timeout | :failed}

  @typedoc "A project as a listing shows it."
  @type project :: %{id: String.t(), name: String.t(), created_at: integer()}

  @doc "The labels of each id of `session_ids` that has some, at most 256 ids."
  @callback labels(t(), session_ids :: [String.t()]) ::
              {:ok, %{String.t() => [String.t()]}} | {:error, :failed}

  @doc """
  In one step: inserts `new` when it is not nil (a derived record that gets
  its row, within `max` rows of its owner), then applies `changes` (`:title`,
  `:visibility`, `:archived`, `:project_id`, `:labels`) and sets
  `updated_at`. A project that the owner of the row does not own answers
  `:unknown_project`.
  """
  @callback update_record(
              t(),
              String.t(),
              new :: map() | nil,
              changes :: map(),
              pos_integer(),
              deadline()
            ) ::
              :ok
              | {:error, :not_found | :too_many_records | :unknown_project | :timeout | :failed}

  @doc "Deletes the row of a session with its labels."
  @callback delete_record(t(), String.t(), deadline()) ::
              :ok | {:error, :not_found | :timeout | :failed}

  @doc """
  The stored records that `user` may read, newest `updated_at` first, then
  by session id, at most `limit` + 1. `filters`: `:limit`, and the optional
  `:mine`, `:query`, `:labels`, `:project_id`, `:archived`, and `:after`
  (`{updated_at, session_id}`).
  """
  @callback search(t(), user :: String.t(), filters :: map()) ::
              {:ok, [record()]} | {:error, :failed}

  @doc "The projects of `owner`, by name."
  @callback projects(t(), owner :: String.t()) :: {:ok, [project()]} | {:error, :failed}

  @doc "The project `project_id` when `owner` owns it."
  @callback project(t(), owner :: String.t(), project_id :: String.t()) ::
              {:ok, project()} | {:error, :not_found | :failed}

  @doc "Inserts a project unless its owner holds `max` or one of its name."
  @callback put_project(t(), project :: map(), pos_integer(), deadline()) ::
              :ok | {:error, :too_many_projects | :name_taken | :timeout | :failed}

  @doc "Renames a project of `owner`."
  @callback rename_project(t(), String.t(), String.t(), String.t(), deadline()) ::
              :ok | {:error, :not_found | :name_taken | :timeout | :failed}

  @doc "Deletes a project of `owner`; its records lose it."
  @callback delete_project(t(), String.t(), String.t(), deadline()) ::
              :ok | {:error, :not_found | :timeout | :failed}

  @doc """
  The stored records that `user` may read, of the folder `cwd` when not
  nil, newest `active_at` first, then by session id, both descending, after
  `cursor` (`{time, session_id}` or nil), at most `limit` (`sessions.saved`).
  """
  @callback saved(t(), String.t(), String.t() | nil, {integer(), String.t()} | nil, pos_integer()) ::
              {:ok, [record()]} | {:error, :failed}

  @doc "The newest record of the folder `cwd` that `owner` owns."
  @callback newest(t(), owner :: String.t(), cwd :: String.t()) ::
              {:ok, record()} | {:error, :not_found | :failed}
end
