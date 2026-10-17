defmodule Helyx.Provider.Codex.ConnectTest do
  # The handshake that connects to the program, the open of the thread at
  # the first request, and the close.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.Codex

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  test "an idle close after a turn ends the input and answers :ok at the exit",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "Hi."))
    {:ok, state} = connect(work)
    {turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {actions, state} = pump(Codex, state, [], &turn_ended?/1)
    assert {:reply, turn, :ok} in actions
    {from, [], state} = ask(state, :idle_close)
    assert {[{:reply, ^from, :ok}], _state} = pump(Codex, state, [], replied?(from))
  end

  test "the connect ends at the initialize answer; the first turn opens the thread with its prompt",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "Hi."))
    {:ok, state} = connect(work)
    assert state.thread == nil
    context = %Helyx.Context{system: "Be brief.", messages: [Message.user("go")]}
    {_from, actions, state} = ask(state, {:turn, "t1", context})
    {_actions, state} = pump(Codex, state, actions, &turn_ended?/1)
    close(state)

    assert ["initialize", "initialized", "thread/start" | _] =
             Enum.map(stdin(bin, 1), & &1["method"])

    assert request(bin, 1, "thread/start")["params"]["baseInstructions"] == "Be brief."
  end

  test "a nil system is the empty prompt, never the program's own", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "Hi."))
    {:ok, state} = connect(work)
    {_from, actions, state} = turn_on(state)
    {_actions, state} = pump(Codex, state, actions, &turn_ended?/1)
    close(state)
    assert request(bin, 1, "thread/start")["params"]["baseInstructions"] == ""
  end

  test "a response error fails the first turn with the method and the message",
       %{bin: bin, work: work} do
    initialize(bin, 1)
    on(bin, 1, "thread/start", [j(%{id: "@", error: %{code: -1, message: "bad model"}})])
    assert {:stop, {:codex, "thread/start", "bad model"}} = opening_stop(work)
  end

  test "an initialize error fails the connect", %{bin: bin, work: work} do
    on(bin, 1, "initialize", [j(%{id: "@", error: %{code: -1, message: "no"}})])
    assert {:error, {:codex, "initialize", "no"}} = connect(work)
  end

  @tag :slow
  test "a handshake answer with the wrong shape fails the connect or the first turn",
       %{bin: bin, work: work} do
    thread = %{thread: thread(tid())}
    lost = %{code: -32_600, message: "no rollout found for thread id #{tid()}"}

    cases = [
      {:resume, "thread/resume", %{error: lost, result: thread}},
      {:resume, "thread/resume", %{error: %{code: -1, message: "boom"}}},
      {:resume, "thread/resume", %{error: %{lost | message: "no rollout found"}}},
      {:resume, "thread/resume", %{error: %{lost | code: -1}}},
      {:resume, "thread/resume",
       %{error: %{lost | message: "no rollout found for thread id #{fresh_tid()}"}}},
      {:resume, "thread/resume", %{result: %{thread: thread(fresh_tid())}}},
      {:resume, "thread/resume", %{result: %{}}},
      {:fresh, "thread/start", %{error: %{message: "x"}, result: thread}},
      {:fresh, "thread/start", %{result: %{thread: %{id: 7}}}},
      {:fresh, "initialize", %{result: "ok"}}
    ]

    for {{mode, method, answer}, n} <- Enum.with_index(cases, 1) do
      on(bin, n, method, [j(Map.put(answer, :id, "@"))])
      opts = if mode == :resume, do: [resume_id: stored(tid())], else: []

      if method == "initialize" do
        assert {:error, {:malformed, ^method}} = connect(work, opts)
      else
        initialize(bin, n)
        assert {:stop, {:malformed, ^method}} = opening_stop(work, [], opts)
      end
    end
  end

  test "a handshake answer with an id that is not due is dropped", %{bin: bin, work: work} do
    initialize(bin, 1)

    # The resume is id 2: a `thread/start` answer that was never asked for
    # does not switch the thread.
    on(bin, 1, "thread/resume", [
      j(%{id: 3, result: %{thread: thread(fresh_tid())}}),
      j(%{id: 1, result: %{}}),
      j(%{id: "@", result: %{thread: thread(tid())}})
    ])

    assert {:ok, state} = connect(work, resume_id: stored(tid()))
    {_from, _actions, state} = turn_on(state)
    state = settle(Codex, state, &(&1.thread != nil))
    assert {state.thread, state.fresh?} == {tid(), false}
    close(state)
    assert request(bin, 1, "thread/start") == nil
  end

  test "a program that exits before its thread is ready fails the first turn",
       %{bin: bin, work: work} do
    initialize(bin, 1)
    on(bin, 1, "thread/start", [], "exit 3\n")
    assert {:stop, {:codex_exit, 3}} = opening_stop(work)
  end

  test "a program that exits before the initialize answer fails the connect",
       %{bin: bin, work: work} do
    on(bin, 1, "initialize", [], "exit 3\n")
    assert {:error, {:codex_exit, 3}} = connect(work)
  end
end
