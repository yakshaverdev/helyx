defmodule Helyx.Session.UIBlocksApprovalsTest do
  # UI blocks beside harness approvals (docs/features/ui-blocks.md,
  # docs/features/hooks.md, "Harness approvals" and "The owner of a call
  # id"): a call that an approval request named is the provider's own, so
  # its provider blocks show; a call that a Helyx tool request named is a
  # Helyx call, so its provider blocks are dropped and an approval for it
  # is denied, also when the call opened after Core answered the request.
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase, only: [start_core: 1]

  alias Helyx.Message.ToolCall
  alias Helyx.Session
  alias Helyx.Test.Hook
  alias Helyx.Test.UIBlocks.Show

  @load_ms 300
  @own %ToolCall{id: "p1", name: "fileChange", arguments: %{}}

  defp core do
    core = start_core([Helyx.Test.Connected, Show, Hook.A])
    test = self()
    Process.register(spawn_link(fn -> forward(test) end), Hook.test_name(core))
    Process.register(spawn_link(fn -> forward(test) end), Helyx.Test.Connected.controller(core))
    core
  end

  defp forward(pid) do
    receive do
      message -> send(pid, message)
    end

    forward(pid)
  end

  defp turn(core) do
    {:ok, session} = Session.start(core, model: "conn/hang")
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, pid, {:turn, turn_id, _context}}
    %{session: session, pid: pid, turn_id: turn_id}
  end

  defp events(%{pid: pid, turn_id: turn_id}, events),
    do: send(pid, {:batch, Enum.map(events, &{:event, turn_id, &1})})

  defp approval(%{pid: pid, turn_id: turn_id}, approval_id) do
    assert_receive {:conn, :approval, ^pid, {:approval, ^turn_id, ^approval_id, decision}}
    decision
  end

  defp tool_result(%{pid: pid, turn_id: turn_id}, id) do
    assert_receive {:conn, :tool_result, ^pid, {:tool_result, ^turn_id, ^id, result}}
    result
  end

  defp ui(call_id, key, text), do: %{call_id: call_id, key: key, block: Show.block(text)}

  defp blocks(%{pid: pid, session: session}) do
    send(pid, {:ping, self()})
    assert_receive :pong
    snapshot(session).ui_blocks
  end

  test "a call with an approval owner shows its provider blocks, while its chain runs and after" do
    turn = turn(core())
    events(turn, [{:tool_call, @own}, {:approval, "a1", "p1"}])
    assert approval(turn, "a1") == :allow

    events(turn, [{:ui_block, "p1", "k", Show.block("own")}])
    assert of_type(collect_until(:ui_block), :ui_block) == [ui("p1", "k", "own")]
  end

  test "an approval call and a Helyx call in one turn: each keeps its owner for its blocks" do
    turn = turn(core())
    c1 = %ToolCall{id: "c1", name: "show", arguments: %{"shows" => [["t", "tool"]]}}

    events(turn, [
      {:tool_call, @own},
      {:tool_call, c1},
      {:approval, "a1", "p1"},
      {:tool_request, "c1", "show", c1.arguments}
    ])

    assert approval(turn, "a1") == :allow
    assert tool_result(turn, "c1") == {:ok, ":ok"}

    events(turn, [
      {:ui_block, "p1", "k", Show.block("own")},
      {:ui_block, "c1", "p", Show.block("provider")}
    ])

    assert blocks(turn) == [ui("c1", "t", "tool"), ui("p1", "k", "own")]

    # An approval for the Helyx call is denied, and no chain runs for it.
    events(turn, [{:approval, "a2", "c1"}])
    assert {:deny, reason} = approval(turn, "a2")
    assert reason =~ "no open call"
  end

  test "a Helyx request for a call with an approval owner stops the provider, with blocks or not" do
    turn = turn(core())
    ref = Process.monitor(turn.pid)

    events(turn, [
      {:tool_call, @own},
      {:approval, "a1", "p1"},
      {:ui_block, "p1", "k", Show.block("own")}
    ])

    assert approval(turn, "a1") == :allow
    collect_until(:ui_block)
    events(turn, [{:tool_request, "p1", "show", %{"shows" => []}}])
    assert %{data: %{outcome: :error, error: error}} = List.last(collect_until(:turn_end))
    assert error =~ "tool_request"
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  # The accepted hole of #881 closes within the bound of the Helyx call ids.
  test "an approval for a call that opened after Core answered its Helyx request is denied" do
    turn = turn(core())
    args = %{"shows" => []}
    events(turn, [{:tool_request, "c1", "show", args}])
    assert tool_result(turn, "c1") == {:ok, ""}

    events(turn, [
      {:tool_call, %ToolCall{id: "c1", name: "show", arguments: args}},
      {:approval, "a1", "c1"}
    ])

    assert {:deny, reason} = approval(turn, "a1")
    assert reason =~ "no open call"
    refute_receive {:hook, Hook.A, :before_tool, %{provider: "conn"}}, @load_ms
  end

  test "an approval for the id of an earlier Helyx call of the turn, in a later message, is denied" do
    turn = turn(core())
    c1 = %ToolCall{id: "c1", name: "show", arguments: %{"shows" => []}}
    events(turn, [{:tool_call, c1}, {:tool_request, "c1", "show", c1.arguments}])
    result = tool_result(turn, "c1")
    events(turn, [{:tool_result, "c1", result}])
    collect_until(:tool_execution_end)

    # A later message reuses the id for a call of the provider's own tools.
    events(turn, [{:tool_call, %{@own | id: "c1"}}, {:approval, "a1", "c1"}])
    assert {:deny, reason} = approval(turn, "a1")
    assert reason =~ "no open call"
    refute_receive {:hook, Hook.A, :before_tool, %{provider: "conn"}}, @load_ms
  end
end
