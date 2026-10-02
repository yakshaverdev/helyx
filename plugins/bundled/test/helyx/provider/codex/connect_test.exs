defmodule Helyx.Provider.Codex.ConnectTest do
  # The handshake that connects to the program, and the close.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.Codex

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  test "a close ends the input and answers at the exit", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [])
    {:ok, state} = connect(work)
    close(state)
  end

  # 4.1 of the simplification review: a write to a watchdog that died
  # closes the port with `:epipe` and no exit status (#167). During a
  # close, that `:DOWN` is the exit that answers it.
  test "a close answers :ok at a port :DOWN with no exit status", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [])
    {:ok, state} = connect(work)
    {from, [], state} = ask(state, :close)
    down = {:DOWN, make_ref(), :port, state.port, :epipe}
    assert {:ok, [{:reply, ^from, :ok}], _state} = Codex.harness_info(down, state)
  end

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

  test "a response error fails the connect with the method and the message",
       %{bin: bin, work: work} do
    initialize(bin, 1)
    on(bin, 1, "thread/start", [j(%{id: "@", error: %{code: -1, message: "bad model"}})])
    assert {:error, {:codex, "thread/start", "bad model"}} = connect(work)
  end

  @tag :slow
  test "a handshake answer with the wrong shape fails the connect",
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
      if method != "initialize", do: initialize(bin, n)
      on(bin, n, method, [j(Map.put(answer, :id, "@"))])
      opts = if mode == :resume, do: [harness_session_id: tid()], else: []
      assert {:error, {:malformed, ^method}} = connect(work, opts)
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

    assert {:ok, state} = connect(work, harness_session_id: tid())
    assert {state.thread, state.fresh?} == {tid(), false}
    assert request(bin, 1, "thread/start") == nil
  end

  test "a program that exits before its thread is ready fails the connect",
       %{bin: bin, work: work} do
    initialize(bin, 1)
    on(bin, 1, "thread/start", [], "exit 3\n")
    assert {:error, {:codex_exit, 3}} = connect(work)
  end
end
