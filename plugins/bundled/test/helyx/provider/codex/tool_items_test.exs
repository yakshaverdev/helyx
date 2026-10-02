defmodule Helyx.Provider.Codex.ToolItemsTest do
  # Tool items: open items of other types, items that run together, and cut results.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.Events

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

  test "a completion of an open tool item with another type stops the provider process",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [
      started(tid(), command("exec-1", %{status: "inProgress"})),
      completed(tid(), %{search() | id: "exec-1"}),
      turn_end(tid(), "completed")
    ])

    assert {:stop, {:malformed, "item/completed"}} =
             List.last(run_direct([Message.user("go")], work))
  end

  # Codex can run tool items side by side: the message of both calls
  # closes once, before the first result.
  test "two tool items that run together close one message", %{bin: bin, work: work} do
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
             {:message_end, :tool_use, _},
             {:tool_result, "a", {:ok, "out"}},
             {:tool_result, "b", {:ok, "out"}},
             {:done, _}
           ] = run_direct([Message.user("go")], work)
  end

  test "a tool result over the limits arrives cut, with the notice", %{bin: bin, work: work} do
    big = String.duplicate("x\n", 3_000)

    fresh(bin, 1, tid(), [
      completed(tid(), command("a", %{done() | aggregatedOutput: big})),
      turn_end(tid(), "completed")
    ])

    events = run_direct([Message.user("go")], work)
    assert [text] = for({:tool_result, "a", {:ok, t}} <- events, do: t)
    assert text == Helyx.Text.truncate(big, :tail)
    assert text =~ "[truncated: showing lines 1001-3000 of 3000]"
  end

  # A message that closes while a call of the message before it still
  # runs waits for that call's result, so the session does not abort it.
  test "a message that closes before an earlier call's result waits for it",
       %{bin: bin, work: work} = ctx do
    lines = [
      started(tid(), command("a", %{status: "inProgress"})),
      started(tid(), command("b", %{status: "inProgress"})),
      completed(tid(), command("a", done())),
      delta(tid(), "msg_x", "x"),
      started(tid(), command("d", %{status: "inProgress"})),
      completed(tid(), command("d", done())),
      completed(tid(), command("b", done())),
      turn_end(tid(), "completed")
    ]

    fresh(bin, 1, tid(), lines)
    fresh(bin, 2, tid(), lines)

    assert [
             {:resume, tid(), 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "a", {:ok, "out"}},
             {:text_delta, "x"},
             {:tool_call, %{id: "d"}},
             {:tool_result, "b", {:ok, "out"}},
             {:message_end, :tool_use, _},
             {:tool_result, "d", {:ok, "out"}},
             {:done, _}
           ] = run_direct([Message.user("go")], work)

    # The same run in a session: every real result joins the transcript,
    # each before the next message.
    events = ctx |> start() |> prompt("go")

    assert [{"a", "out"}, {"b", "out"}, {"d", "out"}] =
             for(
               %{message: m} <- of_type(events, :tool_execution_end),
               do: {m.tool_call_id, Message.text(m)}
             )

    assert [
             %Message{role: :user},
             %Message{role: :assistant, content: [%{id: "a"}, %{id: "b"}]},
             %Message{role: :assistant, content: [%Message.Text{text: "x"}, %{id: "d"}]},
             # The session closes the turn with an empty message when the
             # turn ends right after a result (as before this change).
             %Message{role: :assistant, content: [], stop_reason: :end_turn}
           ] = messages(events)
  end

  # A result of a held message must not wait behind a later held message.
  test "a held result goes before a later message's end", %{bin: bin, work: work} = ctx do
    lines = [
      started(tid(), command("a", %{status: "inProgress"})),
      started(tid(), command("b", %{status: "inProgress"})),
      completed(tid(), command("b", done())),
      started(tid(), command("c", %{status: "inProgress"})),
      started(tid(), command("e", %{status: "inProgress"})),
      completed(tid(), command("c", done())),
      started(tid(), command("d", %{status: "inProgress"})),
      completed(tid(), command("d", done())),
      completed(tid(), command("e", done())),
      completed(tid(), command("a", done())),
      delta(tid(), "msg_y", "ok"),
      turn_end(tid(), "completed")
    ]

    fresh(bin, 1, tid(), lines)
    fresh(bin, 2, tid(), lines)

    assert [
             {:resume, tid(), 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "b", _},
             {:tool_call, %{id: "c"}},
             {:tool_call, %{id: "e"}},
             {:tool_result, "a", _},
             {:message_end, :tool_use, _},
             {:tool_result, "c", _},
             {:tool_result, "e", _},
             {:tool_call, %{id: "d"}},
             {:message_end, :tool_use, _},
             {:tool_result, "d", _},
             {:text_delta, "ok"},
             {:done, _}
           ] = run_direct([Message.user("go")], work)

    events = ctx |> start() |> prompt("go")

    assert ["out", "out", "out", "out", "out"] =
             for(%{message: m} <- of_type(events, :tool_execution_end), do: Message.text(m))
  end
end
