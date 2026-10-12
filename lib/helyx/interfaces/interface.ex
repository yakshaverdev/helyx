defmodule Helyx.Interface do
  @moduledoc """
  Marks a module as a Helyx interface.

  An interface is a behaviour plus a public API. It declares how many plugins
  can be active at once:

      use Helyx.Interface, mode: :single
      use Helyx.Interface, mode: :multi

  `:single` means exactly one plugin when present. `:multi` means any number.
  `:mode` is the only option.
  """

  @type mode :: :single | :multi

  defmacro __using__(opts) do
    mode = opts |> Keyword.validate!([:mode]) |> Keyword.fetch!(:mode)

    unless mode in [:single, :multi] do
      raise ArgumentError, "mode must be :single or :multi, got: #{inspect(mode)}"
    end

    quote do
      @doc false
      def __helyx_interface__, do: %{mode: unquote(mode)}
    end
  end

  @doc "Returns the interface declaration of a module, or `nil` if it is not an interface."
  @spec declaration(module()) :: %{mode: mode()} | nil
  def declaration(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :__helyx_interface__, 0) do
      module.__helyx_interface__()
    end
  end

  @doc """
  Returns the interfaces a plugin module implements, in declaration order.

  A module that cannot be loaded implements nothing.
  """
  @spec implemented_by(module()) :: [module()]
  def implemented_by(plugin) do
    case Code.ensure_loaded(plugin) do
      {:module, ^plugin} ->
        plugin.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()
        |> Enum.filter(&declaration/1)

      {:error, _reason} ->
        []
    end
  end
end
