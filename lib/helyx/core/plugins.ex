defmodule Helyx.Core.Plugins do
  @moduledoc false
  # Resolves the plugin table for one Core instance. Core keeps the table in
  # the meta of its sessions Registry.

  @type table :: %{module() => [module()]}

  @doc """
  Groups plugins by interface and checks each interface's mode.

  Every interface in `interfaces` is checked even when no plugin implements
  it, so a required interface with no plugin is an error. An interface that
  only appears through a plugin's `@behaviour` is checked too.
  """
  @spec resolve([module()], [module()]) :: {:ok, table()} | {:error, term()}
  def resolve(plugins, interfaces) do
    with {:ok, table} <- group(plugins) do
      interfaces = Enum.uniq(interfaces ++ Map.keys(table))

      case Enum.find_value(interfaces, &check_mode(&1, Map.get(table, &1, []))) do
        nil -> {:ok, table}
        error -> {:error, error}
      end
    end
  end

  defp group(plugins) do
    implemented = Enum.map(plugins, &{&1, Helyx.Interface.implemented_by(&1)})

    case Enum.find(implemented, &match?({_, []}, &1)) do
      {plugin, []} ->
        {:error, {:not_a_plugin, plugin}}

      nil ->
        pairs =
          for {plugin, interfaces} <- implemented,
              interface <- interfaces,
              do: {interface, plugin}

        {:ok, Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))}
    end
  end

  @doc """
  Maps each provider id to its plugin. It calls `id/0` of each provider once,
  at Core start. An `id/0` that raises, throws, exits, or returns a value
  that is not a binary is `{:invalid_provider_id, plugin}`. A provider that
  exports neither `stream/3` nor `init/3` has no turn and is
  `{:invalid_provider, plugin}`. Two providers
  with one id are `{:duplicate_provider_id, id, [first, second]}`.
  """
  @spec provider_ids([module()]) :: {:ok, %{String.t() => module()}} | {:error, term()}
  def provider_ids(providers) do
    Enum.reduce_while(providers, {:ok, %{}}, fn plugin, {:ok, ids} ->
      case checked(plugin) do
        :no_turn ->
          {:halt, {:error, {:invalid_provider, plugin}}}

        {:ok, id} when is_map_key(ids, id) ->
          {:halt, {:error, {:duplicate_provider_id, id, [ids[id], plugin]}}}

        {:ok, id} ->
          {:cont, {:ok, Map.put(ids, id, plugin)}}

        :error ->
          {:halt, {:error, {:invalid_provider_id, plugin}}}
      end
    end)
  end

  # A provider runs in a provider process: it needs `init/3`, `request/3`,
  # and `info/2`. The plugin check loaded the module.
  defp checked(plugin) do
    if function_exported?(plugin, :init, 3) and function_exported?(plugin, :request, 3) and
         function_exported?(plugin, :info, 2),
       do: checked_id(plugin),
       else: :no_turn
  end

  defp checked_id(plugin) do
    id = plugin.id()
    if is_binary(id), do: {:ok, id}, else: :error
  catch
    _class, _reason -> :error
  end

  # Returns the error for an interface and its plugins, or nil when they fit.
  defp check_mode(interface, plugins) do
    case {Helyx.Interface.declaration(interface), plugins} do
      {%{required: true}, []} -> {:missing_plugin, interface}
      {%{mode: :single}, [_, _ | _]} -> {:mode_violation, interface, plugins}
      _ -> nil
    end
  end
end
