defmodule Helyx.Provider.Codex.HeldEventsTest do
  # Events held behind a late tool result, and the cap of the held events.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake

  alias Helyx.Message

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  # The late result of "b" sends what was held. A tool item open at the
  # turn's end stops the provider process (#224), so a turn that ends holds
  # nothing.
  test "a late result sends the held events", %{bin: bin, work: work} do
    fresh(
      bin,
      1,
      tid(),
      held(tid()) ++ [completed(tid(), search()), turn_end(tid(), "completed")]
    )

    assert [
             {:resume, tid(), 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "a", {:ok, "out"}},
             {:tool_call, %{id: "d"}},
             {:tool_result, "b", _},
             {:message_end, :tool_use, _},
             {:tool_result, "d", {:ok, "out"}},
             {:done, _}
           ] = run_direct([Message.user("go")], work)
  end

  # The events that go out before the `message_end` of "d", which waits for
  # "b". The held events are dropped with the turn, as at an abort.
  @sent [
    {:resume, tid(), 0},
    {:tool_call,
     %Message.ToolCall{
       id: "a",
       name: "commandExecution",
       arguments: %{"command" => "/bin/zsh -lc ls", "cwd" => "/work"}
     }},
    {:tool_call, %Message.ToolCall{id: "b", name: "webSearch", arguments: %{"query" => "x"}}},
    {:message_end, :tool_use, %{}},
    {:tool_result, "a", {:ok, "out"}},
    {:tool_call,
     %Message.ToolCall{
       id: "d",
       name: "commandExecution",
       arguments: %{"command" => "/bin/zsh -lc ls", "cwd" => "/work"}
     }}
  ]

  defp held(tid) do
    [
      started(tid, command("a", %{status: "inProgress"})),
      started(tid, search()),
      completed(tid, command("a", done())),
      started(tid, command("d", %{status: "inProgress"})),
      completed(tid, command("d", done()))
    ]
  end

  test "an exit during a turn stops the provider process", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), held(tid()), "exit 3\n")
    assert run_direct([Message.user("go")], work) == @sent ++ [{:stop, {:codex_exit, 3}}]
  end

  test "a line over the cap stops the provider process", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), held(tid()) ++ [String.duplicate("x", 16 * 1024 * 1024 + 1)])

    assert run_direct([Message.user("go")], work) ==
             @sent ++ [{:stop, {:line_over_limit, 16_777_216}}]
  end

  # The `message_end` of "d" waits for "b", so it and every event after it
  # is held: the end, the result, and 9,998 deltas make 10,000, the cap.
  # The result of "b" then sends them.
  defp held_run(bin, work, count) do
    deltas = for i <- 1..count, do: delta(tid(), "msg_y", "#{i}")
    ending = [completed(tid(), search()), turn_end(tid(), "completed")]
    fresh(bin, 1, tid(), held(tid()) ++ deltas ++ ending)
    {sent, rest} = Enum.split(run_direct([Message.user("go")], work), length(@sent))
    assert sent == @sent
    rest
  end

  test "the held events one under the cap go out at the late result", %{bin: bin, work: work} do
    assert [{:tool_result, "b", _}, {:message_end, _, _}, {:tool_result, "d", _} | rest] =
             held_run(bin, work, 9_997)

    assert {texts, [{:done, _}]} = Enum.split(rest, -1)
    assert texts == for(i <- 1..9_997, do: {:text_delta, "#{i}"})
  end

  test "the held events at the cap go out at the late result", %{bin: bin, work: work} do
    assert [_, _, _ | rest] = held_run(bin, work, 9_998)
    assert {texts, [{:done, _}]} = Enum.split(rest, -1)
    assert texts == for(i <- 1..9_998, do: {:text_delta, "#{i}"})
  end

  # The next delta is over the cap: nothing held goes out.
  test "the held events over the cap stop the provider process", %{bin: bin, work: work} do
    assert held_run(bin, work, 9_999) == [{:stop, {:held_over_limit, 10_000}}]
  end
end
