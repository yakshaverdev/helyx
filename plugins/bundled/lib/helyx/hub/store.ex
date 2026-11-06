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

  @typedoc "A token row. `key` is `SHA-256(token text)`; it never leaves Hub."
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
end
