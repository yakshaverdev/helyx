defmodule Helyx.Provider.Codex.TurnLinesTest do
  # Turn lines and turn/start answers with a wrong shape or at a wrong time.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.Codex

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  test "a turn/start answer with both an error and a result stops the provider process",
       %{bin: bin, work: work} do
    initialize(bin, 1)
    on(bin, 1, "thread/start", [j(%{id: "@", result: %{thread: thread(tid())}})])
    on(bin, 1, "thread/inject_items", [j(%{id: "@", result: %{}})])

    on(bin, 1, "turn/start", [
      j(%{id: "@", error: %{message: "boom"}, result: %{turn: %{id: "turn1"}}})
    ])

    {:ok, state} = connect(work)
    {turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {actions, _state} = pump(Codex, state, [], fn _ -> false end)

    assert {:stop, {:malformed, "turn/start"}} = List.last(actions)
    refute Enum.any?(actions, &match?({:reply, ^turn, _}, &1))
  end

  test "an answer with an id that is not due is dropped: the thread stays, and the turn ends",
       %{bin: bin, work: work} do
    # `initialize` is id 1 and `thread/start` id 2, both answered; 99 was
    # never sent.
    late = [
      j(%{id: 2, result: %{thread: thread("other")}}),
      j(%{id: 1, result: %{}}),
      j(%{id: 99, error: %{code: -1, message: "boom"}}),
      turn_end("other", "completed")
    ]

    fresh(bin, 1, tid(), late ++ reply(tid(), "Hi."))
    {:ok, state} = connect(work)
    {turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {actions, state} = pump(Codex, state, [], &turn_ended?/1)

    assert {:reply, turn, :ok} in actions
    assert {:event, "t1", {:done, _}} = List.last(actions)
    assert state.thread == tid()
    assert state.due == %{}
  end

  test "a turn line with the fields of an item line and not its own shape stops the provider process",
       %{bin: bin, work: work} do
    item = %{turnId: "turn1", item: %{type: "agentMessage", id: "msg_1", text: ""}}

    cases = [
      {note(tid(), "turn/started", item), "turn/started"},
      {note(tid(), "turn/completed", Map.put(item, :turn, %{id: "turn1", items: []})),
       "turn/completed"}
    ]

    for {{line, method}, n} <- Enum.with_index(cases, 1) do
      fresh(bin, n, tid(), [line])
      {:ok, state} = connect(work)

      {_turn, _, state} =
        ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})

      {actions, _state} = pump(Codex, state, [], fn _ -> false end)
      assert {:stop, {:malformed, ^method}} = List.last(actions)
    end
  end

  test "a turn/start answer or a turn/started with no string turn id stops the provider process",
       %{bin: bin, work: work} do
    cases = [
      {[j(%{id: "@", result: %{turn: %{id: 7}}})], "turn/start"},
      {[note(tid(), "turn/started", %{turn: %{id: nil}})], "turn/started"}
    ]

    for {{lines, method}, n} <- Enum.with_index(cases, 1) do
      fresh(bin, n, tid(), [])
      on(bin, n, "turn/start", lines)
      {:ok, state} = connect(work)

      {_turn, _, state} =
        ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})

      {actions, _state} = pump(Codex, state, [], fn _ -> false end)
      assert {:stop, {:malformed, ^method}} = List.last(actions)
    end
  end

  test "a turn/interrupt error that is not an object stops the provider process",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [])
    on(bin, 1, "turn/interrupt", [j(%{id: "@", error: "boom"})])
    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {from, [], state} = ask(state, {:interrupt, "t1"})
    {actions, _state} = pump(Codex, state, [], fn _ -> false end)
    assert {:stop, {:malformed, "turn/interrupt"}} = List.last(actions)
    refute Enum.any?(actions, &match?({:reply, ^from, _}, &1))
  end

  test "an item/started with a request id stops the provider process, and a pending interrupt gets no answer",
       %{bin: bin, work: work} do
    start =
      j(%{
        id: nil,
        method: "item/started",
        params: %{threadId: tid(), item: command("exec-1", %{status: "inProgress"})}
      })

    fresh(bin, 1, tid(), [])

    on(bin, 1, "turn/interrupt", [
      start,
      j(%{id: "@", result: %{}}),
      turn_end(tid(), "interrupted")
    ])

    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {from, [], state} = ask(state, {:interrupt, "t1"})
    {actions, _state} = pump(Codex, state, [], fn _ -> false end)

    assert {:stop, {:malformed, "item/started"}} = List.last(actions)
    refute Enum.any?(actions, &match?({:reply, ^from, _}, &1))
  end

  test "a turn that Helyx did not ask for stops the provider process", %{bin: bin, work: work} do
    other = note(tid(), "turn/started", %{turn: %{id: "turn9", status: "inProgress"}})
    File.write!(Path.join(bin, "other"), other <> "\n")
    fresh(bin, 1, tid(), reply(tid(), "ok"), ~s{sleep 0.2; cat "$d/other"\n})

    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {actions, state} = pump(Codex, state, [], &turn_ended?/1)
    assert {:event, "t1", {:done, _}} = List.last(actions)
    assert {[{:stop, :turn_not_asked}], _state} = pump(Codex, state, [], fn _ -> false end)
  end

  test "an error answer to turn/start answers the turn with it", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [])
    on(bin, 1, "turn/start", [j(%{id: "@", error: %{code: -1, message: "busy"}})])
    {:ok, state} = connect(work)
    {turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {actions, _state} = pump(Codex, state, [], replied?(turn))
    assert {:reply, turn, {:error, {:codex, "turn/start", "busy"}}} in actions
  end

  test "a turn/completed before the turn is known stops the provider process",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [])
    on(bin, 1, "turn/start", [turn_end(tid(), "completed")])

    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    assert {[{:stop, :turn_not_asked}], _state} = pump(Codex, state, [], fn _ -> false end)
  end

  @tag :slow
  test "a turn or item line with no string threadId stops the provider process",
       %{bin: bin, work: work} do
    params = %{turn: %{id: "turn1", status: "completed"}, turnId: "turn1", item: search()}

    lines =
      for method <- ~w(turn/completed item/started item/completed turn/started),
          params <- [params, Map.put(params, :threadId, 7), nil],
          do: {method, j(%{method: method, params: params})}

    for {{method, line}, n} <- Enum.with_index(lines, 1) do
      fresh(bin, n, tid(), [line])
      assert {:stop, {:malformed, ^method}} = List.last(run_direct([Message.user("go")], work))
    end
  end
end
