defmodule Helyx.Core.Plugins do
  @moduledoc false
  # Resolves the plugin table for one Core instance. Core keeps the table in
  # the meta of its sessions Registry.

  @type table :: %{module() => [module()]}

  @doc "Checks the plugins value, groups the plugins by interface, and checks each interface's mode."
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
  # checks after it trust the shape: each entry is an Elixir module, listed
  # once.
  defp check_shape(plugins) do
    if is_list(plugins) and not List.improper?(plugins),
      do: Enum.find_value(plugins, &invalid_plugin/1) || check_unique(plugins),
      else: {:error, {:invalid_plugins, plugins}}
  end

  defp check_unique(plugins) do
    case plugins -- Enum.uniq(plugins) do
      [] -> :ok
      [module | _] -> {:error, {:duplicate_plugin, module}}
    end
  end

  # An Erlang module such as `:lists` has no `__info__/1`.
  defp invalid_plugin(entry) do
    if is_atom(entry) and Code.ensure_loaded?(entry) and function_exported?(entry, :__info__, 1),
      do: nil,
      else: {:error, {:invalid_plugin, entry}}
  end

  @modes %{
    Helyx.Provider => :multi,
    Helyx.Tool => :multi,
    Helyx.ModelContext => :multi,
    Helyx.Hook => :multi,
    Helyx.Compaction => :single,
    Helyx.Memory => :single
  }

  defp group(plugins) do
    implemented = Enum.map(plugins, &{&1, implemented_by(&1)})

    pairs =
      for {plugin, interfaces} <- implemented, interface <- interfaces, do: {interface, plugin}

    case Enum.find_value(implemented, &not_a_plugin/1) do
      nil -> {:ok, Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))}
      error -> {:error, error}
    end
  end

  defp implemented_by(plugin) do
    plugin.__info__(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.filter(&Map.has_key?(@modes, &1))
  end

  defp not_a_plugin({plugin, []}), do: {:not_a_plugin, plugin}
  defp not_a_plugin(_implemented), do: nil

  @doc "Maps each provider id to its plugin, after one call of `id/0` of each provider."
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

  # The providers whose optional `max_output_tokens?/0` returns `true`; any
  # other return than a boolean fails the start
  # (docs/features/output-limit.md, decision 3).
  @spec limit_providers([module()]) ::
          {:ok, [module()]} | {:error, {:invalid_max_output_tokens, module()}}
  def limit_providers(providers) do
    Enum.reduce_while(providers, {:ok, []}, fn plugin, {:ok, limited} ->
      case function_exported?(plugin, :max_output_tokens?, 0) and plugin.max_output_tokens?() do
        true -> {:cont, {:ok, [plugin | limited]}}
        false -> {:cont, {:ok, limited}}
        _other -> {:halt, {:error, {:invalid_max_output_tokens, plugin}}}
      end
    end)
  end

  @doc "The hook modules of each point with their limits, in plugin order."
  @spec hooks([module()]) ::
          {:ok, %{Helyx.Hook.point() => [{module(), pos_integer()}]}}
          | {:error, {:no_hook_point | :invalid_hook_limit | :invalid_hook_name, module()}}
  def hooks(plugins) do
    checked =
      Enum.reduce_while(plugins, {:ok, []}, fn plugin, {:ok, acc} ->
        case hook_limits(plugin) do
          {:ok, limits} ->
            {:cont, {:ok, acc ++ for({point, ms} <- limits, do: {point, {plugin, ms}})}}

          error ->
            {:halt, error}
        end
      end)

    with {:ok, pairs} <- checked,
         do: {:ok, Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))}
  end

  defp hook_limits(plugin) do
    points = Enum.filter(Helyx.Hook.points(), &function_exported?(plugin, &1, 1))
    limits = for point <- points, do: {point, limit(plugin, point)}

    cond do
      points == [] -> {:error, {:no_hook_point, plugin}}
      not Enum.all?(limits, &limit?(elem(&1, 1))) -> {:error, {:invalid_hook_limit, plugin}}
      :before_settle in points and not name?(plugin) -> {:error, {:invalid_hook_name, plugin}}
      true -> {:ok, limits}
    end
  end

  # The name of a hook is the origin id of its continue message.
  defp name?(plugin), do: Helyx.Message.origin?(Helyx.Message.hook_origin(plugin))

  defp limit(plugin, point),
    do: if(function_exported?(plugin, :limit, 1), do: plugin.limit(point))

  defp limit?(ms), do: is_integer(ms) and ms in 1..Helyx.Hook.max_limit_ms()//1

  @doc "Checks each Tool plugin: a fixed tool, or a tool source."
  @spec tools([module()]) :: :ok | {:error, {:invalid_tool_plugin, module()}}
  def tools(plugins) do
    case Enum.find(plugins, &(not tool_kind?(&1))) do
      nil -> :ok
      plugin -> {:error, {:invalid_tool_plugin, plugin}}
    end
  end

  defp tool_kind?(plugin) do
    source? = Helyx.Tool.source?(plugin)

    function_exported?(plugin, :run, 2) and
      Enum.all?(
        [:name, :description, :parameters],
        &(function_exported?(plugin, &1, 0) != source?)
      )
  end

  defp checked_id(plugin) do
    id = plugin.id()
    if is_binary(id), do: {:ok, id}, else: :error
  end

  defp check_mode({interface, [_, _ | _] = plugins}) do
    if @modes[interface] == :single,
      do: {:mode_violation, interface, plugins}
  end

  defp check_mode(_entry), do: nil
end
