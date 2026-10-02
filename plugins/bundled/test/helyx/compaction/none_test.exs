defmodule Helyx.Compaction.NoneTest do
  use ExUnit.Case, async: true

  defmodule Provider do
    @moduledoc false
    # Core requires a provider to boot.
    use Helyx.Provider.Loop

    @impl true
    def id, do: "stub"

    @impl true
    def stream(_model, _context, _opts), do: {:ok, []}
  end

  test "registered with Core, it returns the context unchanged" do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Provider, Helyx.Compaction.None]})

    assert Helyx.Core.plugins(core, Helyx.Compaction) == [Helyx.Compaction.None]

    context = %Helyx.Context{system: "base", messages: [Helyx.Message.user("hi")]}
    assert Helyx.Compaction.None.compact(context, []) == context
  end
end
