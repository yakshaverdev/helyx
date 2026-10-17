defmodule Helyx.Provider.Codex.CompactTest do
  # The compaction of the thread's history
  # (docs/features/harness-compaction.md), in the line shapes of
  # `docs/research/codex-app-server.md`, "Compaction".
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.Events
  import Helyx.Test.HarnessDriver

  alias Helyx.Provider.Codex
  alias Helyx.Session

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  defp item, do: %{type: "contextCompaction", id: "c1"}

  # The program's compaction turn "turn2", after the answer.
  defp compaction_turn do
    as_turn(
      [
        note(tid(), "turn/started", %{turn: %{id: "turn1", status: "inProgress"}}),
        started(tid(), item()),
        usage(tid()),
        completed(tid(), item()),
        turn_end(tid(), "completed")
      ],
      "turn2"
    )
  end

  test "/compact gives one compaction event and no message in the transcript",
       %{bin: bin} = ctx do
    fresh(bin, 1, tid(), reply(tid(), "Hi."))
    on(bin, 1, "thread/compact/start", [j(%{id: "@", result: %{}}) | compaction_turn()])

    session = start(ctx)
    prompt(session, "hello")
    assert :ok = Session.compact(session, "dropped")
    events = collect_until(:turn_end)

    assert [%{trigger: :manual, tokens_before: nil, tokens_after: nil}] =
             of_type(events, :compaction)

    assert List.last(events).data == %{outcome: :done}
    assert messages(events) == []
    assert %{"params" => params} = request(bin, 1, "thread/compact/start")
    assert params == %{"threadId" => tid()}

    {:ok, snapshot, _} = Session.subscribe(session)
    assert [%{role: :user}, %{role: :assistant}] = snapshot.messages
  end

  test "the token counts of the compaction turn go into the next done", %{bin: bin} = ctx do
    fresh(bin, 1, tid(), reply(tid(), "Hi."))
    on(bin, 1, "thread/compact/start", [j(%{id: "@", result: %{}}) | compaction_turn()])
    on(bin, 1, "turn/start", as_turn(turn(tid(), reply(tid(), "Next.")), "turn3"), "", 2)

    session = start(ctx)
    assert [_user, %{usage: %{input: 12, output: 7}}] = messages(prompt(session, "one"))
    assert :ok = Session.compact(session)
    assert List.last(collect_until(:turn_end)).data == %{outcome: :done}
    assert [_user, %{usage: %{input: 24, output: 14}}] = messages(prompt(session, "two"))
  end

  test "a fresh thread has no history: the compaction fails, and nothing is sent",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [])
    {:ok, state} = connect(work)
    assert {from, actions, state} = ask(state, {:compact, "t1", ""})

    assert [
             {:reply, ^from, :ok},
             {:event, "t1", {:error, %Helyx.ProviderError{kind: :compaction_failed}}}
           ] = actions

    assert state.turn_id == nil
    close(state)
    assert request(bin, 1, "thread/compact/start") == nil
  end

  test "an interrupt before the compaction turn starts goes out with its turn id",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "Hi."))
    tail = after_go(bin, "compaction", compaction_turn())
    on(bin, 1, "thread/compact/start", [j(%{id: "@", result: %{}})], tail)
    on(bin, 1, "turn/interrupt", [j(%{id: "@", result: %{}})])

    {:ok, state} = connect(work)
    {_from, actions, state} = turn_on(state)
    {_actions, state} = pump(Codex, state, actions, &turn_ended?/1)

    {from, _actions, state} = ask(state, {:compact, "t2", ""})
    {_actions, state} = pump(Codex, state, [], replied?(from))
    {interrupt, [], state} = ask(state, {:interrupt, "t2"})
    go(bin)

    {actions, state} = pump(Codex, state, [], replied?(interrupt))
    assert {:event, "t2", {:compaction, nil, nil}} in actions
    close(state)

    assert %{"params" => %{"turnId" => "turn2"}} = request(bin, 1, "turn/interrupt")
  end

  test "an error answer to the compaction fails it", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "Hi."))
    error = %{code: -32_600, message: "no thread"}
    on(bin, 1, "thread/compact/start", [j(%{id: "@", error: error})])

    {:ok, state} = connect(work)
    {_from, actions, state} = turn_on(state)
    {_actions, state} = pump(Codex, state, actions, &turn_ended?/1)
    {from, _actions, state} = ask(state, {:compact, "t2", ""})
    {actions, state} = pump(Codex, state, [], replied?(from))

    assert {:reply, ^from,
            {:error,
             %Helyx.ProviderError{
               provider: "codex",
               kind: "thread/compact/start",
               text: "no thread"
             }}} =
             List.last(actions)

    close(state)
  end

  test "a compaction by the program in a model turn gives the event, and the turn goes on",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [started(tid(), item()), completed(tid(), item())] ++ reply(tid(), "ok"))

    assert [{:resume_id, _, _}, {:compaction, nil, nil}, {:text_delta, "ok"}, {:done, _}] =
             run_direct([Helyx.Message.user("x")], work)
  end
end
