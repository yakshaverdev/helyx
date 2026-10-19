defmodule Helyx.Provider.ClaudeCode.NoStateTest do
  # A harness session with no stored state, `persist: false`
  # (docs/features/harness-no-state.md).
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.ClaudeCode

  @moduletag :tmp_dir

  setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

  @flag "--no-session-persistence"

  defp answer(text), do: %Message{role: :assistant, content: [%Message.Text{text: text}]}

  defp run(state, system, messages) do
    context = %Helyx.Context{system: system, messages: messages}
    {_from, actions, state} = request(state, {:turn, "t1", context})
    {actions, state} = pump(ClaudeCode, state, actions, &ended?/1)
    {events_of(actions), state}
  end

  test "every launch has the flag, and a fresh harness session gives no resume id",
       %{bin: bin, work: work} do
    turn(bin, 1, 1, reply("one"))
    turn(bin, 2, 1, reply("two"))

    history = [Message.user("a"), answer("b"), Message.user("x")]
    {events, state} = run(harness(work, persist: false), "A", history)
    assert @flag in args(bin, 1)
    assert [{:text_delta, "one"} | _] = events
    closed(state)

    {events, state} = run(harness(work), "A", history)
    refute @flag in args(bin, 2)
    assert [{:resume_id, _id, 0} | _] = events
    closed(state)
  end

  test "a prompt change starts a fresh harness session with the replay and a new meter",
       %{bin: bin, work: work} do
    # A cost of 0.2 that a meter with the old program's mark of 0.5 would
    # not give.
    costed =
      Map.merge(JSON.decode!(result("two")), %{
        "total_cost_usd" => 0.2,
        "modelUsage" => %{"m" => %{"costBasis" => "list"}}
      })

    turn(bin, 1, 1, reply("one"))
    turn(bin, 2, 1, begin() ++ [delta("two"), j(costed)])

    {_events, state} = run(harness(work, persist: false), "A", [Message.user("x")])
    first = state.session_id
    meter = %{state.meter | mark: 0.5}

    history = [Message.user("x"), answer("one"), Message.user("y")]
    {events, state} = run(%{state | meter: meter}, "B", history)

    assert programs(bin) == "2"
    args = args(bin, 2)
    assert @flag in args and ("--session-id=" <> state.session_id) in args
    refute Enum.any?(args, &String.starts_with?(&1, "--resume"))
    assert state.session_id != first
    assert initialize(bin, 2) == "B"
    assert [{:text_delta, "two"} | _] = events
    # The replay, then the prompt.
    assert [%{"shouldQuery" => false}, %{"type" => "assistant"}, prompt] = stdin(bin, 2)
    assert %{"type" => "user", "message" => %{"content" => [%{"text" => "y"}]}} = prompt
    assert {:done, %{usage: %{cost: 0.2}}} = List.last(events)
    closed(state)
  end

  test "a resume id fails the init, and so does a persist that is not a boolean",
       %{work: work} do
    opts = [cwd: work, persist: false]

    assert ClaudeCode.init("haiku", [], [resume_id: stored(sid())] ++ opts) ==
             {:error, :no_state_resume}

    assert ClaudeCode.init("haiku", [], [resume_id: sid()] ++ opts) == {:error, :no_state_resume}

    for bad <- [nil, "false", 0] do
      assert ClaudeCode.init("haiku", [], cwd: work, persist: bad) ==
               {:error, {:invalid_option, :persist}}
    end

    assert {:ok, _state} =
             ClaudeCode.init("haiku", [], cwd: work, persist: true, resume_id: sid())
  end

  test "a compaction fails at once and keeps the program", %{bin: bin, work: work} do
    turn(bin, 1, 1, reply("one"))
    {_events, state} = run(harness(work, persist: false), "A", [Message.user("x")])

    assert {from, [{:reply, from, :ok}, {:event, "t2", {:error, error}}], state} =
             request(state, {:compact, "t2", ""})

    assert %Helyx.ProviderError{kind: :compaction_failed, text: "no stored state to compact"} =
             error

    assert state.port != nil
    closed(state)
    assert programs(bin) == "1"
  end
end
