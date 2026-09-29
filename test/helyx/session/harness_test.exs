defmodule Helyx.Session.HarnessTest do
  # The harness process of a connected provider (ADR 0007), driven through
  # the session with the fake connected provider. The rows of the Bounds and
  # Ownership tables of `docs/features/long-lived-harness.md` that #199
  # builds each have a test here.
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message, Session}
  alias Helyx.Test.Connected

  setup do
    core = :"core_#{System.unique_integer([:positive])}"

    plugins = [
      Connected,
      Helyx.Test.Provider,
      Helyx.Test.Harness,
      Helyx.Test.PrepareContext,
      Helyx.Test.PrepareCompaction,
      Helyx.Test.Tool.Upcase
    ]

    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    Process.register(self(), Connected.controller(core))
    %{core: core}
  end

  # Starts a session with the bounds in `bounds` (`turn`, `interrupt`,
  # `close`, `idle` of the session; `connect`, `prepare` of the hands), subscribes,
  # and returns the session, its pid, and its hands.
  defp start(core, model, bounds \\ []) do
    {:ok, session} = Session.start(core, model: "conn/#{model}")
    pid = Session.pid(session)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | harness_ms:
            Map.merge(
              state.harness_ms,
              Map.new(Keyword.take(bounds, [:turn, :interrupt, :close, :idle]))
            )
      }
    end)

    hands = :sys.get_state(pid).hands

    :sys.replace_state(hands, fn state ->
      %{
        state
        | connect_ms: Keyword.get(bounds, :connect, state.connect_ms),
          prepare_ms: Keyword.get(bounds, :prepare, state.prepare_ms)
      }
    end)

    {:ok, _} = Session.subscribe(session)
    {session, pid, hands}
  end

  defp collect_until(type, acc \\ []) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect_until(type, [event | acc])
    after
      3_000 -> flunk("timed out waiting for #{type}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  defp error(events), do: List.last(events).data[:error]

  defp final_text(events) do
    Message.text(Enum.find(events, &(&1.type == :turn_end)).data.message)
  end

  # Runs one turn and returns its events.
  defp turn(session, text) do
    :ok = Session.prompt(session, text)
    collect_until(:agent_end)
  end

  describe "the harness process" do
    test "starts once with the tool specs, takes each turn with the prepared context, and lives on",
         %{core: core} do
      {session, _pid, _hands} = start(core, "echo")
      cwd = File.cwd!()

      assert final_text(turn(session, "one")) == "echo:prepared|one"
      assert_received {:conn, :init, harness, {"echo", [%{name: "upcase"}], opts}}
      assert opts[:cwd] == cwd and opts[:harness_session_id] == nil
      assert_received {:conn, :turn, ^harness, {:turn, _turn_id, _context}}

      assert final_text(turn(session, "two")) == "echo:prepared|two"
      assert_received {:conn, :turn, ^harness, _request}
      refute_received {:conn, :init, _, _}
      assert Process.alive?(harness)
    end

    test "a turn reply that comes late, within the bound, keeps the turn", %{core: core} do
      {session, _pid, _hands} = start(core, "late_turn")
      assert final_text(turn(session, "one")) == "echo:prepared|one"
    end

    test "a steer on a connected turn waits for the next turn", %{core: core} do
      {session, _pid, _hands} = start(core, "hang")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, {:turn, turn_id, _}}

      :ok = Session.steer(session, "more")
      assert [%{data: %{follow_ups: 1}}] = [List.last(collect_until(:queue_update))]
      send(harness, {:finish, turn_id})
      collect_until(:agent_end)

      assert_receive {:conn, :turn, ^harness, {:turn, _, context}}
      assert Message.text(List.last(context.messages)) == "more"
    end

    # The hands release the closed harness process and end before the
    # session does, so no release runs after a Core stop took the task
    # supervisor (#219).
    test "the session end closes it, releases it, and stops the hands first", %{core: core} do
      {session, pid, hands} = start(core, "echo")
      turn(session, "one")
      assert_received {:conn, :init, harness, _}
      ref = Process.monitor(harness)
      hands_ref = Process.monitor(hands)

      GenServer.stop(pid)
      assert_received {:conn, :close, ^harness, :close}
      assert_received {:DOWN, ^ref, :process, _, _}
      assert_received {:release, :deliver, [{:report, _}]}
      assert_received {:DOWN, ^hands_ref, :process, _, :shutdown}
    end

    test "the session end during a turn stops the hands first", %{core: core} do
      {session, pid, hands} = start(core, "hang")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, _}
      ref = Process.monitor(harness)
      hands_ref = Process.monitor(hands)

      GenServer.stop(pid)
      assert_received {:DOWN, ^hands_ref, :process, _, :shutdown}
      assert_receive {:DOWN, ^ref, :process, _, _}
    end

    test "a model switch closes it and releases its handles; the next turn runs on the new model",
         %{core: core} do
      {session, _pid, _hands} = start(core, "echo")
      turn(session, "one")
      assert_received {:conn, :init, harness, _}

      :ok = Session.set_model(session, "test/ok")
      assert_receive {:conn, :close, ^harness, :close}
      assert_receive {:release, :deliver, [{:report, _}]}
      assert final_text(turn(session, "two")) == "ok"
    end

    # #219: the switch close clears the current harness process; the wait
    # still holds it, and a session end closes and releases it.
    test "a Core stop during a switch close closes and releases the program", %{core: core} do
      {session, _pid, hands} = start(core, "late_close")
      turn(session, "one")
      assert_received {:conn, :init, harness, _}
      ref = Process.monitor(harness)
      hands_ref = Process.monitor(hands)

      :ok = Session.set_model(session, "test/ok")
      assert_receive {:conn, :close, ^harness, :close}
      Process.flag(:trap_exit, true)
      :ok = stop_supervised(core)
      assert_received {:DOWN, ^ref, :process, _, :normal}
      assert_received {:release, :deliver, [{:report, _}]}
      assert_received {:DOWN, ^hands_ref, :process, _, :shutdown}
    end

    test "a close that blocks is killed at the bound; a prompt waits for it", %{core: core} do
      {session, _pid, _hands} = start(core, "block_close", close: 200)
      turn(session, "one")
      assert_received {:conn, :init, old, _}
      ref = Process.monitor(old)

      :ok = Session.set_model(session, "conn/echo")
      :ok = Session.prompt(session, "two")
      assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000
      assert final_text(collect_until(:agent_end)) == "echo:prepared|two"
      assert_received {:conn, :init, new, {"echo", _, _}}
      assert new != old
    end
  end

  describe "failures" do
    test "a connect that blocks is killed at the bound while the session and the hands are suspended",
         %{core: core} do
      {session, pid, hands} = start(core, "block_init", connect: 300)
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :init, harness, _}
      ref = Process.monitor(harness)

      :erlang.suspend_process(pid)
      :erlang.suspend_process(hands)
      assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000
      :erlang.resume_process(hands)
      :erlang.resume_process(pid)

      assert error(collect_until(:agent_end)) == :harness_timeout
      assert_receive {:release, :deliver, [{:report, _}]}
    end

    test "a turn callback that blocks is killed at the bound while the session and the hands are suspended",
         %{core: core} do
      {session, pid, hands} = start(core, "block_turn", turn: 300)
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, _}
      ref = Process.monitor(harness)

      :erlang.suspend_process(pid)
      :erlang.suspend_process(hands)
      assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000
      :erlang.resume_process(hands)
      :erlang.resume_process(pid)

      assert error(collect_until(:agent_end)) == :harness_timeout
      assert_receive {:release, :deliver, [{:report, _}]}
    end

    test "a failed connect fails the turn; the next turn starts a new harness process",
         %{core: core} do
      {session, _pid, _hands} = start(core, "fail_init")
      assert error(turn(session, "one")) == {:harness_init, :no_program}
      assert_received {:conn, :init, first, _}

      assert error(turn(session, "two")) == {:harness_init, :no_program}
      assert_received {:conn, :init, second, _}
      assert first != second
    end

    for {model, reason} <- [
          {"error_turn", {:harness_error, :turn, :refused}},
          {"bad_action", {:bad_action, :bogus}},
          {"bad_event", {:bad_stream_event, {:text_delta, 42}}}
        ] do
      test "#{model} stops the harness process and fails the turn", %{core: core} do
        {session, _pid, _hands} = start(core, unquote(model))
        assert error(turn(session, "one")) == unquote(Macro.escape(reason))
        assert_received {:conn, :init, harness, _}
        assert_received {:conn, :turn, ^harness, _}
        refute Process.alive?(harness)
        assert_received {:release, :deliver, [{:report, _}]}
      end
    end

    test "a reply of the wrong shape stops the harness process", %{core: core} do
      {session, _pid, _hands} = start(core, "bad_reply")
      assert {:bad_action, {:reply, _from, :maybe}} = error(turn(session, "one"))
    end

    @tag :capture_log
    test "a crash in a callback fails the turn", %{core: core} do
      {session, _pid, _hands} = start(core, "crash_turn")

      assert {:task_exit, {%RuntimeError{message: "turn crashed"}, _}} =
               error(turn(session, "one"))
    end

    test "a stop from harness_info fails the turn", %{core: core} do
      {session, _pid, _hands} = start(core, "stop")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, _}
      send(harness, :stop)
      assert error(collect_until(:agent_end)) == {:harness_stop, :gone}
    end

    test "a prompt after an idle harness process ends waits for the release of its handles",
         %{core: core} do
      {session, _pid, hands} = start(core, "stop")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, old, {:turn, turn_id, _}}
      assert_received {:conn, :init, ^old, _}
      send(old, {:finish, turn_id})
      collect_until(:agent_end)

      ref = Process.monitor(old)
      :erlang.suspend_process(hands)
      send(old, :stop)
      assert_receive {:DOWN, ^ref, :process, _, _}

      assert :ok = Session.prompt(session, "two")
      refute_received {:conn, :init, _, _}
      :erlang.resume_process(hands)

      assert_receive {:release, :deliver, [{:report, _}]}
      assert_receive {:conn, :init, new, {"stop", _, _}}
      assert_receive {:conn, :turn, ^new, {:turn, _, context}}
      assert Message.text(List.last(context.messages)) == "two"
    end

    test "a turn that ends as its harness process ends waits for the release before the next turn",
         %{core: core} do
      {session, pid, hands} = start(core, "stop")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, old, {:turn, turn_id, _}}
      assert_received {:conn, :init, ^old, _}
      :ok = Session.follow_up(session, "two")

      ref = Process.monitor(old)
      :erlang.suspend_process(pid)
      :erlang.suspend_process(hands)
      send(old, {:finish, turn_id})
      send(old, :stop)
      assert_receive {:DOWN, ^ref, :process, _, _}
      :erlang.resume_process(pid)

      assert List.last(collect_until(:agent_end)).data.stop_reason == :end_turn
      assert %{harness: nil, aborting: %{harness: ^old}} = :sys.get_state(pid)
      refute_received {:conn, :init, _, _}
      :erlang.resume_process(hands)

      assert_receive {:release, :deliver, [{:report, _}]}
      assert_receive {:conn, :init, new, _}
      assert_receive {:conn, :turn, ^new, {:turn, _, context}}
      assert Message.text(List.last(context.messages)) == "two"
    end

    test "a harness process that ends after the check fails the new turn at its release",
         %{core: core} do
      {session, pid, hands} = start(core, "stop")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, old, {:turn, turn_id, _}}
      send(old, {:finish, turn_id})
      collect_until(:agent_end)

      ref = Process.monitor(old)
      :erlang.suspend_process(hands)
      :ok = Session.prompt(session, "two")
      assert %{turn: %{phase: :preparing}} = :sys.get_state(pid)
      send(old, :stop)
      assert_receive {:DOWN, ^ref, :process, _, _}
      :erlang.resume_process(hands)

      assert error(collect_until(:agent_end)) == {:harness_stop, :gone}
      assert_receive {:release, :deliver, [{:report, _}]}
      :ok = Session.prompt(session, "three")
      assert_receive {:conn, :turn, new, {:turn, _, _}}
      assert new != old
    end

    test "a steer during the wait for an ended harness process goes first", %{core: core} do
      {session, _pid, hands} = start(core, "stop")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, old, {:turn, turn_id, _}}
      send(old, {:finish, turn_id})
      collect_until(:agent_end)

      ref = Process.monitor(old)
      :erlang.suspend_process(hands)
      send(old, :stop)
      assert_receive {:DOWN, ^ref, :process, _, _}
      :ok = Session.prompt(session, "A")
      :ok = Session.steer(session, "B")
      :erlang.resume_process(hands)

      assert_receive {:conn, :turn, new, {:turn, _, context}}
      assert new != old
      texts = context.messages |> Enum.take(-2) |> Enum.map(&Message.text/1)
      assert texts == ["B", "A"]
    end

    test "a steer on a preparing turn waits for the next turn", %{core: core} do
      {session, pid, hands} = start(core, "echo")
      turn(session, "zero")
      :erlang.suspend_process(hands)
      :ok = Session.prompt(session, "one")
      assert %{turn: %{phase: :preparing}} = :sys.get_state(pid)
      :ok = Session.steer(session, "later")
      :erlang.resume_process(hands)

      events = collect_until(:agent_end)
      assert Enum.any?(events, &(&1.type == :queue_update and &1.data.follow_ups == 1))
      assert final_text(events) == "echo:prepared|one"
      assert final_text(collect_until(:agent_end)) == "echo:prepared|later"
    end

    for {text, kind} <- [
          {"nil_build", :model_context},
          {"bad_build", :model_context},
          {"forged_build", :model_context},
          {"bad_system", :model_context},
          {"bad_messages", :compaction},
          {"nil_compact", :compaction},
          {"bad_compact", :compaction}
        ] do
      test "#{text} fails the turn and keeps the harness process", %{core: core} do
        {session, _pid, _hands} = start(core, "echo")
        assert final_text(turn(session, "one")) == "echo:prepared|one"
        assert_received {:conn, :init, harness, _}
        assert_received {:conn, :turn, ^harness, _}

        assert error(turn(session, unquote(text))) ==
                 {:bad_context, unquote(kind)}

        refute_received {:conn, :turn, ^harness, {:turn, _, _}}
        assert final_text(turn(session, "two")) == "echo:prepared|two"
        assert_received {:conn, :turn, ^harness, _}
      end
    end

    @tag :capture_log
    test "a prepare that raises fails the turn and keeps the harness process", %{core: core} do
      {session, _pid, _hands} = start(core, "echo")
      assert {:task_exit, _reason} = error(turn(session, "raise_prepare"))
      # The connect races the prepare Task, so the init message can come
      # after the turn ends. The wait is for a message that must come, not
      # an upper bound.
      assert_receive {:conn, :init, harness, _}, 1_000

      assert final_text(turn(session, "two")) == "echo:prepared|two"
      assert_received {:conn, :turn, ^harness, _}
      refute_received {:conn, :init, _, _}
    end

    test "a prepare that blocks is killed at the bound and keeps the harness process",
         %{core: core} do
      {session, _pid, _hands} = start(core, "echo", prepare: 200)
      assert error(turn(session, "block_prepare")) == {:task_exit, :killed}
      # The connect races the prepare Task, so the init message can come
      # after the turn ends. The wait is for a message that must come, not
      # an upper bound.
      assert_receive {:conn, :init, harness, _}, 1_000

      assert final_text(turn(session, "two")) == "echo:prepared|two"
      assert_received {:conn, :turn, ^harness, _}
    end

    test "a flood of events over the session mailbox cap stops the harness process",
         %{core: core} do
      {session, pid, _hands} = start(core, "flood")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, {:turn, turn_id, _}}
      collect_until(:message_update)
      ref = Process.monitor(harness)

      :erlang.suspend_process(pid)
      send(harness, {:flood, turn_id})
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
      :erlang.resume_process(pid)

      assert {:session_behind, _length, 10_000} = error(collect_until(:agent_end))
    end
  end

  describe "abort" do
    test "while preparing kills the prepare Task and leaves the harness process", %{core: core} do
      {session, _pid, _hands} = start(core, "echo")
      :ok = Session.prompt(session, "block_prepare")
      assert_receive {:conn, :init, harness, _}

      :ok = Session.abort(session)
      collect_until(:agent_end)
      refute_received {:conn, :interrupt, _, _}
      assert final_text(turn(session, "two")) == "echo:prepared|two"
      assert_received {:conn, :turn, ^harness, _}
    end

    test "while submitting sends the interrupt after the turn and keeps the harness process",
         %{core: core} do
      {session, _pid, _hands} = start(core, "late_turn")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, {:turn, turn_id, _}}

      :ok = Session.abort(session)
      assert_received {:conn, :interrupt, ^harness, {:interrupt, ^turn_id}}
      assert Process.alive?(harness)
      collect_until(:agent_end)

      # The late reply and events of the aborted turn are dropped.
      events = turn(session, "two")
      assert final_text(events) == "echo:prepared|two"
      refute Enum.any?(events, &(&1.data[:text_delta] == "echo:prepared|one"))
    end

    test "while submitted interrupts and keeps the harness process for the next turn",
         %{core: core} do
      {session, _pid, _hands} = start(core, "hang")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :init, harness, _}
      assert_receive {:conn, :turn, ^harness, {:turn, turn_id, _}}
      collect_until(:message_update)

      :ok = Session.abort(session)
      assert_received {:conn, :interrupt, ^harness, {:interrupt, ^turn_id}}

      :ok = Session.prompt(session, "two")
      assert_receive {:conn, :turn, ^harness, _}
      refute_received {:conn, :init, _, _}
    end

    test "an interrupt answered late, within the bound, keeps the harness process",
         %{core: core} do
      {session, _pid, _hands} = start(core, "late_interrupt")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, _}

      :ok = Session.abort(session)
      assert_received {:conn, :interrupt, ^harness, _}
      assert Process.alive?(harness)
    end

    for {model, bounds} <- [{"block_interrupt", [interrupt: 200]}, {"error_interrupt", []}] do
      test "#{model}: the abort returns after the harness process is stopped and released",
           %{core: core} do
        {session, _pid, _hands} = start(core, unquote(model), unquote(bounds))
        :ok = Session.prompt(session, "one")
        assert_receive {:conn, :init, harness, _}
        assert_receive {:conn, :turn, ^harness, _}

        :ok = Session.abort(session)
        refute Process.alive?(harness)
        assert_received {:release, :deliver, [{:report, _}]}

        :ok = Session.prompt(session, "two")
        assert_receive {:conn, :init, new, _}
        assert new != harness
      end
    end
  end

  describe "idle close" do
    test "after the idle time with no turn it closes the program; the next turn starts a new one",
         %{core: core} do
      {session, _pid, _hands} = start(core, "echo", idle: 100)
      turn(session, "one")
      assert_received {:conn, :init, harness, _}
      ref = Process.monitor(harness)

      assert_receive {:conn, :idle_close, ^harness, :idle_close}, 1_000
      assert_receive {:DOWN, ^ref, :process, _, _}
      assert_receive {:release, :deliver, [{:report, _}]}

      assert final_text(turn(session, "two")) == "echo:prepared|two"
      assert_received {:conn, :init, new, _}
      assert new != harness
    end

    test "is never sent while a turn runs, and the idle time starts again at its end",
         %{core: core} do
      {session, _pid, _hands} = start(core, "hang", idle: 100)
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, {:turn, turn_id, _}}

      refute_receive {:conn, :idle_close, _, _}, 300
      send(harness, {:finish, turn_id})
      collect_until(:agent_end)
      refute_receive {:conn, :idle_close, _, _}, 50
      assert_receive {:conn, :idle_close, ^harness, :idle_close}, 1_000
    end

    test "is 30 minutes by default", %{core: core} do
      {:ok, session} = Session.start(core, model: "conn/echo")
      assert :sys.get_state(Session.pid(session)).harness_ms.idle == 1_800_000
    end

    test "the end of an abort arms the timer again", %{core: core} do
      {session, _pid, _hands} = start(core, "hang", idle: 100)
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, _}
      refute_receive {:conn, :idle_close, _, _}, 200

      :ok = Session.abort(session)
      assert_received {:conn, :interrupt, ^harness, _}
      assert_receive {:conn, :idle_close, ^harness, :idle_close}, 1_000
    end

    test "a :busy answer keeps the program and arms the timer again", %{core: core} do
      {session, _pid, _hands} = start(core, "busy", idle: 100)
      turn(session, "one")
      assert_received {:conn, :init, harness, _}

      assert_receive {:conn, :idle_close, ^harness, :idle_close}, 1_000
      assert_receive {:conn, :idle_close, ^harness, :idle_close}, 1_000
      assert Process.alive?(harness)

      assert final_text(turn(session, "two")) == "echo:prepared|two"
      assert_received {:conn, :turn, ^harness, _}
      refute_received {:conn, :init, _, _}
    end

    test "a prompt during the idle close waits and runs on a new program", %{core: core} do
      {session, _pid, _hands} = start(core, "late_idle", idle: 100)
      turn(session, "one")
      assert_received {:conn, :init, harness, _}

      assert_receive {:conn, :idle_close, ^harness, :idle_close}, 1_000
      :ok = Session.prompt(session, "two")
      assert final_text(collect_until(:agent_end)) == "echo:prepared|two"
      refute Process.alive?(harness)
      assert_received {:conn, :init, new, _}
      assert new != harness
    end

    # #219: a session end during a wait closes the harness process within
    # the close bound, and the hands release it before they stop.
    for model <- ["late_idle", "busy"] do
      test "#{model}: a Core stop during the idle close closes and releases the program",
           %{core: core} do
        {session, _pid, hands} = start(core, unquote(model), idle: 100)
        turn(session, "one")
        assert_received {:conn, :init, harness, _}
        ref = Process.monitor(harness)
        hands_ref = Process.monitor(hands)

        assert_receive {:conn, :idle_close, ^harness, :idle_close}, 1_000
        Process.flag(:trap_exit, true)
        :ok = stop_supervised(core)
        assert_received {:DOWN, ^ref, :process, _, :normal}
        assert_received {:release, :deliver, [{:report, _}]}
        assert_received {:DOWN, ^hands_ref, :process, _, :shutdown}
      end
    end

    test "a Core stop during the interrupt of an abort closes and releases the program",
         %{core: core} do
      {session, _pid, hands} = start(core, "late_interrupt")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, _}
      ref = Process.monitor(harness)
      hands_ref = Process.monitor(hands)

      # The abort returns only after the interrupt answer, 100 ms late.
      {:ok, _} = Task.start(fn -> Session.abort(session) end)
      assert_receive {:conn, :interrupt, ^harness, _}
      Process.flag(:trap_exit, true)
      :ok = stop_supervised(core)
      assert_received {:DOWN, ^ref, :process, _, :normal}
      assert_received {:release, :deliver, [{:report, _}]}
      assert_received {:DOWN, ^hands_ref, :process, _, :shutdown}
    end

    test "an idle close that blocks is killed at the close bound", %{core: core} do
      {session, _pid, _hands} = start(core, "block_idle", idle: 100, close: 200)
      turn(session, "one")
      assert_received {:conn, :init, harness, _}
      ref = Process.monitor(harness)

      assert_receive {:conn, :idle_close, ^harness, :idle_close}, 1_000
      :ok = Session.prompt(session, "two")
      assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000
      assert final_text(collect_until(:agent_end)) == "echo:prepared|two"
      assert_received {:conn, :init, new, _}
      assert new != harness
    end
  end

  # #227: a local and an external turn check the context of each plugin like
  # a connected turn.
  describe "the context check of a local and an external turn" do
    for {mode, model, text} <- [
          {"local", "test/system", "prepared"},
          {"external", "harness/id1", "ok"}
        ],
        {prompt, kind} <- [
          {"nil_build", :model_context},
          {"bad_build", :model_context},
          {"forged_build", :model_context},
          {"bad_system", :model_context},
          {"bad_messages_build", :model_context},
          {"nil_compact", :compaction},
          {"bad_compact", :compaction},
          {"forged_compact", :compaction},
          {"bad_system_compact", :compaction},
          {"bad_messages", :compaction}
        ] do
      test "#{prompt} fails a #{mode} turn, and the next turn succeeds", %{core: core} do
        {:ok, session} = Session.start(core, model: unquote(model))
        {:ok, _} = Session.subscribe(session)

        assert error(turn(session, unquote(prompt))) == {:bad_context, unquote(kind)}
        assert final_text(turn(session, "two")) == unquote(text)
      end
    end
  end
end
