defmodule Helyx.Provider.ClaudeCode.InterruptTest do
  # The interrupt request of a turn, and its answers.
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Provider.ClaudeCode

  @moduletag :tmp_dir

  setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

  describe "an interrupt" do
    defp started?(state), do: state.turn.messages == nil and state.init?

    test "answers :ok after the control response and the result", %{bin: bin, work: work} do
      turn(bin, 1, 1, begin())
      script(bin, "ctl.1", [interrupted(), aborted()])

      assert {:ok, actions} = interrupt(running(work, &started?/1))
      refute Enum.any?(actions, &match?({:event, _, {:error, _}}, &1))
    end

    test "waits for the init line after the start of the turn", %{bin: bin, work: work} do
      turn(bin, 1, 1, [lifecycle("started")], "(sleep 0.3; out out.late) &\n")
      File.write!(Path.join(bin, "out.late"), init() <> "\n")
      script(bin, "ctl.1", [interrupted(), aborted()])

      state = running(work, &(&1.turn.messages == nil))
      refute state.init?
      assert {:ok, _actions} = interrupt(state)
    end

    test "of a turn whose result comes before the control response answers :ok",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin())
      script(bin, "ctl.1", [result("done"), interrupted()])

      assert {:ok, actions} = interrupt(running(work, &started?/1))
      refute Enum.any?(actions, &match?({:event, _, {:done, _}}, &1))
    end

    test "of a turn that ended answers :ok and writes nothing", %{bin: bin, work: work} do
      turn(bin, 1, 1, reply("ok"))

      state = running(work, &(&1.turn == nil))
      assert {from, [{:reply, from, :ok}], _state} = request(state, {:interrupt, "t1"})
      assert [%{"type" => "user"}] = stdin(bin, 1)
    end

    test "that cancels the turn's line answers :ok with no result", %{bin: bin, work: work} do
      # The capabilities are known before the start, as in a later turn.
      turn(bin, 1, 1, [lifecycle("queued"), init()])
      script(bin, "ctl.1", [interrupted([], ["@U@"])])

      assert {:ok, _actions} = interrupt(running(work, & &1.init?))
      assert [%{"type" => "user"}, %{"type" => "control_request"}] = stdin(bin, 1)
    end

    test "after a replay waits for the start of the turn's line", %{bin: bin, work: work} do
      go = Path.join(bin, "go")
      rest = Path.join(bin, "out.rest")
      # The result of a failed replay line comes before the start.
      File.write!(rest, [replay_failed(), "\n", lifecycle("started"), "\n", init(), "\n"])
      gate = ~s(while [ ! -e "#{go}" ]; do sleep 0.05; done; out out.rest\n)
      turn(bin, 1, 1, [init()], gate)
      script(bin, "ctl.1", [interrupted(), aborted()])

      history = replay_history()

      {_from, _actions, state} =
        request(harness(work), {:turn, "t1", %Helyx.Context{messages: history}})

      state = settle(ClaudeCode, state, & &1.init?)
      assert {from, [], state} = request(state, {:interrupt, "t1"})
      assert state.turn.interrupt.request_id == nil

      File.write!(go, "")
      assert {actions, _state} = pump(ClaudeCode, state, [], replied?(from))
      assert {:reply, ^from, :ok} = List.last(actions)
      assert %{"type" => "control_request"} = List.last(stdin(bin, 1))
    end

    test "of a turn that ends before the interrupt is written answers :ok and writes nothing",
         %{bin: bin, work: work} do
      go = Path.join(bin, "go")
      File.write!(Path.join(bin, "out.rest"), [result("done"), "\n"])
      gate = ~s(while [ ! -e "#{go}" ]; do sleep 0.05; done; out out.rest\n)
      turn(bin, 1, 1, [lifecycle("started")], gate)

      state = running(work, &(&1.turn.messages == nil))
      assert {from, [], state} = request(state, {:interrupt, "t1"})

      File.write!(go, "")
      assert {actions, _state} = pump(ClaudeCode, state, [], replied?(from))
      assert {:reply, ^from, :ok} = List.last(actions)
      assert [%{"type" => "user"}] = stdin(bin, 1)
    end

    test "with work still queued answers an error", %{bin: bin, work: work} do
      turn(bin, 1, 1, begin())
      script(bin, "ctl.1", [interrupted(["q1"])])

      assert {{:error, :still_queued}, _actions} = interrupt(running(work, &started?/1))
    end

    # Only an exact `[]` confirms that no queued work remains.
    for {name, body} <- [
          {"a missing", %{cancelled: []}},
          {"a null", %{still_queued: nil, cancelled: []}},
          {"a non-list", %{still_queued: "none", cancelled: []}},
          {"a missing response", nil}
        ] do
      test "with #{name} still_queued answers an error", %{bin: bin, work: work} do
        turn(bin, 1, 1, begin())
        response = %{subtype: "success", request_id: "@R@", response: unquote(Macro.escape(body))}
        script(bin, "ctl.1", [j(%{type: "control_response", response: response}), aborted()])

        assert {{:error, :still_queued}, _actions} = interrupt(running(work, &started?/1))
      end
    end

    test "with an error response answers the error, cut", %{bin: bin, work: work} do
      turn(bin, 1, 1, begin())
      long = String.duplicate("é", 1_500)

      error =
        j(%{
          type: "control_response",
          response: %{subtype: "error", request_id: "@R@", error: long}
        })

      script(bin, "ctl.1", [error])

      assert {{:error, {:interrupt, text}}, _actions} = interrupt(running(work, &started?/1))
      assert byte_size(text) == 2_000 and String.valid?(text)
    end
  end
end
