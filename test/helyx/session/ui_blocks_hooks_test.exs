defmodule Helyx.Session.UIBlocksHooksTest do
  # UI blocks and the hooks (docs/features/ui-blocks.md,
  # docs/features/hooks.md): an `after_tool` hook gets the result as
  # `{status, text}`; a keep and a failure keep the blocks, and a replace
  # gives a result with none. A hook Task shows no block, and its ask with
  # a kind gets the check of a UI block.
  use ExUnit.Case, async: true

  import Helyx.Test.Events

  alias Helyx.Message.ToolCall
  alias Helyx.Session
  alias Helyx.Test.{Connected, Hook}
  alias Helyx.Test.UIBlocks.{Result, Show}

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Connected, Result, Show, Hook.A]})
    Process.register(self(), Connected.controller(core))
    Hook.proxy(core, self())
    %{core: core}
  end

  defp events(proc, turn_id, events),
    do: send(proc, {:batch, Enum.map(events, &{:event, turn_id, &1})})

  # One Helyx call of the result tool with 2 blocks, its result echoed:
  # the result message.
  defp result_message(core) do
    {:ok, session} = Session.start(core, model: "conn/tools")
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, proc, {:turn, turn_id, _context}}
    args = %{"mode" => "n.2"}

    events(proc, turn_id, [
      {:tool_call, %ToolCall{id: "c1", name: "result", arguments: args}},
      {:message_end, :tool_use, nil},
      {:tool_request, "c1", "result", args}
    ])

    assert_receive {:conn, :tool_result, ^proc, {:tool_result, ^turn_id, "c1", result}}
    events(proc, turn_id, [{:tool_result, "c1", result}])
    [%{message: m}] = of_type(collect_until(:tool_execution_end), :tool_execution_end)
    send(proc, {:finish, turn_id})
    collect_until(:turn_end)
    m
  end

  test "a keep keeps the blocks; the hook gets the result without them", %{core: core} do
    m = result_message(core)
    assert_receive {:hook, Hook.A, :after_tool, %{result: seen}}
    assert seen == {:ok, "r"}
    assert m.ui_blocks == [Result.block(1), Result.block(2)]
  end

  test "a replace gives a result with no blocks", %{core: core} do
    Hook.script(core, Hook.A, :after_tool, fn _ -> {:replace, {:ok, "replaced"}} end)
    m = result_message(core)
    assert Helyx.Message.text(m) == "replaced"
    assert m.ui_blocks == []
  end

  @tag :capture_log
  test "a hook that fails keeps the blocks", %{core: core} do
    Hook.script(core, Hook.A, :after_tool, fn _ -> raise "boom" end)
    m = result_message(core)
    assert Helyx.Message.text(m) == "r"
    assert m.ui_blocks == [Result.block(1), Result.block(2)]
  end

  test "a hook Task's show gets not_running", %{core: core} do
    test = Hook.test_name(core)
    block = %{"kind" => "progress", "text" => "hook"}

    Hook.script(core, Hook.A, :before_tool, fn _ ->
      send(test, {:shown, Helyx.Tool.show("k", block)})
      :allow
    end)

    result_message(core)
    assert_receive {:shown, {:error, :not_running}}
  end

  test "a hook Task that starts after its call's result gets no record: its ask is refused",
       %{core: core} do
    test = Hook.test_name(core)

    Hook.script(core, Hook.A, :after_tool, fn _ ->
      send(test, {:asked, Helyx.Hook.ask(%{"q" => "late"})})
      :keep
    end)

    {:ok, session} = Session.start(core, model: "conn/tools")
    {:ok, _, _} = Session.subscribe(session, answers: true)
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, proc, {:turn, turn_id, _context}}
    gate = gate()
    args = %{"shows" => [], "gate" => gate}

    events(proc, turn_id, [
      {:tool_call, %ToolCall{id: "c1", name: "show", arguments: args}},
      {:message_end, :tool_use, nil},
      {:tool_request, "c1", "show", args}
    ])

    assert_receive {:waiting, run}
    events(proc, turn_id, [{:tool_result, "c1", {:ok, "early"}}])
    collect_until(:tool_execution_end)
    send(run, :go)
    assert_receive {:asked, {:error, :not_running}}
    send(proc, {:finish, turn_id})
    assert of_type(collect_until(:turn_end), :ask) == []
  end

  # The test process holds the controller name, so a proxy holds the name
  # of the gate (`Helyx.Test.Gate`) and forwards each wait.
  defp gate do
    test = self()
    gate = :"gate_#{System.unique_integer([:positive])}"

    spawn_link(fn ->
      Process.register(self(), gate)
      send(test, :registered)
      forward_waits(test)
    end)

    assert_receive :registered
    Atom.to_string(gate)
  end

  defp forward_waits(test) do
    receive do: ({:waiting, run} -> send(test, {:waiting, run}))
    forward_waits(test)
  end

  test "a hook's ask with a kind gets the check of a UI block", %{core: core} do
    test = Hook.test_name(core)

    Hook.script(core, Hook.A, :before_tool, fn _ ->
      raised =
        for request <- [%{"kind" => "Bad", "text" => ""}, %{"kind" => "approval"}] do
          try do
            Helyx.Hook.ask(request)
          rescue
            ArgumentError -> :raised
          end
        end

      send(test, {:asked, raised})
      :allow
    end)

    result_message(core)
    assert_receive {:asked, [:raised, :raised]}
  end
end
