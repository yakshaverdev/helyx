defmodule Helyx.Provider.LoopTest do
  # `Helyx.Provider.Loop`: the callbacks driven directly, with the test
  # process as the provider process, and a session for the process rules.
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Context, Message, Session}
  alias Helyx.Provider.Loop

  defp new(model), do: Loop.new(Helyx.Test.Provider, model, session_id: "s", resume_id: nil)

  # A turn "t1" of `model`, after its `:ok`.
  defp turn(model, context \\ %Context{}) do
    from = make_ref()

    assert {:ok, [{:reply, ^from, :ok}], state} =
             Loop.request({:turn, "t1", context}, from, new(model))

    state
  end

  defp request(request, state) do
    from = make_ref()
    assert {:ok, [{:reply, ^from, reply} | actions], state} = Loop.request(request, from, state)
    {reply, actions, state}
  end

  # Gives each message of the model Task to `info/2` until the actions end
  # with a terminal, a tool request, or a context request.
  defp pump(state, acc \\ []) do
    receive do
      :filler ->
        pump(state, acc)

      message ->
        {:ok, actions, state} = Loop.info(message, state)
        acc = acc ++ actions
        if stop?(List.last(acc)), do: {acc, state}, else: pump(state, acc)
    after
      wait_ms() -> flunk("no end of the model call")
    end
  end

  defp stop?({:event, _, {tag, _}}) when tag in [:done, :error], do: true
  defp stop?({:event, _, {:tool_request, _, _, _}}), do: true
  defp stop?({:need_context, _}), do: true
  defp stop?(_action), do: false

  defp events(actions), do: for({:event, "t1", event} <- actions, do: event)

  defp done(stop), do: {:done, %{stop_reason: stop, usage: %{}}}

  test "deltas and calls go out in order; a done with calls ends the message and requests the call" do
    {actions, state} = pump(turn("blocks"))

    assert [
             {:thinking_delta, "hm"},
             {:thinking_delta, "m"},
             {:text_delta, "Listing"},
             {:text_delta, "."},
             {:tool_call, %Message.ToolCall{id: "call_1"}},
             {:message_end, :end_turn, %{}},
             {:tool_request, id, "bash", %{"command" => "ls"}}
           ] = events(actions)

    assert %{calls: [{^id, %{id: "call_1"}, nil}], task: nil} = state
  end

  test "every call goes out at once; the results join in call order, whatever order they come in" do
    {actions, state} = pump(turn("serial"))

    assert [{"slow", "1", id1}, {"slow", "2", id2}, {"slow", "3", id3}] =
             for(
               {:tool_request, id, name, %{"text" => text}} <- events(actions),
               do: {name, text, id}
             )

    {:ok, [], state} = request({:tool_result, "t1", id3, {:ok, "3"}}, state)
    {:ok, [], state} = request({:tool_result, "t1", id2, {:ok, "2"}}, state)
    {:ok, actions, state} = request({:tool_result, "t1", id1, {:ok, "1"}}, state)

    assert actions ==
             [
               {:event, "t1", {:tool_result, "1", {:ok, "1"}}},
               {:event, "t1", {:tool_result, "2", {:ok, "2"}}},
               {:event, "t1", {:tool_result, "3", {:ok, "3"}}},
               {:need_context, "t1"}
             ]

    assert %{calls: [], turn: "t1"} = state
  end

  test "a rejected call has its result at once, after the results of the calls before it" do
    {actions, state} = pump(turn("rejected"))

    assert [
             {:tool_call, %{id: "c1"}},
             {:tool_call, %{id: "c2"}},
             {:message_end, _, _},
             tool_request
           ] =
             Enum.drop(events(actions), 1)

    assert {:tool_request, id, "upcase", %{"text" => "one"}} = tool_request

    {:ok, actions, state} = request({:tool_result, "t1", id, {:ok, "ONE"}}, state)
    rejected = {:error, "tool call not run: the arguments are not a valid JSON object"}

    assert actions == [
             {:event, "t1", {:tool_result, "c1", {:ok, "ONE"}}},
             {:event, "t1", {:tool_result, "c2", rejected}},
             {:need_context, "t1"}
           ]

    # The next model call gets the fresh context.
    messages = [
      Message.tool_result(
        %Message.ToolCall{id: "c1", name: "upcase", arguments: %{}},
        {:ok, "ONE"}
      )
    ]

    {:ok, [], state} = request({:context, "t1", {:ok, %Context{messages: messages}}}, state)
    {actions, _state} = pump(state)
    assert [{:text_delta, "ONE"}, {:done, _}] = events(actions)
  end

  test "a held steer continues the turn: the message ends, the steer goes out, then the context request" do
    state = turn("ok")
    assert {:ok, [], state} = request({:steer, "t1", "s1", "more"}, state)
    {actions, state} = pump(state)

    assert events(actions) == [
             {:text_delta, "ok"},
             {:message_end, :end_turn, %{}},
             {:user_message, "s1"}
           ]

    assert List.last(actions) == {:need_context, "t1"}
    assert %{turn: "t1", steers: []} = state
  end

  test "a steer after the terminal is rejected" do
    {actions, state} = pump(turn("ok"))
    assert List.last(events(actions)) == done(:end_turn)
    assert {:rejected, [], _state} = request({:steer, "t1", "s1", "late"}, state)
  end

  test "a steer held while the context is built goes out before the model call" do
    state = turn("ok")
    {:ok, [], state} = request({:steer, "t1", "s1", "more"}, state)
    {_actions, state} = pump(state)
    {:ok, [], state} = request({:steer, "t1", "s2", "again"}, state)

    assert {:ok, [{:event, "t1", {:user_message, "s2"}}, {:need_context, "t1"}], state} =
             request({:context, "t1", {:ok, %Context{}}}, state)

    assert %{task: nil, steers: []} = state
  end

  test "a context error ends the turn" do
    state = turn("ok")
    {:ok, [], state} = request({:steer, "t1", "s1", "more"}, state)
    {_actions, state} = pump(state)

    assert {:ok, [{:event, "t1", {:error, :bad}}], state} =
             request({:context, "t1", {:error, :bad}}, state)

    assert %{turn: nil} = state
  end

  test "a raising, throwing, or exiting stream gives task_exit; an empty one stream_ended" do
    # "exit_normal" ends the Task with a signal that no catch sees: its
    # `:DOWN` is the terminal.
    errors =
      for model <- ["crash", "throw", "exit", "exit_normal", "empty"] do
        {actions, state} = pump(turn(model))
        assert %{turn: nil, task: nil} = state
        {:error, error} = List.last(events(actions))
        error
      end

    assert [
             {:task_exit, {%RuntimeError{message: "boom"}, [_ | _]}},
             {:task_exit, {{:nocatch, :boom}, [_ | _]}},
             {:task_exit, :boom},
             {:task_exit, :normal},
             :stream_ended
           ] = errors
  end

  test "the interrupt replies only after the model Task is dead; a late message of it changes nothing" do
    state = turn("hang")
    %Task{pid: pid, ref: ref} = state.task
    {:ok, [], state} = request({:interrupt, "t1"}, state)

    refute Process.alive?(pid)
    assert %{turn: nil, task: nil} = state
    assert {:ok, [], ^state} = Loop.info({Loop, pid, {:text_delta, "late"}}, state)
    assert {:ok, [], ^state} = Loop.info({ref, done(:end_turn)}, state)
  end

  # The session answers every open request `aborted` before the interrupt
  # (`Helyx.Session.Wait`), and it drops the events of the turn that ended.
  test "an interrupt during tool runs ends the turn after the aborted results" do
    {actions, state} = pump(turn("serial"))
    ids = for {:tool_request, id, _, _} <- events(actions), do: id

    state =
      Enum.reduce(ids, state, fn id, state ->
        {:ok, _actions, state} = request({:tool_result, "t1", id, {:error, "aborted"}}, state)
        state
      end)

    {:ok, [], state} = request({:interrupt, "t1"}, state)
    assert %{turn: nil, calls: [], task: nil} = state
    refute_received _
  end

  test "a send over the mailbox cap of the provider process ends the model call" do
    # At the cap one more send is allowed; over it the next send fails.
    for _ <- 1..10_000, do: send(self(), :filler)
    state = turn("blocks")
    # The fillers stay until the model call ends.
    ref = Process.monitor(state.task.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}
    {actions, _state} = pump(state)

    assert [{:thinking_delta, "hm"}, {:error, {:provider_behind, 10_001, 10_000}}] =
             events(actions)
  end

  # The bound is on bytes: 512 "é" are 1,024 bytes, and one more "x" is over.
  test "a rejected call with a reason of at most 1,024 bytes of valid UTF-8 passes" do
    for model <- ["reject_bytes_1023", "reject_bytes_1024", "reject_multibyte_1024"] do
      {actions, _state} = pump(turn(model))

      assert [{:tool_call, %{id: "r"}}, {:message_end, _, _}, {:tool_result, "r", {:error, text}}] =
               events(actions)

      assert byte_size(text) <= 1_024 + byte_size("tool call not run: "), model
    end
  end

  # "self_halt" is an enumerable whose result is not a terminal.
  test "a rejected call with a bad reason, or an event that is not a stream event, ends the process" do
    for model <- [
          "reject_bytes_1025",
          "reject_multibyte_1025",
          "reject_raw",
          "reject_atom",
          "harness_event",
          "self_halt"
        ] do
      state = turn(model)
      assert {:shutdown, {:bad_stream_event, event}} = catch_exit(pump(state))
      assert elem(event, 0) in [:rejected_tool_call, :message_end, :text_delta], model
      Task.shutdown(state.task, :brutal_kill)
    end
  end

  describe "in a session" do
    setup :start_core

    test "a bad event ends the provider process and its model Task", %{core: core} do
      gate = Helyx.Test.Gate.open()
      {:ok, session} = Session.start(core, model: "test/bad_event." <> gate)
      {:ok, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")

      assert_receive {:waiting, task}
      provider = :sys.get_state(Session.pid(session)).conn.pid
      refs = for pid <- [task, provider], do: Process.monitor(pid)
      send(task, :go)

      for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _})

      assert {:bad_stream_event, {:message_end, :end_turn, %{}}} =
               List.last(collect_until(:agent_end)).data.error
    end

    @tag :capture_log
    test "after a failed model call the provider process takes the next turn", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/crash")
      {:ok, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      assert {:task_exit, _} = List.last(collect_until(:agent_end)).data.error
      provider = :sys.get_state(Session.pid(session)).conn.pid

      :ok = Session.prompt(session, "again")
      assert stop_reason(collect_until(:agent_end)) == :error
      assert :sys.get_state(Session.pid(session)).conn.pid == provider
    end
  end
end
