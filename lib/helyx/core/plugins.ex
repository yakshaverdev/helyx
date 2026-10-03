defmodule Helyx.Core.Plugins do
  @moduledoc false
  # Resolves the plugin table for one Core instance. Core keeps the table in
  # the meta of its sessions Registry.

  @type table :: %{module() => [module()]}

  @doc """
  Groups plugins by interface and checks each interface's mode.

  A module that implements no interface is `{:not_a_plugin, module}`. A
  plugin that does not export a required callback of an interface it
  implements is `{:missing_callbacks, plugin, interface, [{name, arity}]}`.

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

  # The plugin list is config: this is its boundary check (AGENTS.md).
  defp group(plugins) do
    implemented = Enum.map(plugins, &{&1, Helyx.Interface.implemented_by(&1)})

    pairs =
      for {plugin, interfaces} <- implemented, interface <- interfaces, do: {interface, plugin}

    case Enum.find_value(implemented, &not_a_plugin/1) ||
           Enum.find_value(pairs, &missing_callbacks/1) do
      nil -> {:ok, Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))}
      error -> {:error, error}
    end
  end

  defp not_a_plugin({plugin, []}), do: {:not_a_plugin, plugin}
  defp not_a_plugin(_implemented), do: nil

  # Both modules are loaded: `implemented_by/1` loaded the plugin and the
  # interface. An interface without `@callback` has no `behaviour_info/1` and
  # requires nothing.
  defp missing_callbacks({interface, plugin}) do
    required =
      if function_exported?(interface, :behaviour_info, 1),
        do: interface.behaviour_info(:callbacks) -- interface.behaviour_info(:optional_callbacks),
        else: []

    case Enum.reject(Enum.sort(required), fn {name, arity} ->
           function_exported?(plugin, name, arity)
         end) do
      [] -> nil
      missing -> {:missing_callbacks, plugin, interface, missing}
    end
  end

  @doc """
  Maps each provider id to its plugin. It calls `id/0` of each provider once,
  at Core start. An `id/0` that raises, throws, exits, or returns a value
  that is not a binary is `{:invalid_provider_id, plugin}`. Two providers
  with one id are `{:duplicate_provider_id, id, [first, second]}`.
  """
  @spec provider_ids([module()]) :: {:ok, %{String.t() => module()}} | {:error, term()}
  def provider_ids(providers) do
    Enum.reduce_while(providers, {:ok, %{}}, fn plugin, {:ok, ids} ->
      case checked_id(plugin) do
        {:ok, id} when is_map_key(ids, id) ->
          {:halt, {:error, {:duplicate_provider_id, id, [ids[id], plugin]}}}

        {:ok, id} ->
          {:cont, {:ok, Map.put(ids, id, plugin)}}

        :error ->
          {:halt, {:error, {:invalid_provider_id, plugin}}}
      end
    end)
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
