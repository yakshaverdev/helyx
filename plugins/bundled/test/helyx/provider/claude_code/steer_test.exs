defmodule Helyx.Provider.ClaudeCode.SteerTest do
  # A steer: a user line that the program reads during a turn.
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Provider.ClaudeCode

  @moduletag :tmp_dir

  setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

  # A margin for load on a timer that the test reads.
  @load_ms 2_000

  describe "a steer" do
    # A turn that streams "a" and has no `result` yet.
    defp streaming(work), do: running(work, &(&1.turn.open? and &1.init?))

    defp steer(state), do: request(state, {:steer, "t1", "s1", "more"})

    test "after the terminal answers :rejected and writes nothing", %{bin: bin, work: work} do
      turn(bin, 1, 1, reply("ok"))

      state = running(work, &(&1.turn == nil))
      assert {from, [{:reply, from, :rejected}], _state} = steer(state)
      assert [%{"type" => "user"}] = stdin(bin, 1)
    end

    test "written before the result keeps the turn until its start and the next result",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [delta("a")])
      # The fake reads the steer line, then gives the first result.
      turn(bin, 1, 2, [result("a"), lifecycle("started"), delta("b"), result("b")])

      assert {from, [{:reply, from, :ok}], state} = steer(streaming(work))
      {actions, _state} = pump(ClaudeCode, state, [], &ended?/1)
      assert [prompt, %{"type" => "user", "uuid" => uuid, "message" => message}] = stdin(bin, 1)
      assert uuid != prompt["uuid"]
      assert %{"role" => "user", "content" => [%{"type" => "text", "text" => "more"}]} = message

      assert [
               {:message_end, :end_turn, _},
               {:user_message, "s1"},
               {:text_delta, "b"},
               {:done, _}
             ] =
               actions |> events_of() |> Enum.reject(&match?({:resume, _, _}, &1))
    end

    test "that starts after a tool result gives user_message after the result",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [tool_use("c1", %{command: "ls"})])
      turn(bin, 1, 2, [tool_result("c1", "out"), lifecycle("started"), delta("b"), result("b")])

      state = running(work, &(&1.turn.calls? and &1.init?))
      {_from, _actions, state} = steer(state)
      {actions, _state} = pump(ClaudeCode, state, [], &ended?/1)

      assert [
               {:message_end, :tool_use, _},
               {:tool_result, "c1", {:ok, "out"}},
               {:user_message, "s1"},
               {:text_delta, "b"},
               {:done, _}
             ] = events_of(actions)
    end

    test "with no start after a held result stops the provider process",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [delta("a")])
      turn(bin, 1, 2, [result("a")])

      {_from, _actions, state} = steer(streaming(work))
      state = settle(ClaudeCode, state, &(&1.turn.wait != nil))
      # The timer is armed for 5,000 ms; the test gives its message at once.
      remaining = :erlang.read_timer(state.turn.wait)
      assert remaining <= 5_000 and remaining > 5_000 - @load_ms
      :erlang.cancel_timer(state.turn.wait)
      send(self(), {:timeout, state.turn.wait, :steer_wait})
      assert {[{:stop, :steer_not_started}], _state} = pump(ClaudeCode, state, [], &ended?/1)
    end

    test "an interrupt of a held turn answers :ok at the control response",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [delta("a")])
      turn(bin, 1, 2, [result("a")])
      script(bin, "ctl.1", [interrupted([], ["@U@"])])

      {_from, _actions, state} = steer(streaming(work))
      state = settle(ClaudeCode, state, &(&1.turn.wait != nil))
      assert {:ok, _actions} = interrupt(state)
    end
  end
end
