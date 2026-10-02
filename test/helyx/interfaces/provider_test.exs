defmodule Helyx.ProviderTest do
  use ExUnit.Case, async: true

  # `Helyx.Provider.turn/1` reads `function_exported?/3`, which needs the
  # module loaded. In a session, Core start loads it, because it calls `id/0`.
  setup do
    Code.ensure_loaded!(Helyx.Test.Provider)
    Code.ensure_loaded!(Helyx.Test.Harness)
    :ok
  end

  test "a provider with no init/3 gets a local turn" do
    assert Helyx.Provider.turn(Helyx.Test.Provider) == :local
  end

  test "a provider that exports init/3 is connected, with no stream/3" do
    refute function_exported?(Helyx.Test.Harness, :stream, 3)
    assert Helyx.Provider.turn(Helyx.Test.Harness) == :connected
  end
end
