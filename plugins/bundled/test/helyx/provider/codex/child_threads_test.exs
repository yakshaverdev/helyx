defmodule Helyx.Provider.Codex.ChildThreadsTest do
  # Child threads of sub-agents (#224).
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.Codex

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  # Sub-agents (#224). A `subAgentActivity` item of the parent thread, as
  # the research note records it.
  @child "019a0000-0000-7000-8000-00000000000c"

  defp agent(kind, fields \\ %{}) do
    item =
      Map.merge(
        %{type: "subAgentActivity", id: "call_#{kind}", kind: kind, agentThreadId: @child},
        fields
      )

    [started(tid(), item), completed(tid(), item)]
  end

  test "a child thread with open work at the turn's end stays with the program: the idle close answers :busy until its completed item",
       %{bin: bin, work: work} do
    tail = after_go(bin, "child_done", agent("completed"))
    fresh(bin, 1, tid(), agent("started") ++ reply(tid(), "Spawned."), tail)
    {:ok, state} = connect(work)
    {_turn, _, state} = turn_on(state)
    {actions, state} = pump(Codex, state, [], &turn_ended?/1)
    assert {:done, %{stop_reason: :end_turn}} = List.last(events(actions))

    assert {from, [{:reply, from, :busy}], state} = ask(state, :idle_close)

    # The completed item has the turn id of the ended turn.
    go(bin)
    # The lines give no action.
    state = settle(Codex, state, &(&1.agents == %{}), &(&1 == []))
    {from, [], state} = ask(state, :idle_close)
    assert {[{:reply, ^from, :ok}], _state} = pump(Codex, state, [], replied?(from))
  end

  test "an interrupt while a child thread of the turn has open work answers an error at once and sends nothing",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), agent("started") ++ message(tid(), "msg_1", "Waiting."))
    {:ok, state} = connect(work)
    {_turn, _, state} = turn_on(state)

    {_actions, state} =
      pump(Codex, state, [], &Enum.any?(&1, fn a -> match?({:event, _, {:text_delta, _}}, a) end))

    assert {from, [{:reply, from, {:error, :agent_running}}], _state} =
             ask(state, {:interrupt, "t1"})

    assert request(bin, 1, "turn/interrupt") == nil
  end

  test "a late subAgentActivity item with another turn id keeps the child with its running turn (#244)",
       %{bin: bin, work: work} do
    late = as_turn(agent("interacted"), "turn0")
    fresh(bin, 1, tid(), agent("started") ++ late ++ message(tid(), "msg_1", "Waiting."))
    {:ok, state} = connect(work)
    {_turn, _, state} = turn_on(state)

    {_actions, state} =
      pump(Codex, state, [], &Enum.any?(&1, fn a -> match?({:event, _, {:text_delta, _}}, a) end))

    assert state.agents == %{@child => "turn1"}

    assert {from, [{:reply, from, {:error, :agent_running}}], _state} =
             ask(state, {:interrupt, "t1"})
  end

  test "an item with the running turn id moves a child of an earlier turn to the running turn, and a late item of the earlier turn does not move it back (#244)",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), agent("started") ++ reply(tid(), "Spawned."))
    asked = as_turn(message(tid(), "msg_2", "Asked."), "turn2")
    later = as_turn(agent("interacted"), "turn2") ++ agent("interrupted") ++ asked
    on(bin, 1, "turn/start", as_turn(turn(tid(), []), "turn2") ++ later, "", 2)
    {:ok, state} = connect(work)
    {_turn, _, state} = turn_on(state)
    {_actions, state} = pump(Codex, state, [], &turn_ended?/1)
    {_turn, _, state} = turn_on(state, "t2")

    {_actions, state} =
      pump(Codex, state, [], &Enum.any?(&1, fn a -> match?({:event, _, {:text_delta, _}}, a) end))

    assert {from, [{:reply, from, {:error, :agent_running}}], _state} =
             ask(state, {:interrupt, "t2"})
  end

  test "a child thread that starts after the interrupt stops the provider process at the turn's end",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [])

    on(
      bin,
      1,
      "turn/interrupt",
      agent("started") ++ [j(%{id: "@", result: %{}}), turn_end(tid(), "interrupted")]
    )

    {:ok, state} = connect(work)
    {_turn, _, state} = turn_on(state)
    {from, [], state} = ask(state, {:interrupt, "t1"})
    {actions, _state} = pump(Codex, state, [], fn _ -> false end)

    assert {:stop, :agent_running} = List.last(actions)
    refute Enum.any?(actions, &match?({:reply, ^from, _}, &1))
  end

  test "a child thread of an earlier turn is background work: an abort of a later turn interrupts the turn and keeps the program",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), agent("started") ++ reply(tid(), "Spawned."))
    on(bin, 1, "turn/start", as_turn(turn(tid(), []), "turn2"), "", 2)

    on(bin, 1, "turn/interrupt", [
      j(%{id: "@", result: %{}}),
      hd(as_turn([turn_end(tid(), "interrupted")], "turn2"))
    ])

    {:ok, state} = connect(work)
    {_turn, _, state} = turn_on(state)
    {_actions, state} = pump(Codex, state, [], &turn_ended?/1)
    {turn, _, state} = turn_on(state, "t2")
    {_actions, state} = pump(Codex, state, [], replied?(turn))
    {from, [], state} = ask(state, {:interrupt, "t2"})
    {actions, state} = pump(Codex, state, [], replied?(from))

    assert {:reply, from, :ok} in actions
    assert %{"params" => %{"turnId" => "turn2"}} = request(bin, 1, "turn/interrupt")
    assert {from, [{:reply, from, :busy}], _state} = ask(state, :idle_close)
  end

  test "a subAgentActivity item without its full shape stops the provider process",
       %{bin: bin, work: work} do
    bad = [%{kind: "paused"}, %{kind: nil}, %{agentThreadId: nil}, %{agentThreadId: 7}]

    for {fields, n} <- Enum.with_index(bad, 1) do
      fresh(bin, n, tid(), Enum.take(agent("started", fields), 1))

      assert {:stop, {:malformed, "item/started"}} =
               List.last(run_direct([Message.user("go")], work))
    end
  end
end
