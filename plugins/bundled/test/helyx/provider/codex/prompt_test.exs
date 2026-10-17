defmodule Helyx.Provider.Codex.PromptTest do
  # The prompt of the thread (docs/features/provider-parity.md).
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.Codex

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  defp context(system, text),
    do: %Helyx.Context{system: system, messages: [Message.user(text)]}

  # Program N resumes the thread and runs each turn as `reply/2`.
  defp resumed(bin, n) do
    initialize(bin, n)
    on(bin, n, "thread/resume", [j(%{id: "@", result: %{thread: thread(tid())}})])
    on(bin, n, "turn/start", turn(tid(), reply(tid(), "ok")))
  end

  defp run(state, system, text) do
    {_from, actions, state} = ask(state, {:turn, "t1", context(system, text)})
    {_actions, state} = pump(Codex, state, actions, &turn_ended?/1)
    state
  end

  test "a new prompt resumes the thread in a new program with it; the same prompt keeps the program",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "one"))
    resumed(bin, 2)

    {:ok, state} = connect(work)
    state = run(state, "A", "x")
    state = run(state, "B", "y")
    state = run(state, "B", "z")
    close(state)

    assert runs(bin) == "2"

    assert %{"params" => %{"threadId" => tid(), "baseInstructions" => "B"}} =
             request(bin, 2, "thread/resume")

    assert [_, _] = for(%{"method" => "turn/start"} <- stdin(bin, 2), do: :turn)
  end

  test "the new program starts only after the old one exited", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "one"))
    resumed(bin, 2)
    File.write!(Path.join(bin, "eof.1"), ~s(sleep 0.3; : > "$d/ended.1"\n))

    File.write!(
      Path.join(bin, "on.2.initialize.1"),
      ~s([ -f "$d/ended.1" ] && : > "$d/after.2"\nout "$d/out.2.initialize"\n)
    )

    {:ok, state} = connect(work)
    state = run(run(state, "A", "x"), "B", "y")
    close(state)
    assert File.exists?(Path.join(bin, "after.2"))
  end

  test "the hands hold the handles of one program across relaunches", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "one"))
    resumed(bin, 2)
    resumed(bin, 3)

    {:ok, state} = connect(work)
    state = Enum.reduce(["A", "B", "C"], state, &run(&2, &1, "x"))
    assert runs(bin) == "3"
    assert [command: _, watchdog: _] = Enum.sort(Helyx.Test.Hands.held())
    close(state)
  end

  # The wait for the exit is 1,000 ms (`HarnessIO.finish/1`).
  @tag :slow
  test "an old program that does not exit fails the turn", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "one"))
    File.write!(Path.join(bin, "eof.1"), "sleep 3\n")

    {:ok, state} = connect(work)
    state = run(state, "A", "x")

    assert {from, [{:reply, from, {:error, :program_not_ended}}], _state} =
             ask(state, {:turn, "t1", context("B", "y")})

    assert runs(bin) == "1"
  end

  test "an interrupt of a compaction that opens a fresh thread is answered",
       %{bin: bin, work: work} do
    initialize(bin, 1)
    error = %{code: -32_600, message: "no rollout found for thread id #{tid()}"}
    on(bin, 1, "thread/resume", [j(%{id: "@", error: error})])
    on(bin, 1, "thread/start", [j(%{id: "@", result: %{thread: thread(fresh_tid())}})])

    {:ok, state} = connect(work, resume_id: stored_tid())
    {_from, [], state} = ask(state, {:compact, "c1", ""})
    {interrupt, [], state} = ask(state, {:interrupt, "c1"})

    {actions, state} =
      pump(Codex, state, [], &Enum.any?(&1, fn a -> match?({:reply, ^interrupt, _}, a) end))

    assert {:reply, interrupt, :ok} in actions
    assert state.interrupt == nil
    close(state)
  end

  test "a steer with no answer at the new program fails with :restarted",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [delta(tid(), "msg_1", "a")])
    # The turn ends, and the steer never gets its answer.
    on(bin, 1, "turn/steer", [turn_end(tid(), "completed")])
    resumed(bin, 2)

    {:ok, state} = connect(work)
    {_from, actions, state} = ask(state, {:turn, "t1", context("A", "x")})

    {_actions, state} =
      pump(
        Codex,
        state,
        actions,
        &Enum.any?(&1, fn a -> match?({:event, _, {:text_delta, _}}, a) end)
      )

    {steer, [], state} = ask(state, {:steer, "t1", "s1", "more"})
    {_actions, state} = pump(Codex, state, [], &turn_ended?/1)

    {_from, actions, state} = ask(state, {:turn, "t2", context("B", "y")})
    assert {:reply, steer, {:error, :restarted}} in actions
    {_actions, state} = pump(Codex, state, actions, &turn_ended?/1)
    close(state)
  end

  test "a compaction of a stored thread opens it with the empty prompt",
       %{bin: bin, work: work} do
    initialize(bin, 1)
    on(bin, 1, "thread/resume", [j(%{id: "@", result: %{thread: thread(tid())}})])

    {:ok, state} = connect(work, resume_id: stored_tid())
    {_from, _actions, state} = ask(state, {:compact, "t1", ""})
    close(state)

    assert %{"params" => %{"threadId" => tid(), "baseInstructions" => ""}} =
             request(bin, 1, "thread/resume")
  end
end
