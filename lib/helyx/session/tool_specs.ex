defmodule Helyx.Session.ToolSpecs do
  @moduledoc false
  # The checks of the fixed tools at a session start, their specs, `check/0`, and
  # `concurrent?/0`, and the name rule of every tool, for `Helyx.Tool.specs/2`,
  # `check_available/1`, `concurrent/1`, and `name?/1`. `spec_error/2` is also
  # the check of the entries of a tool source
  # (`Helyx.Session.ToolRegistry`).

  alias Helyx.Session.Input

  def specs(core, only) do
    result =
      Enum.reduce_while(fixed(core), {:ok, []}, fn tool, {:ok, acc} ->
        case checked_spec(tool) do
          {:ok, spec} -> {:cont, {:ok, [{tool, spec} | acc]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, tools} <- result,
         :ok <- check_unique(tools),
         do: {:ok, Enum.sort_by(keep(tools, only), fn {_tool, spec} -> spec.name end)}
  end

  defp fixed(core), do: Enum.reject(Helyx.Core.plugins(core, Helyx.Tool), &Helyx.Tool.source?/1)

  defp keep(tools, nil), do: tools
  defp keep(tools, only), do: Enum.filter(tools, fn {_tool, spec} -> spec.name in only end)

  defp checked_spec(tool) do
    spec = %{name: tool.name(), description: tool.description(), parameters: tool.parameters()}

    cond do
      not name?(spec.name) ->
        {:error, {:bad_tool_spec, inspect(tool)}}

      spec_error(spec.description, spec.parameters) != nil ->
        {:error, {:bad_tool_spec, spec.name}}

      true ->
        {:ok, spec}
    end
  end

  defp check_unique(tools) do
    names = Enum.map(tools, fn {_tool, spec} -> spec.name end)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [dup | _] -> {:error, {:duplicate_tool_name, dup}}
    end
  end

  # The most bytes of the description and of the parameters of a spec
  # (docs/features/mcp-client.md, "Bounds"). One check for the specs of the
  # fixed tools and of the entries of a tool source; Core rejects a longer
  # description than the MCP plugin cuts.
  @max_description_bytes 4_096
  @max_parameters_bytes 16_384

  @doc false
  # The reason that the description or the parameters of a spec are outside the
  # rule, or nil: a description of UTF-8 of at most 4,096 bytes, and parameters
  # that are a JSON object of at most 16,384 bytes.
  @spec spec_error(term(), term()) :: String.t() | nil
  def spec_error(description, parameters) do
    cond do
      not text?(description, @max_description_bytes) ->
        "a description that is not UTF-8 of at most #{@max_description_bytes} bytes"

      Input.json_object(parameters, @max_parameters_bytes) != :ok ->
        "parameters that are not a JSON object of at most #{@max_parameters_bytes} bytes"

      true ->
        nil
    end
  end

  defp text?(value, max),
    do: is_binary(value) and byte_size(value) <= max and String.valid?(value)

  # The smallest name limit known among the providers is 64 bytes of this set,
  # and a harness shows a Helyx tool as `mcp__helyx__<name>`, 12 bytes more
  # (docs/features/mcp-client.md, decision 8).
  @name_pattern ~r/\A[A-Za-z0-9_-]{1,52}\z/

  def name?(value), do: is_binary(value) and Regex.match?(@name_pattern, value)

  def check_available(tools) do
    Enum.find_value(tools, :ok, fn {tool, spec} ->
      case run_check(tool) do
        :ok -> nil
        {:error, reason} -> {:error, {:tool_unavailable, spec.name, reason}}
      end
    end)
  end

  defp run_check(tool) do
    if function_exported?(tool, :check, 0), do: checked_result(tool.check()), else: :ok
  end

  defp checked_result(:ok), do: :ok

  defp checked_result({:error, reason} = error) when is_binary(reason) do
    true = String.valid?(reason)
    error
  end

  def concurrent(tools),
    do: MapSet.new(for {tool, spec} <- tools, concurrent?(tool), do: spec.name)

  defp concurrent?(tool) do
    if function_exported?(tool, :concurrent?, 0) do
      concurrent? = tool.concurrent?()
      true = is_boolean(concurrent?)
      concurrent?
    else
      false
    end
  end
end
