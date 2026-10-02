defmodule Helyx.Provider.Codex.SteerTest do
  # Steers of a running turn.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.Codex

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  describe "a steer" do
    # A turn that streamed "a" and did not complete.
    defp streaming(bin, work) do
      fresh(bin, 1, tid(), [delta(tid(), "msg_1", "a")])
      {:ok, state} = connect(work)

      {_turn, actions, state} =
        ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})

      {_actions, state} =
        pump(
          Codex,
          state,
          actions,
          &Enum.any?(&1, fn a -> match?({:event, _, {:text_delta, _}}, a) end)
        )

      state
    end

    defp steer(state) do
      {from, [], state} = ask(state, {:steer, "t1", "s1", "more"})
      {actions, _state} = pump(Codex, state, [], &turn_ended?/1)
      {from, actions}
    end

    test "after turn/completed answers :rejected and sends nothing", %{bin: bin, work: work} do
      fresh(bin, 1, tid(), reply(tid(), "ok"))
      {:ok, state} = connect(work)

      {_turn, _, state} =
        ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})

      {_actions, state} = pump(Codex, state, [], &turn_ended?/1)
      assert {from, [{:reply, from, :rejected}], state} = ask(state, {:steer, "t1", "s1", "more"})
      close(state)
      assert request(bin, 1, "turn/steer") == nil
    end

    test "that crosses the turn's end answers :rejected on the exact error",
         %{bin: bin, work: work} do
      error = %{code: -32_600, message: "no active turn to steer"}
      on(bin, 1, "turn/steer", [j(%{id: "@", error: error}), turn_end(tid(), "completed")])

      {from, actions} = steer(streaming(bin, work))
      assert [{:reply, ^from, :rejected}, {:event, "t1", {:done, _}}] = actions
    end

    test "with another error answers it, as unknown", %{bin: bin, work: work} do
      error = %{code: -32_600, message: "expected active turn id turn1 but found turn2"}
      on(bin, 1, "turn/steer", [j(%{id: "@", error: error}), turn_end(tid(), "completed")])

      {from, actions} = steer(streaming(bin, work))

      assert [{:reply, ^from, {:error, {:codex, "turn/steer", "expected active" <> _}}}, _done] =
               actions
    end

    # #224: the turn's end stops the harness process for its open tool item
    # while the steer's answer is open. The steer gets no answer and fails
    # with the stop, so the session never sends it again.
    test "with an open answer at a turn end that stops the harness process gets no answer",
         %{bin: bin, work: work} do
      fresh(bin, 1, tid(), [delta(tid(), "msg_1", "a"), started(tid(), search())])
      on(bin, 1, "turn/steer", [turn_end(tid(), "completed")])
      {:ok, state} = connect(work)
      {_turn, actions, state} = turn_on(state)

      {_actions, state} =
        pump(
          Codex,
          state,
          actions,
          &Enum.any?(&1, fn a -> match?({:event, _, {:tool_call, _}}, a) end)
        )

      {from, [], state} = ask(state, {:steer, "t1", "s1", "more"})
      {actions, _state} = pump(Codex, state, [], fn _ -> false end)

      assert {:stop, :tool_running} = List.last(actions)
      refute Enum.any?(actions, &match?({:reply, ^from, _}, &1))
    end

    test "that the program takes gives :ok, then its user_message once", %{bin: bin, work: work} do
      item = %{type: "userMessage", id: "u1", clientId: "s1", content: []}

      on(bin, 1, "turn/steer", [
        j(%{id: "@", result: %{turnId: "turn1"}}),
        started(tid(), item),
        completed(tid(), item),
        turn_end(tid(), "completed")
      ])

      {from, actions} = steer(streaming(bin, work))

      assert [
               {:reply, ^from, :ok},
               {:event, "t1", {:user_message, "s1", "more"}},
               {:event, "t1", {:done, _}}
             ] =
               actions

      assert %{
               "params" => %{
                 "threadId" => tid(),
                 "expectedTurnId" => "turn1",
                 "clientUserMessageId" => "s1",
                 "input" => [%{"type" => "text", "text" => "more"}]
               }
             } = request(bin, 1, "turn/steer")
    end
  end
end
