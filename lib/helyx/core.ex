defmodule Helyx.Core do
  # The default limit of a recall. The most is the prepare budget less the
  # reserve that the prepare Task keeps after it (`Helyx.Session.Recall`).
  @recall_ms 2_000

  @moduledoc """
  Registers, resolves, and supervises plugins.

  Start Core as a child of the product's supervision tree with the plugin list:

      children = [{Helyx.Core, plugins: [Helyx.Provider.Fake]}]

  Core checks that the plugins value is a proper list of atoms that name
  loadable Elixir modules, listed once, then groups the plugins by interface
  and checks each interface's mode. It calls `id/0` of each provider once,
  the optional `max_output_tokens?/0` once, `limit/1` of each hook plugin
  once for each point that the plugin exports, and checks each Tool plugin.
  Any check that fails refuses the start with its error tuple:
  `{:invalid_plugins, value}`, `{:invalid_plugin, entry}`,
  `{:duplicate_plugin, module}`, `{:not_a_plugin, module}`,
  `{:mode_violation, interface, plugins}`, `{:missing_plugin,
  Helyx.Provider}`, `{:invalid_provider_id, plugin}`,
  `{:duplicate_provider_id, id, [first, second]}`,
  `{:invalid_max_output_tokens, plugin}`, `{:no_hook_point, plugin}`,
  `{:invalid_hook_limit, plugin}`, `{:invalid_hook_name, plugin}`, and
  `{:invalid_tool_plugin, plugin}`. The bounds behind them are in
  `docs/features/coding-agent.md`, "Bounds", `docs/features/hooks.md`,
  `docs/features/before-settle.md`, `docs/features/output-limit.md`, and
  `docs/features/mcp-client.md`. A plugin callback that raises, throws, or
  exits at start is not contained: the error goes to the caller.

  A plugin that exports `child_spec/1` gets its process tree started under
  Core, with `[core: name]` as the argument.

  `recall_ms` is the limit of a `Helyx.Memory` recall, an integer from 1 to
  9,000, default #{@recall_ms}; any other value stops the start with
  `{:invalid_recall_ms, value}` (`docs/features/memory.md`). The server
  configuration of `Helyx.Sessions` adds `:sessions_dir`, the folder of the
  session files, and `:model`, the default model ref; a path that is not
  absolute and valid, or a model that does not parse, refuses the start with
  `{:invalid_option, key}`. `:idle_stop_ms` is the time with no work after
  which a session of the Core stops, a positive integer or nil, default nil;
  any other value refuses the start with `{:invalid_option, :idle_stop_ms}`
  (`docs/features/idle-unload.md`). Core runs at most 64 sessions
  (`docs/features/server-management.md`).

  Several Core instances can run in one node under different names. Sessions
  and their subscribers are scoped to the Core that started them.

  With `:sessions_dir`, Core makes the folder and takes the lock of the data
  folder at its start (`docs/features/session-lock.md`). A second Core on the
  folder gives `{:error, {:data_folder_locked, dir}}`; other errors are
  `{:error, {:lock_failed, text}}` and `{:error, {:create_failed, reason}}`.
  A failed start reaches a caller that does not trap exits as an exit signal,
  so a caller that wants `{:error, {:data_folder_locked, dir}}` must trap
  exits or start Core under a supervisor. If the lock ends while Core runs,
  Core stops. Perl is required when `:sessions_dir` is given.
  """

  use Supervisor

  @type name :: atom()

  # The live sessions of one Core (server-management.md, "Bounds").
  @max_sessions 64

  @doc "Child spec for a product's supervision tree. Takes `name:`, `plugins:`, `recall_ms:`, `sessions_dir:`, `model:`, and `idle_stop_ms:`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts Core. Returns the resolution error instead of a pid when the plugin list is invalid."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    plugins = Keyword.get(opts, :plugins, [])
    recall_ms = Keyword.get(opts, :recall_ms, @recall_ms)
    idle_stop_ms = Keyword.get(opts, :idle_stop_ms)

    with :ok <- check(:sessions_dir, opts[:sessions_dir]),
         :ok <- check(:model, opts[:model]),
         :ok <- check_idle_stop_ms(idle_stop_ms),
         {:ok, table} <- Helyx.Core.Plugins.resolve(plugins),
         {:ok, providers} <- providers(table),
         {:ok, ids} <- Helyx.Core.Plugins.provider_ids(providers),
         {:ok, limited} <- Helyx.Core.Plugins.limit_providers(providers),
         {:ok, hooks} <- Helyx.Core.Plugins.hooks(Map.get(table, Helyx.Hook, [])),
         :ok <- Helyx.Core.Plugins.tools(Map.get(table, Helyx.Tool, [])),
         :ok <- check_recall_ms(recall_ms) do
      meta = [
        plugins: table,
        provider_ids: ids,
        limit_providers: limited,
        hooks: hooks,
        recall_ms: recall_ms,
        sessions_dir: opts[:sessions_dir],
        model: opts[:model],
        idle_stop_ms: idle_stop_ms
      ]

      case Supervisor.start_link(__MODULE__, {name, plugins, meta}, name: name) do
        {:error, {:shutdown, {:failed_to_start_child, Helyx.Core.FolderLock, reason}}} ->
          {:error, reason}

        result ->
          result
      end
    end
  end

  defp check_recall_ms(ms) do
    if is_integer(ms) and ms in 1..Helyx.Session.Recall.max_ms()//1,
      do: :ok,
      else: {:error, {:invalid_recall_ms, ms}}
  end

  # The idle stop of a session, in ms: a positive integer up to the largest
  # time that the timer takes, or nil for no rule (docs/features/idle-unload.md).
  defp check_idle_stop_ms(nil), do: :ok

  defp check_idle_stop_ms(ms) when is_integer(ms) and ms > 0 do
    if ms <= Helyx.Session.Server.IdleStop.max_ms(),
      do: :ok,
      else: {:error, {:invalid_option, :idle_stop_ms}}
  end

  defp check_idle_stop_ms(_ms), do: {:error, {:invalid_option, :idle_stop_ms}}

  # The folder goes into file paths, as the cwd of a session does. A
  # relative folder would move with the working directory of the node.
  defp check(_key, nil), do: :ok

  defp check(:model, model) when is_binary(model) do
    if match?({:ok, _}, Helyx.ModelRef.parse(model)),
      do: :ok,
      else: {:error, {:invalid_option, :model}}
  end

  defp check(:sessions_dir, dir) do
    if match?({:ok, _}, Helyx.Session.Input.cwd(dir)) and Path.type(dir) == :absolute,
      do: :ok,
      else: {:error, {:invalid_option, :sessions_dir}}
  end

  defp check(key, _value), do: {:error, {:invalid_option, key}}

  # A session needs a provider. The table holds no empty list.
  defp providers(%{Helyx.Provider => providers}), do: {:ok, providers}
  defp providers(_table), do: {:error, {:missing_plugin, Helyx.Provider}}

  @impl true
  def init({name, plugins, meta}) do
    plugin_children =
      for plugin <- plugins, function_exported?(plugin, :child_spec, 1) do
        plugin.child_spec(core: name)
      end

    # The lock is first, so it is taken before any session and released after
    # all of them; its end stops Core (docs/features/session-lock.md).
    lock =
      case Keyword.fetch!(meta, :sessions_dir) do
        nil ->
          []

        dir ->
          [
            Supervisor.child_spec({Helyx.Core.FolderLock, {dir, name}},
              restart: :temporary,
              significant: true
            )
          ]
      end

    children =
      lock ++
        [
          # The child spec holds the plugin table, the provider ids, the recall
          # limit, and the server configuration, so a restart keeps them.
          {Registry, keys: :unique, name: sessions_registry(name), meta: meta},
          # The watchers of the session feed, one entry for each type that a
          # watcher names (docs/features/session-feed.md). The supervisor stops
          # its children in reverse order, so the feed outlives the sessions.
          {Registry, keys: :duplicate, name: feed_registry(name)},
          {Task.Supervisor, name: task_supervisor(name)},
          # The memory sync workers, apart from the sessions so that the cap
          # counts sessions only (#707). It is before the session supervisor, so
          # it stops after the sessions and takes the batches of their stops.
          {DynamicSupervisor, name: sync_supervisor(name), strategy: :one_for_one},
          # The session process loads a resumed transcript, so the start
          # message holds no transcript for the supervisor to keep (#103, #589).
          # The supervisor counts its children one start at a time, so
          # concurrent starts cannot pass the cap.
          {DynamicSupervisor,
           name: session_supervisor(name), strategy: :one_for_one, max_children: @max_sessions}
        ] ++ plugin_children

    Supervisor.init(children, strategy: :one_for_one, auto_shutdown: :any_significant)
  end

  @doc "Returns the plugins registered for an interface, in registration order."
  @spec plugins(name(), module()) :: [module()]
  def plugins(name, interface) do
    Map.get(meta!(name, :plugins), interface, [])
  end

  @doc false
  # The provider id to module map that Core built at start.
  @spec provider_ids(name()) :: %{String.t() => module()}
  def provider_ids(name), do: meta!(name, :provider_ids)

  @doc false
  # The providers that apply a session's `:max_output_tokens`, which Core
  # found at start.
  @spec limit_providers(name()) :: [module()]
  def limit_providers(name), do: meta!(name, :limit_providers)

  @doc false
  # The hook modules and their limits of each point, in plugin order.
  @spec hooks(name()) :: %{Helyx.Hook.point() => [{module(), pos_integer()}]}
  def hooks(name), do: meta!(name, :hooks)

  @doc false
  # The limit of a recall, in ms.
  @spec recall_ms(name()) :: pos_integer()
  def recall_ms(name), do: meta!(name, :recall_ms)

  @doc false
  # An option of the server configuration, or nil.
  @spec config(name(), :sessions_dir | :model | :idle_stop_ms) :: String.t() | pos_integer() | nil
  def config(name, key), do: meta!(name, key)

  # Every Core sets these meta keys at start, so `:error` gets the answer of a
  # missing table, `ArgumentError`, which `Session.set_model/2` rescues. A
  # Registry start creates its table before it inserts the keys, so a read in
  # that window gets `:error`. The #462 precommit saw `:error` once after
  # `Supervisor.stop/1` (#465).
  defp meta!(name, key) do
    case Registry.meta(sessions_registry(name), key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "the Core #{inspect(name)} holds no #{key}"
    end
  end

  @doc false
  def max_sessions, do: @max_sessions
  @doc false
  def sessions_registry(name), do: Module.concat(name, Sessions)
  @doc false
  def feed_registry(name), do: Module.concat(name, Feed)
  @doc false
  def task_supervisor(name), do: Module.concat(name, Tasks)
  @doc false
  def session_supervisor(name), do: Module.concat(name, SessionSupervisor)
  @doc false
  def sync_supervisor(name), do: Module.concat(name, SyncSupervisor)
end
