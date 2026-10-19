defmodule Helyx.Provider.Codex.NoStateTest do
  # A harness session with no stored state, `persist: false`
  # (docs/features/harness-no-state.md).
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.Codex

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  defp answer(text), do: %Message{role: :assistant, content: [%Message.Text{text: text}]}

  # Run `n` as `fresh/4`, with a thread that the program reports as
  # ephemeral.
  defp ephemeral(bin, n, lines) do
    fresh(bin, n, tid(), lines)
    started = Map.put(thread(tid()), :ephemeral, true)

    on(bin, n, "thread/start", [
      j(%{id: "@", result: %{thread: started}}),
      j(%{method: "thread/started", params: %{thread: started}})
    ])
  end

  defp run(state, system, messages) do
    {_from, actions, state} =
      ask(state, {:turn, "t1", %Helyx.Context{system: system, messages: messages}})

    {actions, state} = pump(Codex, state, actions, &turn_ended?/1)
    {events(actions), state}
  end

  test "the thread starts ephemeral and gives no resume id", %{bin: bin, work: work} do
    ephemeral(bin, 1, reply(tid(), "one"))
    fresh(bin, 2, tid(), reply(tid(), "two"))
    history = [Message.user("a"), answer("b"), Message.user("x")]

    {:ok, state} = connect(work, persist: false)
    {events, state} = run(state, "A", history)
    close(state)
    assert %{"params" => %{"ephemeral" => true}} = request(bin, 1, "thread/start")
    assert request(bin, 1, "thread/inject_items") != nil
    refute Enum.any?(events, &match?({:resume_id, _, _}, &1))

    {:ok, state} = connect(work)
    {events, state} = run(state, "A", history)
    close(state)
    refute Map.has_key?(request(bin, 2, "thread/start")["params"], "ephemeral")
    assert [{:resume_id, _, 0} | _] = events
  end

  test "a prompt change starts a fresh ephemeral thread with the replay in a new program",
       %{bin: bin, work: work} do
    ephemeral(bin, 1, reply(tid(), "one"))
    ephemeral(bin, 2, reply(tid(), "two"))

    {:ok, state} = connect(work, persist: false)
    {_events, state} = run(state, "A", [Message.user("x")])
    {events, state} = run(state, "B", [Message.user("x"), answer("one"), Message.user("y")])
    close(state)

    assert runs(bin) == "2"
    assert request(bin, 2, "thread/resume") == nil

    assert %{"params" => %{"ephemeral" => true, "baseInstructions" => "B"}} =
             request(bin, 2, "thread/start")

    assert %{"params" => %{"items" => [_x, _one]}} = request(bin, 2, "thread/inject_items")
    refute Enum.any?(events, &match?({:resume_id, _, _}, &1))
  end

  test "a thread that the program does not report as ephemeral stops the provider",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "one"))
    assert opening_stop(work, [], persist: false) == {:stop, {:malformed, "thread/start"}}
  end

  test "a resume id fails the init, and so does a persist that is not a boolean",
       %{work: work} do
    assert connect(work, persist: false, resume_id: stored(tid())) == {:error, :no_state_resume}

    for bad <- [nil, "false", 0],
        do: assert(connect(work, persist: bad) == {:error, {:invalid_option, :persist}})
  end
end
