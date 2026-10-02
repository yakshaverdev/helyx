defmodule Helyx.Provider.ClaudeCode.IdleCloseTest do
  # The idle close between turns, and a program that exits.
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.Events
  import Helyx.Test.HarnessDriver

  alias Helyx.{Message, Session}
  alias Helyx.Provider.ClaudeCode

  @moduletag :tmp_dir

  setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

  describe "an idle close" do
    # The line of the program at each change of its live background tasks
    # (`claude` 2.1.284); `tasks` is the whole set.
    defp tasks_line(fields) do
      j(Map.merge(%{type: "system", subtype: "background_tasks_changed", uuid: "u9"}, fields))
    end

    # One turn whose program sends `lines` after its result, between
    # turns; returns the state once `done?` holds.
    defp idle(bin, work, lines, tail, done?) do
      turn(bin, 1, 1, reply("ok") ++ lines, tail)
      context = %Helyx.Context{messages: [Message.user("hi")]}
      {_from, actions, state} = request(harness(work), {:turn, "t1", context})
      {_actions, state} = pump(ClaudeCode, state, actions, &ended?/1)
      settle(ClaudeCode, state, done?)
    end

    test "with a live background task answers :busy and keeps the program; with none it closes",
         %{bin: bin, work: work} do
      task = %{task_id: "bm9v5qfnr", task_type: "local_bash", description: "sleep 12"}
      go = Path.join(bin, "go")
      File.write!(Path.join(bin, "out.rest"), tasks_line(%{tasks: []}) <> "\n")
      gate = ~s(while [ ! -e "#{go}" ]; do sleep 0.05; done; out out.rest\n)
      state = idle(bin, work, [tasks_line(%{tasks: [task]})], gate, &(&1.tasks != []))

      assert {_from, [{:reply, _, :busy}], state} = request(state, :idle_close)
      assert programs(bin) == "1"

      File.write!(go, "")
      state = settle(ClaudeCode, state, &(&1.tasks == []))
      {from, [], state} = request(state, :idle_close)
      assert {[{:reply, ^from, :ok}], _state} = pump(ClaudeCode, state, [], replied?(from))
      assert programs(bin) == "1"
    end

    # #224: a sub-agent's lines carry `parent_tool_use_id`, and a
    # background sub-agent is in the set of background tasks (research
    # note, "Sub-agents at the end of a turn").
    test "a background sub-agent gives no events and keeps the program as a background task",
         %{bin: bin, work: work} do
      sub = &String.replace(&1, ~s("parent_tool_use_id":null), ~s("parent_tool_use_id":"toolu_a"))
      own = [tool_use("toolu_s", %{command: "sleep 40"}), tool_result("toolu_s", "x"), delta("s")]
      task = %{task_id: "a1", task_type: "local_agent", description: "research"}
      text = [delta("ok"), assistant(%{type: "text", text: "ok"}), result("ok")]
      turn(bin, 1, 1, begin() ++ Enum.map(own, sub) ++ text ++ [tasks_line(%{tasks: [task]})])
      context = %Helyx.Context{messages: [Message.user("hi")]}
      {_from, actions, state} = request(harness(work), {:turn, "t1", context})
      {actions, state} = pump(ClaudeCode, state, actions, &ended?/1)

      assert [{:resume, _, 0}, {:text_delta, "ok"}, {:done, _}] =
               for({:event, "t1", event} <- actions, do: event)

      state = settle(ClaudeCode, state, &(&1.tasks != []))
      assert {_from, [{:reply, _, :busy}], _state} = request(state, :idle_close)
    end

    # #240: a program turn starts 100 to 150 ms after the notification.
    test "after a task_notification answers :busy once, then closes", %{bin: bin, work: work} do
      note =
        j(%{type: "system", subtype: "task_notification", task_id: "b1", status: "completed"})

      state = idle(bin, work, [tasks_line(%{tasks: []}), note], "", & &1.notified?)
      assert {_from, [{:reply, _, :busy}], state} = request(state, :idle_close)

      {from, [], state} = request(state, :idle_close)
      assert {[{:reply, ^from, :ok}], _state} = pump(ClaudeCode, state, [], replied?(from))
    end

    for {name, fields} <- [
          {"a null tasks", %{tasks: nil}},
          {"no tasks field", %{}},
          {"a tasks string", %{tasks: "[]"}},
          {"a tasks map", %{tasks: %{}}}
        ] do
      test "after #{name} answers :busy", %{bin: bin, work: work} do
        line = tasks_line(unquote(Macro.escape(fields)))
        state = idle(bin, work, [line], "", &(&1.tasks == :unknown))
        assert {_from, [{:reply, _, :busy}], _state} = request(state, :idle_close)
      end
    end
  end

  test "a program that exits between turns ends the provider process; the next turn resumes",
       %{bin: bin} = ctx do
    turn(bin, 1, 1, reply("Hi."), "exit 3\n")
    turn(bin, 2, 1, reply("Back."))

    session = start(ctx)
    pid = Session.pid(session)
    :erlang.trace(pid, true, [:receive])
    [%{resume_id: id}] = of_type(prompt(session, "hello"), :provider_session)
    # A turn that starts before the session saw the end runs on the old
    # provider process and fails (`docs/features/long-lived-harness.md`,
    # "Built in #199"). A later call returns after the session handled it.
    assert_receive {:trace, ^pid, :receive, {:provider_down, _, _}}
    :erlang.trace(pid, false, [:receive])
    assert :sys.get_state(pid).conn == nil
    assert [%{stop_reason: :end_turn}] = of_type(prompt(session, "again"), :agent_end)
    assert "--resume=#{id}" in args(bin, 2)
  end

  test "a program that exits during a turn fails it", %{bin: bin} = ctx do
    turn(bin, 1, 1, begin(), "exit 3\n")

    events = prompt(start(ctx), "go")

    assert [%{stop_reason: :error, error: {:provider_stop, {:claude_code_exit, 3}}}] =
             of_type(events, :agent_end)
  end
end
