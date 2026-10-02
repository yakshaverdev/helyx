defmodule Helyx.CoreTest do
  use ExUnit.Case, async: true

  alias Helyx.Test

  defp boot(plugins) do
    name = :"core_#{System.unique_integer([:positive])}"
    Helyx.Core.start_link(name: name, plugins: plugins)
  end

  test "boots with one plugin per single interface and any number per multi interface" do
    assert {:ok, _} = boot([Test.Provider, Test.SingleA, Test.MultiA, Test.MultiB])
  end

  test "exposes the registered plugins per interface" do
    name = :"core_#{System.unique_integer([:positive])}"
    plugins = [Test.Provider, Test.SingleA, Test.MultiB, Test.MultiA]
    {:ok, _} = start_supervised({Helyx.Core, name: name, plugins: plugins})

    assert Helyx.Core.plugins(name, Test.Single) == [Test.SingleA]
    assert Helyx.Core.plugins(name, Test.Multi) == [Test.MultiB, Test.MultiA]
    assert Helyx.Core.plugins(name, Helyx.Provider) == [Test.Provider]
  end

  test "the plugin table survives a restart of the sessions Registry" do
    name = :"core_#{System.unique_integer([:positive])}"
    {:ok, _} = start_supervised({Helyx.Core, name: name, plugins: [Test.Provider, Test.MultiA]})

    # Core starts the Registry again from its child spec.
    registry = Helyx.Core.sessions_registry(name)
    old = Process.whereis(registry)
    :ok = Supervisor.terminate_child(name, registry)
    {:ok, new} = Supervisor.restart_child(name, registry)
    assert new != old
    assert Helyx.Core.plugins(name, Test.Multi) == [Test.MultiA]
  end

  for {name, plugins, error} <- [
        {"two plugins for a single interface", [Test.Provider, Test.SingleA, Test.SingleB],
         quote(do: {:mode_violation, Test.Single, [Test.SingleA, Test.SingleB]})},
        {"two model context plugins", [Test.Provider, Test.ModelContext, Test.ModelContextTwin],
         quote(do: {:mode_violation, Helyx.ModelContext, _})},
        {"two compaction plugins", [Test.Provider, Test.Compaction, Test.CompactionTwin],
         quote(do: {:mode_violation, Helyx.Compaction, _})},
        {"a missing provider", [Test.SingleA], quote(do: {:missing_plugin, Helyx.Provider})},
        {"a module that does not exist", [Test.Provider, Test.Missing],
         quote(do: {:not_a_plugin, Test.Missing})},
        {"a module that implements no interface", [Test.Provider, Test.NoInterface],
         quote(do: {:not_a_plugin, Test.NoInterface})}
      ] do
    test "rejects #{name}" do
      assert {:error, unquote(error)} = boot(unquote(plugins))
    end
  end

  describe "provider ids (#169)" do
    test "an id/0 that raises, throws, exits, or is not a binary stops the start" do
      for mode <- [:raise, :throw, :exit, 42] do
        Process.put(:bad_id, mode)
        assert boot([Test.Provider, Test.BadId]) == {:error, {:invalid_provider_id, Test.BadId}}
      end
    end

    test "a provider without init/3, request/3, and info/2 stops the start" do
      # The missing callbacks are the point; their compile warnings are kept
      # out of the test output.
      source = """
      defmodule Helyx.Test.NoTurn do
        @behaviour Helyx.Provider
        def id, do: "no_turn"
      end
      """

      {[{no_turn, _}], _warnings} = Code.with_diagnostics(fn -> Code.compile_string(source) end)
      assert boot([Test.Provider, no_turn]) == {:error, {:invalid_provider, no_turn}}
    end

    test "two providers with one id stop the start and are both named" do
      assert boot([Test.Provider, Test.ProviderOther, Test.ProviderTwin]) ==
               {:error, {:duplicate_provider_id, "test", [Test.Provider, Test.ProviderTwin]}}
    end

    test "a lookup reads the ids of the start and calls no plugin code" do
      name = :"core_#{System.unique_integer([:positive])}"
      start_supervised!({Helyx.Core, name: name, plugins: [Test.Provider, Test.BadId]})
      Process.put(:bad_id, :raise)

      assert Helyx.Provider.find(name, "bad_id") == {:ok, Test.BadId}
      assert Helyx.Provider.find(name, "test") == {:ok, Test.Provider}
      assert Helyx.Provider.find(name, "none") == {:error, {:unknown_provider, "none"}}
    end
  end
end
