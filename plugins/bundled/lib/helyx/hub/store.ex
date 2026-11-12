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
  `parent_id` is the session of the parent link and `parent_kind` is
  `"child"` or `"thread"`, both nil for a session with no link.
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
          updated_at: integer(),
          parent_id: String.t() | nil,
          parent_kind: String.t() | nil
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
  `active_at`, `created_at`, and the optional parent link, unless its owner
  holds `max` rows; `:none` means no cap, for the rows of the default owner.
  The row of the id that a session start already wrote through the feed takes
  the owner, the session facts, and a parent link of this start; a start with
  no link keeps the parent of that row.
  """
  @callback put_record(t(), record :: map(), max :: pos_integer() | :none, deadline()) ::
              :ok | {:error, :too_many_records | :timeout | :failed}

  @doc """
  Writes the row that a `Helyx.Sessions.Live` of the feed names: inserts a
  row of the default owner, with the parent link of the session, or, for a
  session that has one, sets its `model` and `active_at`. The owner, title,
  labels, project, prompt, `created_at`, and parent of an existing row stay.
  A row of the default owner has no cap: the session files bound it (hub.md,
  decision 8).
  """
  @callback seen_record(t(), record :: map(), deadline()) ::
              :ok | {:error, :busy | :failed | :timeout}

  @doc """
  Inserts each row that a session with no row names, with its parent link,
  and changes no existing row: at most 256 rows, the bound of the caller
  (hub.md, decision 8).
  """
  @callback ensure_records(t(), [record :: map()], deadline()) ::
              :ok | {:error, :busy | :failed | :timeout}

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
  In one step: applies `changes` (`:title`, `:visibility`, `:archived`,
  `:project_id`, `:labels`) to the row of a session and sets `updated_at`. A
  project that the owner of the row does not own answers `:unknown_project`;
  a session with no row answers `:not_found`.
  """
  @callback update_record(t(), String.t(), changes :: map(), deadline()) ::
              :ok
              | {:error, :not_found | :unknown_project | :timeout | :failed}

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

  @doc "Whether `owner` owns a \"hub\" record."
  @callback hub_records?(t(), owner :: String.t()) :: {:ok, boolean()} | {:error, :failed}

  @doc """
  The rows that `owner` owns, newest `active_at` first, then by session id,
  at most `limit` (`docs/features/live-records.md`).
  """
  @callback owned(t(), owner :: String.t(), limit :: pos_integer()) ::
              {:ok, [record()]} | {:error, :failed}

  @doc "The rows of `session_ids`, at most 256 ids (the feed of a user)."
  @callback rows(t(), session_ids :: [String.t()]) ::
              {:ok, [record()]} | {:error, :failed}

  @typedoc """
  A schedule row (`docs/features/hub.md`, decisions 11 and 12, "Store
  schema"). `delivery_id`, `due_at`, and `next_try_at` are nil when the row
  holds no pending wake-up. `subscription_id` is nil for a schedule and the
  id of its event subscription for the one-run delivery of a webhook
  (decision 17).
  """
  @type schedule :: %{
          id: String.t(),
          owner: String.t(),
          session_id: String.t(),
          prompt: String.t(),
          at: integer(),
          every: pos_integer() | nil,
          run: non_neg_integer(),
          delivery_id: String.t() | nil,
          due_at: integer() | nil,
          next_try_at: integer() | nil,
          last_at: integer() | nil,
          last_outcome: String.t() | nil,
          created_at: integer(),
          subscription_id: String.t() | nil
        }

  @doc "The schedules of `owner`, of the session `session_id` or of all when nil, oldest first."
  @callback schedules(t(), owner :: String.t(), session_id :: String.t() | nil) ::
              {:ok, [schedule()]} | {:error, :failed}

  @doc "The schedule row of `id`."
  @callback schedule(t(), id :: String.t()) :: {:ok, schedule()} | {:error, :not_found | :failed}

  @doc """
  Inserts a schedule unless its session holds `per_session` rows or its
  owner `per_user` rows.
  """
  @callback put_schedule(
              t(),
              schedule(),
              per_session :: pos_integer(),
              per_user :: pos_integer(),
              deadline()
            ) :: :ok | {:error, :too_many_schedules | :timeout | :failed}

  @doc "Deletes a schedule of `owner`; one of another user answers `:not_found`, as a missing one."
  @callback delete_schedule(t(), owner :: String.t(), id :: String.t(), deadline()) ::
              :ok | {:error, :not_found | :timeout | :failed}

  @doc "The rows whose `next_try_at` is at or before `now`, oldest first, at most `limit`."
  @callback due(t(), now :: integer(), limit :: pos_integer()) ::
              {:ok, [schedule()]} | {:error, :failed}

  @doc """
  Sets `changes` on the row `id` only while it holds every value of
  `expect`; both name only the columns of the pending wake-up and the last
  outcome (`at`, `run`, `delivery_id`, `due_at`, `next_try_at`, `last_at`,
  `last_outcome`). A row that does not hold them, or is gone, answers
  `:stale`.
  """
  @callback update_schedule(t(), id :: String.t(), expect :: map(), changes :: map(), deadline()) ::
              :ok | {:error, :stale | :timeout | :failed}

  @typedoc """
  An event subscription row (`docs/features/hub.md`, decision 17, "Store
  schema"). `secret` is the 43-character base64url text of 32 random bytes; it leaves
  the Hub process only into the webhook endpoint, which computes the HMAC of
  a payload with it. `pending` is
  derived: whether the subscription holds a pending delivery.
  """
  @type subscription :: %{
          id: String.t(),
          owner: String.t(),
          session_id: String.t(),
          template: String.t(),
          label: String.t(),
          secret: binary(),
          created_at: integer(),
          last_at: integer() | nil,
          last_outcome: String.t() | nil,
          pending: boolean()
        }

  @doc """
  Inserts a subscription unless its session holds `per_session` rows or its
  owner `per_user` rows.
  """
  @callback put_subscription(
              t(),
              subscription(),
              per_session :: pos_integer(),
              per_user :: pos_integer(),
              deadline()
            ) ::
              :ok | {:error, :too_many_event_subscriptions | :timeout | :failed}

  @doc "The subscriptions of `owner`, of one session or all, oldest first."
  @callback subscriptions(t(), owner :: String.t(), session_id :: String.t() | nil) ::
              {:ok, [subscription()]} | {:error, :failed}

  @doc "The subscription row of `id`, whoever owns it (the webhook endpoint)."
  @callback subscription(t(), id :: String.t()) ::
              {:ok, subscription()} | {:error, :not_found | :failed}

  @doc "Deletes a subscription of `owner` with its deliveries."
  @callback delete_subscription(t(), owner :: String.t(), id :: String.t(), deadline()) ::
              :ok | {:error, :not_found | :timeout | :failed}

  @doc """
  Sets the delivery state of a subscription (`last_at` and `last_outcome`)
  from the outcome of its delivery. A subscription that is gone is left as
  it is.
  """
  @callback subscription_sent(
              t(),
              id :: String.t(),
              at :: integer(),
              outcome :: String.t() | nil,
              deadline()
            ) :: :ok | {:error, :timeout | :failed}

  @doc """
  Inserts the one-run delivery of a webhook (`schedules` row with a
  `subscription_id`) unless its subscription holds `per_pending` pending
  deliveries, or accepted `per_hour` in the `window_s` seconds that end at
  `now`. An ended delivery older than twice the window is pruned in the same
  step, so the rows of a subscription stay bounded.
  """
  @callback put_delivery(
              t(),
              schedule(),
              per_pending :: pos_integer(),
              per_hour :: pos_integer(),
              window_s :: pos_integer(),
              now :: integer(),
              deadline()
            ) ::
              :ok | {:error, :too_many_pending | :rate_limited | :timeout | :failed}

  @typedoc """
  A paired peer of the public listener (`docs/features/remote-hands.md`,
  "Peers"). `public_key` is the 32-byte Ed25519 public key; the store keeps
  no secret of a peer.
  """
  @type peer :: %{
          name: String.t(),
          kind: String.t(),
          public_key: binary(),
          created_at: integer()
        }

  @doc """
  Inserts a peer, or replaces the key of the row of its kind and name,
  unless the store holds `max` peers and the name is new.
  """
  @callback put_peer(t(), peer(), max :: pos_integer(), deadline()) ::
              :ok | {:error, :too_many_peers | :timeout | :failed}

  @doc "The peer row of a kind and a name."
  @callback peer(t(), kind :: String.t(), name :: String.t()) ::
              {:ok, peer()} | {:error, :not_found | :failed}

  @doc "Deletes a peer."
  @callback delete_peer(t(), kind :: String.t(), name :: String.t(), deadline()) ::
              :ok | {:error, :not_found | :timeout | :failed}

  @doc "Every peer, by kind and name."
  @callback peers(t()) :: {:ok, [peer()]} | {:error, :failed}
end
