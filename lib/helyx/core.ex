defmodule Helyx.Core do
  # The default limit of a recall. The most is the prepare budget less the
  # reserve that the prepare Task keeps after it (`Helyx.Session.Recall`).
  @recall_ms 2_000

  @moduledoc """
  Registers, resolves, and supervises plugins.

  Start Core as a child of the product's supervision tree with the plugin list:

      children = [{Helyx.Core, plugins: [Helyx.Provider.Fake]}]

  Core first checks the shape of the plugins value. It refuses to start with
  `{:invalid_plugins, value}` when the value is not a proper list, and with
  `{:invalid_plugin, entry}` when an entry is not an atom that names a
  loadable Elixir module (an Erlang module such as `:lists` is not one), and
  with `{:duplicate_plugin, module}` when a module is listed twice.

  Core checks every plugin against the interfaces it implements. It refuses to
  start with `{:mode_violation, interface, plugins}` when a `:single`
  interface receives more than one plugin, and with `{:not_a_plugin, module}`
  when a module implements no interface at all. It refuses to start with
  `{:missing_plugin, Helyx.Provider}` when no provider is listed. It calls
  `id/0` of each provider once, and refuses to start with
  `{:invalid_provider_id, plugin}` when one returns a value that is not a
  binary, and with `{:duplicate_provider_id, id, [first, second]}` when two
  different providers share an id. A plugin callback that raises, throws,
  or exits at start is not contained: the error goes to the caller.

  A plugin that exports `child_spec/1` gets its process tree started under
  Core, with `[core: name]` as the argument.

  `recall_ms` is the limit of a `Helyx.Memory` recall, an integer from 1 to
  9,000, default #{@recall_ms}; any other value stops the start with
  `{:invalid_recall_ms, value}` (`docs/features/memory.md`).

  Several Core instances can run in one node under different names. Sessions
  and their subscribers are scoped to the Core that started them.
  """

  use Supervisor

  @type name :: atom()

  @doc "Child spec for a product's supervision tree. Takes `name:`, `plugins:`, and `recall_ms:`."
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

    with {:ok, table} <- Helyx.Core.Plugins.resolve(plugins),
         {:ok, providers} <- providers(table),
         {:ok, ids} <- Helyx.Core.Plugins.provider_ids(providers),
         :ok <- check_recall_ms(recall_ms) do
      meta = [plugins: table, provider_ids: ids, recall_ms: recall_ms]
      Supervisor.start_link(__MODULE__, {name, plugins, meta}, name: name)
    end
  end

  defp check_recall_ms(ms) do
    if is_integer(ms) and ms in 1..Helyx.Session.Recall.max_ms()//1,
      do: :ok,
      else: {:error, {:invalid_recall_ms, ms}}
  end

  # A session needs a provider. The table holds no empty list.
  defp providers(%{Helyx.Provider => providers}), do: {:ok, providers}
  defp providers(_table), do: {:error, {:missing_plugin, Helyx.Provider}}

  @impl true
  def init({name, plugins, meta}) do
    plugin_children =
      for plugin <- plugins, function_exported?(plugin, :child_spec, 1) do
        plugin.child_spec(core: name)
      end

    children =
      [
        # The child spec holds the plugin table, the provider ids, and the
        # recall limit, so a restart keeps them.
        {Registry, keys: :unique, name: sessions_registry(name), meta: meta},
        {Task.Supervisor, name: task_supervisor(name)},
        # The session process loads a resumed transcript, so the start
        # message holds no transcript for the supervisor to keep (#103, #589).
        {DynamicSupervisor, name: session_supervisor(name), strategy: :one_for_one}
      ] ++ plugin_children

    Supervisor.init(children, strategy: :one_for_one)
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
  # The limit of a recall, in ms.
  @spec recall_ms(name()) :: pos_integer()
  def recall_ms(name), do: meta!(name, :recall_ms)

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
  def sessions_registry(name), do: Module.concat(name, Sessions)
  @doc false
  def task_supervisor(name), do: Module.concat(name, Tasks)
  @doc false
  def session_supervisor(name), do: Module.concat(name, SessionSupervisor)
end
