defmodule Helyx.Core.Plugins do
  @moduledoc false
  # Resolves the plugin table for one Core instance. Core keeps the table in
  # the meta of its sessions Registry.

  @type table :: %{module() => [module()]}

  @doc """
  Checks the shape of the plugins value, groups plugins by interface, and
  checks each interface's mode.

  A value that is not a proper list is `{:invalid_plugins, value}`. An entry
  that is not an atom naming a loadable Elixir module is `{:invalid_plugin,
  entry}`. A module that implements no interface is `{:not_a_plugin,
  module}`. A plugin that does not export a required callback of an
  interface it implements is `{:missing_callbacks, plugin, interface,
  [{name, arity}]}`.
  """
  @spec resolve(term()) :: {:ok, table()} | {:error, term()}
  def resolve(plugins) do
    with :ok <- check_shape(plugins),
         {:ok, table} <- group(plugins) do
      case Enum.find_value(table, &check_mode/1) do
        nil -> {:ok, table}
        error -> {:error, error}
      end
    end
  end

  # The plugins value is config: this is its boundary check (AGENTS.md). The
  # checks after it trust the shape.
  defp check_shape(plugins) do
    if is_list(plugins) and not List.improper?(plugins),
      do: Enum.find_value(plugins, :ok, &invalid_plugin/1),
      else: {:error, {:invalid_plugins, plugins}}
  end

  # An Erlang module such as `:lists` has no `__info__/1`.
  defp invalid_plugin(entry) do
    if is_atom(entry) and Code.ensure_loaded?(entry) and function_exported?(entry, :__info__, 1),
      do: nil,
      else: {:error, {:invalid_plugin, entry}}
  end

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

  # Both modules are loaded: the shape check loaded the plugin, and
  # `implemented_by/1` loaded the interface. An interface without `@callback`
  # has no `behaviour_info/1` and requires nothing.
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
  defp check_mode({interface, [_, _ | _] = plugins}) do
    if match?(%{mode: :single}, Helyx.Interface.declaration(interface)),
      do: {:mode_violation, interface, plugins}
  end

  defp check_mode(_entry), do: nil
end
