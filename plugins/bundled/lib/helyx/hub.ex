defmodule Helyx.Hub do
  @moduledoc """
  Users, credentials, and session records beside a Core and its transport
  (ADR 0010, `docs/features/hub.md`). A bundled module, not a plugin: a
  product starts it in its own tree, and Core never names it.

  Options of `start_link/1`: `:core` (required, the name of the Core),
  `:default_owner` (required, a user name; made at the start when the store
  does not hold it), `:server_token` (a 0-arity closure that returns the
  server token text), `:path` (the store file, default
  `<sessions_dir>/hub.db`, a store in memory for a Core with no data
  folder), `:store` (default `Helyx.Hub.Store.SQLite`),
  `:max_live_sessions` (1 to 64, default 64), and `:name`. A bad option, a
  `:core` that names no running Core, and a `:path` (or a WAL, SHM, or
  journal file beside it) that is not a regular file with one name or
  nothing give `{:error, {:invalid_option, key}}`, a store file that another Hub
  holds `{:error, :store_locked}`, and a folder of the file that its group
  or other users can write `{:error, :unsafe_folder}`.

  Every user and token function here is a Hub call: a call with a timeout of 5,000 ms,
  sent only while the mailbox of Hub holds fewer than 1,024 messages, else
  `{:error, :busy}` at once (decision 5). Hub drops a call that it takes at
  or past its deadline before it reads or writes, and rolls back a write
  that ends at or past it; the deadline is 4,000 ms after the send, and the
  caller waits it and a margin of 1,000 ms for the answer, so a caller that got a timeout gets no late
  change of state (a commit that takes longer than the margin is the hole,
  `docs/features/hub.md`, Accepted holes).
  """

  import Bitwise

  # The Hub call (decision 5): its timeout, and the mailbox length at which a
  # caller sends nothing.
  @call_ms 5_000
  # The wait of the caller past the deadline of the call, within @call_ms:
  # the answer of a write that committed just before the deadline still
  # comes within it.
  @commit_margin_ms 1_000
  @admission 1_024
  # The bound of a user or token name (Bounds).
  @max_name_bytes 64
  # The Core cap of live sessions, the default and the top of the option.
  @max_live 64
  # The stop of Hub (decision 16).
  @shutdown_ms 5_000

  @typedoc "A Hub: its pid or its registered name."
  @type hub :: GenServer.server()

  @typedoc "A user as the API shows it."
  @type user :: %{id: String.t(), name: String.t()}

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: @shutdown_ms
    }
  end

  @doc "Starts a Hub. See the moduledoc for the options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, config} <- options(opts) do
      gen_opts = if opts[:name], do: [name: opts[:name]], else: []
      GenServer.start_link(Helyx.Hub.Server, config, gen_opts)
    end
  end

  @doc """
  Makes a user. `name` is 1 to 64 bytes of UTF-8 with no control
  character, unique in the Hub; a Hub holds at most 64 users.
  """
  @spec add_user(hub(), String.t()) ::
          {:ok, user()} | {:error, :invalid_name | :too_many_users | :busy | :timeout | :failed}
  def add_user(hub, name) do
    if name?(name), do: call(hub, {:add_user, name}), else: {:error, :invalid_name}
  end

  @doc "Removes a user with its tokens and records. The default owner stays."
  @spec remove_user(hub(), String.t()) ::
          :ok | {:error, :unknown_user | :default_owner | :busy | :timeout | :failed}
  def remove_user(hub, user_id) when is_binary(user_id),
    do: call(hub, {:remove_user, user_id})

  @doc "Every user of the Hub, by name."
  @spec users(hub()) :: {:ok, [user()]} | {:error, :busy | :failed}
  def users(hub), do: call(hub, :users)

  @doc """
  Makes a token for a user and returns its text, `<token id>.<secret>`. This
  is the only return of the text: the store keeps `SHA-256(text)`. A user
  holds at most 16 tokens; `name` is 1 to 64 bytes of UTF-8 with no control
  character.
  """
  @spec create_token(hub(), String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error,
             :invalid_name | :unknown_user | :too_many_tokens | :busy | :timeout | :failed}
  def create_token(hub, user_id, name) when is_binary(user_id) do
    if name?(name),
      do: call(hub, {:create_token, user_id, name}),
      else: {:error, :invalid_name}
  end

  @doc "Revokes a token of any user."
  @spec revoke_token(hub(), String.t()) ::
          :ok | {:error, :unknown_token | :busy | :timeout | :failed}
  def revoke_token(hub, token_id) when is_binary(token_id),
    do: call(hub, {:revoke_token, token_id})

  @doc """
  The value of the option `:authority` of `Helyx.Transport.WebSocket` for
  this Hub (decision 5).
  """
  @spec authority(hub()) :: {module(), hub()}
  def authority(hub), do: {Helyx.Hub.Access, hub}

  # A Hub call (decision 5). No counter: the admission count is the mailbox.
  @doc false
  @spec call(hub(), term()) :: term()
  def call(hub, request) do
    pid = GenServer.whereis(hub) || exit({:noproc, {__MODULE__, :call, [hub, request]}})

    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} when n >= @admission ->
        {:error, :busy}

      _ ->
        deadline = System.monotonic_time(:millisecond) + @call_ms - @commit_margin_ms
        GenServer.call(pid, {:hub, deadline, request}, @call_ms)
    end
  end

  # -- Options --------------------------------------------------------------

  defp options(opts) do
    with {:ok, core} <- required(opts, :core, &is_atom/1),
         {:ok, sessions_dir} <- sessions_dir(core),
         {:ok, _} <- optional(opts, :name, nil, &name_option?/1),
         {:ok, owner} <- required(opts, :default_owner, &name?/1),
         {:ok, server_token} <- optional(opts, :server_token, nil, &is_function(&1, 0)),
         {:ok, store} <- optional(opts, :store, Helyx.Hub.Store.SQLite, &store?/1),
         {:ok, max_live} <- optional(opts, :max_live_sessions, @max_live, &live_cap?/1),
         {:ok, path} <- path(opts, sessions_dir) do
      {:ok,
       %{
         core: core,
         default_owner: owner,
         server_token: server_token,
         store: store,
         max_live: max_live,
         path: path
       }}
    end
  end

  defp live_cap?(n), do: is_integer(n) and n in 1..@max_live

  # The admission check reads the mailbox of a local pid only; a global name
  # can name a pid of another node.
  defp name_option?({:global, _}), do: false
  defp name_option?({:via, :global, _}), do: false

  defp name_option?({:via, mod, _}),
    do: loaded?(mod) and function_exported?(mod, :register_name, 2)

  defp name_option?(name), do: is_atom(name)

  defp store?(mod), do: loaded?(mod) and Helyx.Hub.Store in behaviours(mod)

  defp behaviours(mod),
    do: mod.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

  defp loaded?(mod), do: is_atom(mod) and Code.ensure_loaded?(mod)

  defp required(opts, key, valid?) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> checked(key, value, valid?)
      :error -> {:error, {:invalid_option, key}}
    end
  end

  defp optional(opts, key, default, valid?) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> checked(key, value, valid?)
      :error -> {:ok, default}
    end
  end

  defp checked(key, value, valid?) do
    if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_option, key}}
  end

  # The store file: `:path`, else the data folder of the Core, else memory.
  defp path(opts, sessions_dir) do
    case {Keyword.fetch(opts, :path), sessions_dir} do
      {{:ok, path}, _} when is_binary(path) and path != "" -> safe_folder(Path.expand(path))
      {{:ok, _}, _} -> {:error, {:invalid_option, :path}}
      {:error, nil} -> {:ok, nil}
      {:error, dir} -> safe_folder(Path.join(dir, "hub.db"))
    end
  end

  # Every session id routes to this Core (decision 10). Core.config/2 raises
  # for a name that names no running Core.
  defp sessions_dir(core) do
    {:ok, Helyx.Core.config(core, :sessions_dir)}
  rescue
    ArgumentError -> {:error, {:invalid_option, :core}}
  end

  # The trust boundary of the session files (decision 9): a folder that its
  # group or other users can write could swap the file.
  defp safe_folder(path) do
    case File.stat(Path.dirname(path)) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when (mode &&& 0o022) == 0 -> {:ok, path}
      {:ok, _} -> {:error, :unsafe_folder}
      {:error, _} -> {:error, {:invalid_option, :path}}
    end
  end

  # 1 to 64 bytes of UTF-8 with no control character (C0, DEL, C1).
  @doc false
  @spec name?(term()) :: boolean()
  def name?(name) do
    is_binary(name) and byte_size(name) in 1..@max_name_bytes and String.valid?(name) and
      not String.match?(name, ~r/[\x{0}-\x{1f}\x{7f}-\x{9f}]/u)
  end
end
