defmodule Helyx.HookTest do
  # The check of the hook plugins at Core start (docs/features/hooks.md,
  # "Core start"). Not async: `Helyx.Test.Hook.Limit` reads its limit from
  # one persistent term.
  use ExUnit.Case, async: false

  alias Helyx.Test.Hook

  defp start(plugins),
    do:
      Helyx.Core.start_link(
        name: :"hook_core_#{System.unique_integer([:positive])}",
        plugins: plugins
      )

  defp start_with_limit(ms) do
    :persistent_term.put({Hook.Limit, :ms}, ms)
    start([Helyx.Test.Provider, Hook.Limit])
  end

  test "the hooks of each point keep the order of the plugin list, with their limits" do
    {:ok, pid} = start([Helyx.Test.Provider, Hook.B, Hook.BeforeOnly, Hook.A])
    {:registered_name, core} = Process.info(pid, :registered_name)

    assert Helyx.Core.hooks(core) == %{
             before_tool: [{Hook.B, 2_000}, {Hook.BeforeOnly, 1}, {Hook.A, 2_000}],
             after_tool: [{Hook.B, 2_000}, {Hook.A, 2_000}]
           }

    Supervisor.stop(pid)
  end

  test "a Core with no hook has no point" do
    {:ok, pid} = start([Helyx.Test.Provider])
    {:registered_name, core} = Process.info(pid, :registered_name)
    assert Helyx.Core.hooks(core) == %{}
    Supervisor.stop(pid)
  end

  test "a hook plugin with no point stops the start" do
    assert start([Helyx.Test.Provider, Hook.NoPoint]) == {:error, {:no_hook_point, Hook.NoPoint}}
  end

  test "a limit that is not an integer stops the start" do
    assert start([Helyx.Test.Provider, Hook.NoLimit]) ==
             {:error, {:invalid_hook_limit, Hook.NoLimit}}
  end

  test "a hook plugin with a point and no limit/1 stops the start" do
    # Compiled here, so the warning of the missing callback stays out of the
    # build.
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_string("""
      defmodule Helyx.Test.Hook.NoLimitFn do
        @behaviour Helyx.Hook
        def before_tool(_input), do: :allow
      end
      """)
    end)

    module = Helyx.Test.Hook.NoLimitFn
    assert start([Helyx.Test.Provider, module]) == {:error, {:invalid_hook_limit, module}}
  end

  test "a limit from 1 to 600,000 ms starts, one past either end stops the start" do
    for ms <- [1, 600_000] do
      assert {:ok, pid} = start_with_limit(ms)
      Supervisor.stop(pid)
    end

    for ms <- [0, 600_001, -1, 1.0] do
      assert start_with_limit(ms) == {:error, {:invalid_hook_limit, Hook.Limit}}
    end
  end
end
