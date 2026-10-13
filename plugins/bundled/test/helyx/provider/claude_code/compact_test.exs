defmodule Helyx.Provider.ClaudeCode.CompactTest do
  # The compaction of the program's own history
  # (docs/features/harness-compaction.md), in the line shapes of
  # `docs/research/claude-code-stream-json.md`, "Compaction".
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.Events
  import Helyx.Test.HarnessDriver

  alias Helyx.Provider.ClaudeCode
  alias Helyx.Session

  @moduletag :tmp_dir

  setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

  defp status(fields),
    do: j(Map.merge(%{type: "system", subtype: "status", session_id: sid()}, fields))

  defp boundary(trigger, before, after_) do
    meta = %{trigger: trigger, pre_tokens: before, post_tokens: after_, duration_ms: 2903}
    j(%{type: "system", subtype: "compact_boundary", compact_metadata: meta, session_id: sid()})
  end

  defp summary do
    j(%{
      type: "user",
      message: %{role: "user", content: [%{type: "text", text: "This session is continued"}]},
      session_id: sid()
    })
  end

  defp compacted_line do
    content = "<local-command-stdout>Compacted </local-command-stdout>"
    j(%{type: "user", message: %{role: "user", content: content}, isReplay: true})
  end

  # The lines of a `/compact` that compacts, as the program gives them.
  defp compaction(before, after_) do
    begin() ++
      [
        status(%{status: "compacting"}),
        status(%{status: nil, compact_result: "success"}),
        init(),
        boundary("manual", before, after_),
        summary(),
        compacted_line(),
        replayed() |> JSON.decode!() |> Map.put("queued_turn_count", 0) |> j()
      ]
  end

  test "/compact gives one compaction event and no message in the transcript",
       %{bin: bin} = ctx do
    turn(bin, 1, 1, reply("Hi."))
    turn(bin, 1, 2, compaction(29_557, 3_926))

    session = start(ctx)
    prompt(session, "hello")
    assert :ok = Session.compact(session, "keep it short")
    events = collect_until(:turn_end)

    assert [%{trigger: :manual, tokens_before: 29_557, tokens_after: 3_926}] =
             of_type(events, :compaction)

    assert List.last(events).data == %{outcome: :done}
    assert messages(events) == []

    assert [_prompt, %{"type" => "user", "uuid" => uuid, "message" => message}] = stdin(bin, 1)
    assert is_binary(uuid)
    assert %{"content" => [%{"type" => "text", "text" => "/compact keep it short"}]} = message

    {:ok, snapshot, _} = Session.subscribe(session)
    assert [%{role: :user}, %{role: :assistant}] = snapshot.messages
  end

  # A `result` line with the process total `total` (research note, "The
  # cost of `/compact`").
  defp costed(line, total) do
    entry = %{"costBasis" => "list", "contextWindow" => 1_000_000}
    fields = %{"total_cost_usd" => total, "modelUsage" => %{"claude-haiku-5-5" => entry}}
    line |> JSON.decode!() |> Map.merge(fields) |> j()
  end

  test "the cost of the compaction call goes into the next done", %{bin: bin} = ctx do
    turn(bin, 1, 1, begin() ++ [delta("a"), costed(result("a"), 0.1)])
    turn(bin, 1, 2, List.update_at(compaction(9, 2), -1, &costed(&1, 0.15)))
    turn(bin, 1, 3, begin() ++ [delta("b"), costed(result("b"), 0.25)])

    session = start(ctx)
    assert [_user, %{usage: %{cost: 0.1}}] = messages(prompt(session, "one"))
    assert :ok = Session.compact(session)
    assert List.last(collect_until(:turn_end)).data == %{outcome: :done}
    assert [_user, %{usage: %{cost: cost, cost_kind: :list}}] = messages(prompt(session, "two"))
    assert_in_delta cost, 0.15, 1.0e-12
  end

  # A resumed program reports the totals of its harness session, and no
  # message holds the compaction's cost, so the first done has it.
  test "after a compaction and a reconnect, the first done has the compaction's cost",
       %{bin: bin} = ctx do
    turn(bin, 1, 1, begin() ++ [delta("a"), costed(result("a"), 0.1)])
    turn(bin, 1, 2, List.update_at(compaction(9, 2), -1, &costed(&1, 0.15)))
    turn(bin, 2, 1, begin() ++ [delta("b"), costed(result("b"), 0.25)])

    session = start(ctx)
    prompt(session, "one")
    assert :ok = Session.compact(session)
    collect_until(:turn_end)
    GenServer.stop(Session.pid(session))

    {:ok, session} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
    {:ok, _, _} = Session.subscribe(session)
    assert [_user, %{usage: %{cost: cost}}] = messages(prompt(session, "two"))
    assert_in_delta cost, 0.15, 1.0e-12
    assert ["--resume=" <> _] = Enum.filter(args(bin, 2), &String.starts_with?(&1, "--resume"))
  end

  # The failed turn's message has no usage, so the mark leaves out both
  # the failed call and the compaction call.
  test "after a failed turn, a compaction, and a reconnect, the first done has both costs",
       %{bin: bin} = ctx do
    failed = aborted() |> JSON.decode!() |> Map.put("usage", %{"input_tokens" => 1}) |> j()
    turn(bin, 1, 1, begin() ++ [delta("a"), costed(result("a"), 0.1)])
    turn(bin, 1, 2, begin() ++ [delta("b"), costed(failed, 0.12)])
    turn(bin, 1, 3, List.update_at(compaction(9, 2), -1, &costed(&1, 0.15)))
    turn(bin, 2, 1, begin() ++ [delta("c"), costed(result("c"), 0.25)])

    session = start(ctx)
    prompt(session, "one")
    assert [%{outcome: :error}] = of_type(prompt(session, "two"), :turn_end)
    assert :ok = Session.compact(session)
    assert List.last(collect_until(:turn_end)).data == %{outcome: :done}
    GenServer.stop(Session.pid(session))

    {:ok, session} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
    {:ok, _, _} = Session.subscribe(session)
    assert [_user, %{usage: %{cost: cost}}] = messages(prompt(session, "three"))
    assert_in_delta cost, 0.15, 1.0e-12
    assert ["--resume=" <> _] = Enum.filter(args(bin, 2), &String.starts_with?(&1, "--resume"))
  end

  test "a compaction that fails ends the turn with the program's error", %{bin: bin, work: work} do
    failed = [
      status(%{status: "compacting"}),
      status(%{status: nil, compact_result: "failed", compact_error: "Not enough messages."}),
      init(),
      assistant(%{type: "text", text: "Not enough messages."}),
      replayed() |> JSON.decode!() |> Map.put("queued_turn_count", 0) |> j()
    ]

    turn(bin, 1, 1, begin() ++ failed)

    {_from, actions, state} = request(harness(work, resume_id: sid()), {:compact, "t1", ""})
    {actions, _state} = pump(ClaudeCode, state, actions, &ended?/1)

    assert [{:error, {:compaction_failed, "Not enough messages."}}] = events_of(actions)
    assert [%{"message" => %{"content" => [%{"text" => "/compact"}]}}] = stdin(bin, 1)
  end

  # Core fails the turn: it has no compaction event (Compaction.outcome/2).
  test "a compaction turn with no boundary ends with no event", %{bin: bin, work: work} do
    turn(bin, 1, 1, begin() ++ [result("done", 0)])

    {_from, actions, state} = request(harness(work, resume_id: sid()), {:compact, "t1", ""})
    {actions, _state} = pump(ClaudeCode, state, actions, &ended?/1)

    assert [{:done, _}] = events_of(actions)
  end

  test "a fresh program has no history: the compaction fails, and nothing is written",
       %{bin: bin, work: work} do
    state = harness(work)
    assert {from, actions, state} = request(state, {:compact, "t1", "x"})
    assert [{:reply, ^from, :ok}, {:event, "t1", {:error, {:compaction_failed, _}}}] = actions
    assert state.turn == nil and not state.sent?
    closed(state)
    assert stdin(bin, 1) == []
  end

  test "a lost session during a compaction fails it on the fresh program", %{bin: bin, work: work} do
    script(bin, "start.1", [lost(sid())], "exit 1\n")

    {_from, actions, state} = request(harness(work, resume_id: sid()), {:compact, "t1", ""})
    {actions, state} = pump(ClaudeCode, state, actions, &ended?/1)

    assert [{:error, {:compaction_failed, "no history in the program yet"}}] = events_of(actions)
    assert state.turn == nil and not state.sent?
    closed(state)
    assert programs(bin) == "2"
    assert stdin(bin, 2) == []
  end

  test "a compaction by the program in a model turn gives the event, and the turn goes on",
       %{bin: bin, work: work} do
    auto = [
      status(%{status: "compacting"}),
      status(%{status: nil, compact_result: "success"}),
      boundary("auto", 36_064, 5_292),
      summary(),
      delta("a"),
      assistant(%{type: "text", text: "a"}),
      result("a")
    ]

    turn(bin, 1, 1, begin() ++ auto)
    actions = run_direct([Helyx.Message.user("x")], work)

    assert [{:compaction, 36_064, 5_292}, {:text_delta, "a"}, {:done, _}] =
             actions |> events_of() |> Enum.reject(&match?({:resume_id, _, _}, &1))
  end

  test "a token count outside the wire bound is not known", %{bin: bin, work: work} do
    turn(bin, 1, 1, begin() ++ [boundary("auto", 1_000_000_001, -1), result("a")])
    actions = run_direct([Helyx.Message.user("x")], work)
    assert {:compaction, nil, nil} in events_of(actions)
  end
end
