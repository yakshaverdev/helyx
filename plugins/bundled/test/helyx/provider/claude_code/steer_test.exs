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
    defp streaming(work), do: running(work, &(&1.turn.open? and &1.caps != nil))

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
               {:user_message, "s1", "more"},
               {:text_delta, "b"},
               {:done, _}
             ] =
               actions |> events_of() |> Enum.reject(&match?({:harness_session, _, _}, &1))
    end

    defp failed(errors) do
      j(%{
        type: "result",
        subtype: "error_during_execution",
        is_error: true,
        errors: errors,
        queued_turn_count: 0
      })
    end

    # The events of a turn whose held `result` is `held` and whose steer
    # then starts and succeeds.
    defp held_turn(bin, work, held) do
      turn(bin, 1, 1, begin() ++ [delta("a")])
      turn(bin, 1, 2, [held, lifecycle("started"), delta("b"), result("b")])

      {_from, _actions, state} = steer(streaming(work))
      {actions, _state} = pump(ClaudeCode, state, [], &ended?/1)
      actions |> events_of() |> Enum.reject(&match?({:harness_session, _, _}, &1))
    end

    # The error `result` before the steer's start is not the terminal; the
    # steer makes it obsolete, and it goes out as a notice (#241).
    test "an error result held for the steer goes out as a notice at the steer's start",
         %{bin: bin, work: work} do
      assert [
               {:message_end, :end_turn, _},
               {:notice, "the turn before the steer failed: error_during_execution: boom"},
               {:user_message, "s1", "more"},
               {:text_delta, "b"},
               {:done, _}
             ] = held_turn(bin, work, failed(["boom"]))
    end

    # The notice bound is 2,000 bytes (`HarnessIO.cap_error/1`); a cut of a
    # 3,000-byte multibyte error stays valid UTF-8.
    test "a held error over the notice bound is cut to 2,000 bytes", %{bin: bin, work: work} do
      events = held_turn(bin, work, failed([String.duplicate("é", 1_500)]))
      assert [text] = for({:notice, text} <- events, do: text)
      assert byte_size(text) <= 2_000 and byte_size(text) > 1_990 and String.valid?(text)
    end

    # A program turn's `result` never changes `held` (#241, Codex round 2).
    defp program(line) do
      origin = %{kind: "task-notification", producer: "session-task"}
      j(Map.merge(JSON.decode!(line), %{"origin" => origin, "user_message_uuid" => nil}))
    end

    defp program_held_turn(bin, work, held, program_line) do
      turn(bin, 1, 1, begin() ++ [delta("a")])

      turn(bin, 1, 2, [
        held,
        program_line,
        lifecycle("started"),
        delta("b"),
        result("b")
      ])

      {_from, _actions, state} = steer(streaming(work))
      {actions, _state} = pump(ClaudeCode, state, [], &ended?/1)
      events_of(actions)
    end

    test "a program turn's error result after a held success gives no notice",
         %{bin: bin, work: work} do
      events = program_held_turn(bin, work, result("a"), program(failed(["late"])))
      refute Enum.any?(events, &match?({:notice, _}, &1))
      assert {:user_message, "s1", "more"} in events
    end

    test "a program turn's success result keeps a held error", %{bin: bin, work: work} do
      events = program_held_turn(bin, work, failed(["boom"]), program(result("p")))

      assert [{:notice, "the turn before the steer failed: error_during_execution: boom"}] =
               for({:notice, _} = notice <- events, do: notice)
    end

    test "a success result held for the steer gives no notice", %{bin: bin, work: work} do
      refute Enum.any?(held_turn(bin, work, result("a")), &match?({:notice, _}, &1))
    end

    test "that starts after a tool result gives user_message after the result",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [tool_use("c1", %{command: "ls"})])
      turn(bin, 1, 2, [tool_result("c1", "out"), lifecycle("started"), delta("b"), result("b")])

      state = running(work, &(&1.turn.calls? and &1.caps != nil))
      {_from, _actions, state} = steer(state)
      {actions, _state} = pump(ClaudeCode, state, [], &ended?/1)

      assert [
               {:message_end, :tool_use, _},
               {:tool_result, "c1", {:ok, "out"}},
               {:user_message, "s1", "more"},
               {:text_delta, "b"},
               {:done, _}
             ] = events_of(actions)
    end

    test "with no start after a held result stops the harness process",
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
