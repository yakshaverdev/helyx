defmodule Helyx.Provider.Codex.InterruptTest do
  # Interrupts through the callbacks, and the turn/interrupt answers.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.Events
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.Codex

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  test "an interrupt with no open command sends turn/interrupt and answers at the turn's end",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [
      started(tid(), command("exec-1", %{status: "inProgress"})),
      completed(tid(), command("exec-1", done()))
    ])

    on(bin, 1, "turn/interrupt", [j(%{id: "@", result: %{}}), turn_end(tid(), "interrupted")])
    {:ok, state} = connect(work)

    {turn, actions, state} =
      ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})

    {actions, state} =
      pump(
        Codex,
        state,
        actions,
        &Enum.any?(&1, fn a -> match?({:event, _, {:tool_result, _, _}}, a) end)
      )

    assert {:reply, turn, :ok} in actions
    {from, [], state} = ask(state, {:interrupt, "t1"})
    {actions, _state} = pump(Codex, state, [], replied?(from))

    assert [{:event, "t1", {:error, {:codex, "interrupted", ""}}}, {:reply, ^from, :ok}] = actions

    assert %{"params" => %{"threadId" => tid(), "turnId" => "turn1"}} =
             request(bin, 1, "turn/interrupt")
  end

  test "an interrupt with an open command answers an error at once and sends nothing",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [started(tid(), command("exec-1", %{status: "inProgress"}))])
    {:ok, state} = connect(work)

    {_turn, actions, state} =
      ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})

    {_actions, state} =
      pump(
        Codex,
        state,
        actions,
        &Enum.any?(&1, fn a -> match?({:event, _, {:tool_call, _}}, a) end)
      )

    assert {from, [{:reply, from, {:error, :command_running}}], _state} =
             ask(state, {:interrupt, "t1"})

    assert request(bin, 1, "turn/interrupt") == nil
  end

  test "an interrupt before the turn id is known goes out after the turn/start answer",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [])
    on(bin, 1, "turn/interrupt", [j(%{id: "@", result: %{}}), turn_end(tid(), "interrupted")])
    {:ok, state} = connect(work)
    {turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {from, [], state} = ask(state, {:interrupt, "t1"})
    {actions, _state} = pump(Codex, state, [], replied?(from))

    assert [{:reply, ^turn, :ok}, {:event, "t1", {:error, _}}, {:reply, ^from, :ok}] = actions
    assert %{"params" => %{"turnId" => "turn1"}} = request(bin, 1, "turn/interrupt")
  end

  test "a command that starts after the interrupt stops the provider process at the turn's end",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [])

    on(bin, 1, "turn/interrupt", [
      started(tid(), command("exec-1", %{status: "inProgress"})),
      j(%{id: "@", result: %{}}),
      turn_end(tid(), "interrupted")
    ])

    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {from, [], state} = ask(state, {:interrupt, "t1"})
    {actions, _state} = pump(Codex, state, [], fn _ -> false end)

    assert {:stop, :command_running} = List.last(actions)
    refute Enum.any?(actions, &match?({:reply, ^from, _}, &1))
  end

  # A `turn/completed` whose status does not end the turn.
  @bad_ends [%{}, %{status: nil}, %{status: "inProgress"}, %{status: "paused"}, %{status: 7}]

  defp bad_end(fields),
    do: note(tid(), "turn/completed", %{turn: Map.merge(%{id: "turn1", items: []}, fields)})

  @tag :slow
  test "a turn/completed with a status that does not end the turn stops the provider process, and a pending interrupt gets no answer",
       %{bin: bin, work: work} do
    for {fields, n} <- Enum.with_index(@bad_ends, 1) do
      fresh(bin, n, tid(), [])
      on(bin, n, "turn/interrupt", [j(%{id: "@", result: %{}}), bad_end(fields)])
      {:ok, state} = connect(work)

      {_turn, _, state} =
        ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})

      {from, [], state} = ask(state, {:interrupt, "t1"})
      {actions, _state} = pump(Codex, state, [], fn _ -> false end)

      assert {:stop, {:malformed, "turn/completed"}} = List.last(actions)
      refute Enum.any?(actions, &match?({:reply, ^from, _}, &1))
    end
  end

  test "after a turn/completed with an unknown status, the next turn starts a new program",
       %{bin: bin} = ctx do
    fresh(bin, 1, tid(), [bad_end(%{status: "inProgress"})])
    fresh(bin, 2, fresh_tid(), reply(fresh_tid(), "Back."))
    session = start(ctx)

    assert [%{stop_reason: :error, error: {:provider_stop, {:malformed, "turn/completed"}}}] =
             of_type(prompt(session, "go"), :agent_end)

    assert [%{stop_reason: :end_turn}] = of_type(prompt(session, "again"), :agent_end)
    assert runs(bin) == "2"
  end

  test "an interrupt of a turn that ended answers at once", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "ok"))
    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {_actions, state} = pump(Codex, state, [], &turn_ended?/1)
    assert {from, [{:reply, from, :ok}], _state} = ask(state, {:interrupt, "t1"})
    assert request(bin, 1, "turn/interrupt") == nil
  end

  test "after an interrupt, an item of the stopped turn stops the provider process",
       %{bin: bin, work: work} do
    File.write!(Path.join(bin, "late"), completed(tid(), command("exec-1", done())) <> "\n")
    fresh(bin, 1, tid(), [])

    on(
      bin,
      1,
      "turn/interrupt",
      [j(%{id: "@", result: %{}}), turn_end(tid(), "interrupted")],
      ~s{sleep 0.2; cat "$d/late"\n}
    )

    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {from, [], state} = ask(state, {:interrupt, "t1"})
    {actions, state} = pump(Codex, state, [], replied?(from))
    assert {:reply, from, :ok} in actions
    assert {[{:stop, :item_of_ended_turn}], _state} = pump(Codex, state, [], fn _ -> false end)
  end

  test "a turn's end settles an unanswered turn/interrupt: its id is no longer due",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [])
    on(bin, 1, "turn/interrupt", [turn_end(tid(), "interrupted")])
    {:ok, state} = connect(work)
    {_turn, _, state} = turn_on(state)
    {from, [], state} = ask(state, {:interrupt, "t1"})
    {actions, state} = pump(Codex, state, [], replied?(from))
    assert {:reply, from, :ok} in actions
    assert state.due == %{}
    close(state)
  end

  # The error answer to turn 1's `turn/interrupt` comes after turn 2's
  # interrupt went out: it answers no interrupt (review round 1 of #365).
  test "a late turn/interrupt error does not answer the next turn's interrupt",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [delta(tid(), "msg_1", "thinking")])
    on(bin, 1, "turn/interrupt", [turn_end(tid(), "interrupted")], ~s{echo $i > "$d/first"\n}, 1)

    late =
      ~s|printf '{"id":%s,"error":{"code":-32600,"message":"no active turn to interrupt"}}\\n' | <>
        ~s|"$(cat "$d/first")"\n|

    second = as_turn([j(%{id: "@", result: %{}}), turn_end(tid(), "interrupted")], "turn2")
    on(bin, 1, "turn/interrupt", [], late <> after_go(bin, "second", second), 2)

    on(
      bin,
      1,
      "turn/start",
      as_turn(turn(tid(), [delta(tid(), "msg_2", "again")]), "turn2"),
      "",
      2
    )

    {:ok, state} = connect(work)
    {_turn, _, state} = turn_on(state)
    {_actions, state} = pump(Codex, state, [], &match?([_ | _], events(&1)))
    {first, [], state} = ask(state, {:interrupt, "t1"})
    {actions, state} = pump(Codex, state, [], replied?(first))
    assert {:reply, first, :ok} in actions

    {_next, _, state} = turn_on(state, "t2")

    {_actions, state} =
      pump(
        Codex,
        state,
        [],
        &Enum.any?(&1, fn a -> match?({:event, "t2", {:text_delta, _}}, a) end)
      )

    {second, [], state} = ask(state, {:interrupt, "t2"})
    go(bin)
    {actions, state} = pump(Codex, state, [], replied?(second))
    assert {:reply, second, :ok} in actions
    refute Enum.any?(actions, &match?({:stop, _}, &1))
    close(state)
  end
end
