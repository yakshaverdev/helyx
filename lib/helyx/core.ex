defmodule Helyx.Core do
  @moduledoc """
  Registers, resolves, and supervises plugins.

  Start Core as a child of the product's supervision tree with the plugin list:

      children = [{Helyx.Core, plugins: [Helyx.Provider.Fake]}]

  Core checks every plugin against the interfaces it implements. It refuses to
  start when a `:single` interface receives more than one plugin, when a
  `required: true` interface receives none, when a module implements no
  interface at all, or when a plugin does not export a required callback of
  an interface it implements (`{:missing_callbacks, plugin, interface,
  missing}`). It calls `id/0` of each provider once, and
  refuses to start with `{:invalid_provider_id, plugin}` when one raises,
  throws, exits, or returns a value that is not a binary, and with
  `{:duplicate_provider_id, id, [first, second]}` when two providers share
  an id.

  A plugin that exports `child_spec/1` gets its process tree started under
  Core, with `[core: name]` as the argument.

  Several Core instances can run in one node under different names. Sessions
  and their subscribers are scoped to the Core that started them.
  """

  use Supervisor

  @type name :: atom()

  # Every interface Core checks at boot, so a required one with no plugin is
  # rejected even when nothing else mentions it.
  @interfaces [Helyx.Provider]

  @doc "Child spec for a product's supervision tree. Takes `name:` and `plugins:`."
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

    with {:ok, table} <- Helyx.Core.Plugins.resolve(plugins, @interfaces),
         {:ok, ids} <- Helyx.Core.Plugins.provider_ids(table[Helyx.Provider]) do
      Supervisor.start_link(__MODULE__, {name, plugins, table, ids}, name: name)
    end
  end

  @impl true
  def init({name, plugins, table, ids}) do
    plugin_children =
      for plugin <- plugins, function_exported?(plugin, :child_spec, 1) do
        plugin.child_spec(core: name)
      end

    children =
      [
        # The child spec holds the plugin table and the provider ids, so a
        # restart keeps them.
        {Registry,
         keys: :unique, name: sessions_registry(name), meta: [plugins: table, provider_ids: ids]},
        {Task.Supervisor, name: task_supervisor(name)},
        # The start message of a session holds its whole state, a resumed
        # transcript too. An idle supervisor never collects it, so the
        # supervisor hibernates after each message: a full collection (#103).
        {DynamicSupervisor,
         name: session_supervisor(name), strategy: :one_for_one, hibernate_after: 0}
      ] ++ plugin_children

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Returns the plugins registered for an interface, in registration order."
  @spec plugins(name(), module()) :: [module()]
  def plugins(name \\ __MODULE__, interface) do
    Map.get(meta!(name, :plugins), interface, [])
  end

  @doc false
  # The provider id to module map that Core built at start.
  @spec provider_ids(name()) :: %{String.t() => module()}
  def provider_ids(name), do: meta!(name, :provider_ids)

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
