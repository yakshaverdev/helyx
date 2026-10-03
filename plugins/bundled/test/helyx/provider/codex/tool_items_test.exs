defmodule Helyx.Provider.Codex.ToolItemsTest do
  # Tool items: open items of other types, items that run together, their order, and cut
  # results.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake

  alias Helyx.Message

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  test "an open tool item of another type at the turn's end stops the provider process",
       %{bin: bin, work: work} do
    wait = %{
      type: "collabAgentToolCall",
      id: "call_wait",
      tool: "wait",
      status: "inProgress",
      senderThreadId: tid(),
      receiverThreadIds: [],
      agentsStates: %{}
    }

    fresh(bin, 1, tid(), [started(tid(), wait), turn_end(tid(), "completed")])

    # The stop drops the events of its chunk.
    assert {:stop, :tool_running} = List.last(run_direct([Message.user("go")], work))
  end

  # Codex can run tool items side by side; the session closes the message
  # of both calls at the first result.
  test "two tool items that run together give their results", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [
      started(tid(), command("a", %{status: "inProgress"})),
      started(tid(), command("b", %{status: "inProgress"})),
      completed(tid(), command("a", done())),
      completed(tid(), command("b", done())),
      turn_end(tid(), "completed")
    ])

    assert [
             {:resume, tid(), 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:tool_result, "a", {:ok, "out"}},
             {:tool_result, "b", {:ok, "out"}},
             {:done, _}
           ] = run_direct([Message.user("go")], work)
  end

  test "a tool result over the limits arrives cut, with the notice", %{bin: bin, work: work} do
    big = String.duplicate("x\n", 3_000)

    fresh(bin, 1, tid(), [
      started(tid(), command("a", %{status: "inProgress"})),
      completed(tid(), command("a", %{done() | aggregatedOutput: big})),
      turn_end(tid(), "completed")
    ])

    events = run_direct([Message.user("go")], work)
    assert [text] = for({:tool_result, "a", {:ok, t}} <- events, do: t)
    assert text == Helyx.Text.truncate(big, :tail)
    assert text =~ "[truncated: showing lines 1001-3000 of 3000]"
  end

  test "an exit during a turn stops the provider process", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [started(tid(), command("a", %{status: "inProgress"}))], "exit 3\n")
    assert {:stop, {:codex_exit, 3}} = List.last(run_direct([Message.user("go")], work))
  end
end
