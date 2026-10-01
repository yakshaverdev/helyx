defmodule Helyx.Session.HarnessTest do
  # The harness process of a connected provider (ADR 0007), driven through
  # the session with the fake connected provider. The rows of the Bounds and
  # Ownership tables of `docs/features/long-lived-harness.md` that #199
  # builds each have a test here.
  use ExUnit.Case, async: true

  import Helyx.Test.Events

  alias Helyx.{Message, Session}
  alias Helyx.Test.Connected

  setup do
    core = :"core_#{System.unique_integer([:positive])}"

    plugins = [
      Connected,
      Helyx.Test.Provider,
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
              Map.new(Keyword.take(bounds, [:turn, :interrupt, :steer, :close, :idle]))
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
      # The session waits for the release: no turn, the follow-up still
      # queued, and the session not blocked on the suspended hands.
      assert %{turn: nil, queue: %{follow_ups: 1}} = GenServer.call(pid, :snapshot)
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
      assert %{activity: %{phase: :preparing}} = :sys.get_state(pid)
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
      assert_receive {:conn, :init, harness, _}

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
      assert_receive {:conn, :init, harness, _}

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

  describe "steer (#202)" do
    # A turn in `submitted`: its `:ok` came before its first delta.
    defp submitted(core, model, bounds \\ []) do
      {session, pid, _hands} = start(core, model, bounds)
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, {:turn, turn_id, _}}
      collect_until(:message_update)
      {session, pid, harness, turn_id}
    end

    defp unconfirmed(events), do: for(%{type: :steer_unconfirmed, data: data} <- events, do: data)

    defp ends(events) do
      for %{type: :message_end, data: %{message: m}} <- events, do: {m.role, Message.text(m)}
    end

    test "on a submitted turn reaches the harness, and the user message joins where it took it",
         %{core: core} do
      {session, _pid, harness, turn_id} = submitted(core, "steer_take")
      :ok = Session.steer(session, "more")
      assert_receive {:conn, :steer, ^harness, {:steer, ^turn_id, steer_id, "more"}}
      assert is_binary(steer_id)

      send(harness, {:finish, turn_id})
      events = collect_until(:agent_end)
      assert ends(events) == [{:assistant, "so far"}, {:user, "more"}, {:assistant, ""}]
      assert unconfirmed(events) == []
      refute Enum.any?(events, &(&1.type == :queue_update))
    end

    test "while preparing joins the prompt of the turn and is not sent as a steer",
         %{core: core} do
      {session, pid, hands} = start(core, "echo")
      turn(session, "zero")
      assert_received {:conn, :turn, _harness, _zero}
      :erlang.suspend_process(hands)
      :ok = Session.prompt(session, "one")
      assert %{activity: %{phase: :preparing}} = :sys.get_state(pid)
      :ok = Session.steer(session, "later")
      :erlang.resume_process(hands)

      events = collect_until(:agent_end)
      assert final_text(events) == "echo:prepared|later"
      assert_received {:conn, :turn, _harness, {:turn, _, context}}
      assert context.messages |> Enum.take(-2) |> Enum.map(&Message.text/1) == ["one", "later"]
      refute_received {:conn, :steer, _, _}
    end

    test "while submitting stays local and goes out as a steer after the :ok", %{core: core} do
      {session, pid, _hands} = start(core, "late_turn")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, {:turn, turn_id, _}}
      :erlang.suspend_process(harness)
      assert %{activity: %{phase: :submitting}} = :sys.get_state(pid)
      :ok = Session.steer(session, "more")
      assert %{data: %{steers: 1}} = List.last(collect_until(:queue_update))
      refute_received {:conn, :steer, _, _}
      :erlang.resume_process(harness)

      assert_receive {:conn, :steer, ^harness, {:steer, ^turn_id, _, "more"}}, 2_000
      # "late_turn" ends the turn with its :ok, so the steer's answer, :ok
      # with no user message, comes after the terminal: a notice then.
      collect_until(:agent_end)
      assert unconfirmed(collect_until(:steer_unconfirmed)) == [%{text: "more"}]
    end

    test "rejected after the terminal waits for its answer, then starts the next turn",
         %{core: core} do
      {session, _pid, harness, turn_id} = submitted(core, "steer_hold")
      :ok = Session.steer(session, "more")
      assert_receive {:held, from}
      send(harness, {:finish, turn_id})
      events = collect_until(:agent_end)
      assert unconfirmed(events) == []

      send(harness, {:answer, from, :rejected})
      assert_receive {:conn, :turn, ^harness, {:turn, _, context}}
      assert Message.text(List.last(context.messages)) == "more"
    end

    test "an abort in the wait for a steer answer gives its notice, and a late :rejected starts no turn",
         %{core: core} do
      {session, pid, harness, turn_id} = submitted(core, "steer_hold")
      :ok = Session.steer(session, "more")
      assert_receive {:held, from}
      send(harness, {:finish, turn_id})
      collect_until(:agent_end)

      # The abort waits for the open request.
      abort = Task.async(fn -> Session.abort(session) end)
      assert unconfirmed(collect_until(:steer_unconfirmed)) == [%{text: "more"}]
      send(harness, {:answer, from, :rejected})
      assert :ok = Task.await(abort)
      assert %{turn: nil, queue: %{steers: 0}} = GenServer.call(pid, :snapshot)
      refute_received {:conn, :turn, _, _}
    end

    test "an abort in the wait for a taken steer's answer starts no turn before the answer",
         %{core: core} do
      {session, _pid, harness, turn_id} = submitted(core, "steer_early")
      :ok = Session.steer(session, "more")
      assert_receive {:held, from}
      send(harness, {:finish, turn_id})
      collect_until(:agent_end)

      :ok = Session.follow_up(session, "next")
      collect_until(:queue_update)
      abort = Task.async(fn -> Session.abort(session) end)
      # The abort drops the follow-up; the wait still holds the request.
      assert %{data: %{follow_ups: 0}} = List.last(collect_until(:queue_update))
      send(harness, {:answer, from, :ok})
      assert :ok = Task.await(abort)
      refute_received {:helyx_event, %{type: :steer_unconfirmed}}
      refute_received {:conn, :turn, _, _}
    end

    test "taken before its answer: the turn end waits for the answer, with no notice",
         %{core: core} do
      {session, pid, harness, turn_id} = submitted(core, "steer_early")
      :ok = Session.steer(session, "more")
      assert_receive {:held, from}
      send(harness, {:finish, turn_id})
      events = collect_until(:agent_end)
      assert {:user, "more"} in ends(events)

      :ok = Session.follow_up(session, "next")
      # The wait holds the open request: the follow-up stays queued.
      assert %{turn: nil, queue: %{follow_ups: 1}} = GenServer.call(pid, :snapshot)
      send(harness, {:answer, from, :ok})
      assert_receive {:conn, :turn, ^harness, {:turn, _, context}}
      assert Message.text(List.last(context.messages)) == "next"
      refute_received {:helyx_event, %{type: :steer_unconfirmed}}
    end

    test "rejected during the turn waits in the local queue for the next turn", %{core: core} do
      {session, _pid, harness, turn_id} = submitted(core, "steer_reject")
      :ok = Session.steer(session, "more")
      assert %{data: %{steers: 1}} = List.last(collect_until(:queue_update))
      send(harness, {:finish, turn_id})
      assert unconfirmed(collect_until(:agent_end)) == []

      assert_receive {:conn, :turn, ^harness, {:turn, _, context}}
      assert Message.text(List.last(context.messages)) == "more"
    end

    for model <- ["hang", "steer_error"] do
      test "#{model}: a steer with no user message ends in a notice and is not sent again",
           %{core: core} do
        {session, pid, harness, turn_id} = submitted(core, unquote(model))
        :ok = Session.steer(session, "more")
        assert_receive {:conn, :steer, ^harness, _}
        send(harness, {:finish, turn_id})

        events = collect_until(:agent_end)
        assert unconfirmed(events) == [%{text: "more"}]
        assert Enum.find_index(events, &(&1.type == :steer_unconfirmed)) < length(events) - 1
        assert %{turn: nil, queue: %{steers: 0}} = GenServer.call(pid, :snapshot)
        # No wait is left: a follow-up starts a turn at once, with no queue
        # update (the events go out before the reply).
        :ok = Session.follow_up(session, "next")
        refute_received {:helyx_event, %{type: :queue_update}}
      end
    end

    test "an abort with a steer that has no answer gives a notice", %{core: core} do
      {session, pid, harness, _turn_id} = submitted(core, "steer_hold")
      :ok = Session.steer(session, "more")
      assert_receive {:held, from}
      abort = Task.async(fn -> Session.abort(session) end)
      assert unconfirmed(collect_until(:agent_end)) == [%{text: "more"}]
      send(harness, {:answer, from, :rejected})
      assert :ok = Task.await(abort)
      assert %{queue: %{steers: 0}} = GenServer.call(pid, :snapshot)
    end

    test "a failed turn with a steer that has no answer gives a notice; a late :rejected starts no turn",
         %{core: core} do
      {session, _pid, harness, turn_id} = submitted(core, "steer_hold")
      :ok = Session.steer(session, "more")
      assert_receive {:held, from}
      send(harness, {:fail, turn_id})
      events = collect_until(:agent_end)
      assert unconfirmed(events) == [%{text: "more"}]
      assert error(events) == :failed
      :ok = Session.follow_up(session, "next")
      refute_received {:conn, :turn, _, _}
      send(harness, {:answer, from, :rejected})
      assert_receive {:conn, :turn, ^harness, {:turn, _, context}}
      assert Message.text(List.last(context.messages)) == "next"
      refute_received {:helyx_event, %{type: :steer_unconfirmed}}
    end

    test "the harness_down in the wait after an abort ends its open steer requests",
         %{core: core} do
      {session, pid, harness, _turn_id} = submitted(core, "steer_hold")
      :ok = Session.steer(session, "more")
      assert_receive {:held, _from}
      abort = Task.async(fn -> Session.abort(session) end)
      assert unconfirmed(collect_until(:agent_end)) == [%{text: "more"}]
      send(harness, :stop)
      assert :ok = Task.await(abort)
      assert %{harness: nil} = :sys.get_state(pid)
      assert %{queue: %{steers: 0}} = GenServer.call(pid, :snapshot)
      refute_received {:helyx_event, %{type: :steer_unconfirmed}}
    end

    test "a steer callback that blocks is killed at the steer bound; the turn fails with a notice",
         %{core: core} do
      {session, _pid, harness, _turn_id} = submitted(core, "steer_block", steer: 100)
      ref = Process.monitor(harness)
      :ok = Session.steer(session, "more")
      assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000

      events = collect_until(:agent_end)
      assert unconfirmed(events) == [%{text: "more"}]
      assert error(events) == :harness_timeout
    end

    # The loop answers the ninth open request itself; the 32 steers count
    # the held ones, and the 24 unknown ones get their notice at the end.
    test "sent steers count in the 32; over 8 open requests the loop answers :busy",
         %{core: core} do
      {session, _pid, harness, turn_id} = submitted(core, "steer_hold")
      for n <- 1..32, do: :ok = Session.steer(session, "s#{n}")
      assert Session.steer(session, "s33") == {:error, :queue_full}
      for _ <- 1..8, do: assert_receive({:held, _from})
      refute_received {:held, _from}

      send(harness, {:finish, turn_id})
      assert length(unconfirmed(collect_until(:agent_end))) == 24

      send(harness, :stop)
      notices = for _ <- 1..8, do: hd(collect_until(:steer_unconfirmed) |> unconfirmed())
      assert Enum.sort(Enum.map(notices, & &1.text)) == Enum.sort(for n <- 1..8, do: "s#{n}")
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

  describe "program turn (#240)" do
    @done {:done, %{stop_reason: :end_turn, usage: %{}}}

    # A session after one "echo" turn, idle, and its harness process.
    defp idle(core) do
      {session, pid, _hands} = start(core, "echo")
      turn(session, "one")
      assert_received {:conn, :init, harness, _}
      {session, pid, harness}
    end

    test "with no turn opens a turn with origin :program and no user message",
         %{core: core} do
      {_session, pid, harness} = idle(core)

      send(
        harness,
        {:batch, [{:event, "p1", :program_turn}, {:event, "p1", {:text_delta, "bg"}}]}
      )

      send(harness, {:batch, [{:event, "p1", @done}]})
      events = collect_until(:agent_end)

      assert [:agent_start, :turn_start | _] = Enum.map(events, & &1.type)
      assert Enum.all?(events, &(&1.turn_id == "p1"))
      assert %{origin: :program} = Enum.at(events, 1).data
      assert final_text(events) == "bg"

      assert [:user, :assistant, :assistant] =
               Enum.map(:sys.get_state(pid).transcript, & &1.role)
    end

    test "a steer goes to it, and an abort interrupts it", %{core: core} do
      {session, _pid, harness} = idle(core)
      send(harness, {:batch, [{:event, "p1", :program_turn}]})
      collect_until(:turn_start)

      :ok = Session.steer(session, "more")
      assert_receive {:conn, :steer, ^harness, {:steer, "p1", _steer_id, "more"}}
      :ok = Session.abort(session)
      assert_receive {:conn, :interrupt, ^harness, {:interrupt, "p1"}}
      assert Process.alive?(harness)
    end

    test "during a turn is dropped with its events", %{core: core} do
      {session, _pid, _hands} = start(core, "hang")
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :turn, harness, {:turn, turn_id, _}}

      events = [{:event, "p1", :program_turn}, {:event, "p1", {:text_delta, "bg"}}]
      send(harness, {:batch, events ++ [{:event, "p1", @done}]})
      send(harness, {:finish, turn_id})
      events = collect_until(:agent_end)

      assert Enum.all?(events, &(&1.turn_id == turn_id))
      assert final_text(events) == "so far"
    end

    test "with a turn id that is not a harness id stops the harness process", %{core: core} do
      {_session, _pid, harness} = idle(core)
      ref = Process.monitor(harness)
      send(harness, {:batch, [{:event, "", :program_turn}]})
      assert_receive {:DOWN, ^ref, :process, _, _}
    end
  end

  describe "idle close" do
    test "after the idle time with no turn it closes the program; the next turn starts a new one",
         %{core: core} do
      {session, _pid, _hands} = start(core, "echo", idle: 100)
      turn(session, "one")
      assert_received {:conn, :init, harness, _}
      ref = Process.monitor(harness)

      assert_receive {:conn, :idle_close, ^harness, :idle_close}
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
      assert_receive {:conn, :idle_close, ^harness, :idle_close}
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
      assert_receive {:conn, :idle_close, ^harness, :idle_close}
    end

    test "a :busy answer keeps the program and arms the timer again", %{core: core} do
      {session, _pid, _hands} = start(core, "busy", idle: 100)
      turn(session, "one")
      assert_received {:conn, :init, harness, _}

      assert_receive {:conn, :idle_close, ^harness, :idle_close}
      assert_receive {:conn, :idle_close, ^harness, :idle_close}
      assert Process.alive?(harness)

      assert final_text(turn(session, "two")) == "echo:prepared|two"
      assert_received {:conn, :turn, ^harness, _}
      refute_received {:conn, :init, _, _}
    end

    test "a prompt during the idle close waits and runs on a new program", %{core: core} do
      {session, _pid, _hands} = start(core, "late_idle", idle: 100)
      turn(session, "one")
      assert_received {:conn, :init, harness, _}

      assert_receive {:conn, :idle_close, ^harness, :idle_close}
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

        assert_receive {:conn, :idle_close, ^harness, :idle_close}
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

      assert_receive {:conn, :idle_close, ^harness, :idle_close}
      :ok = Session.prompt(session, "two")
      assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000
      assert final_text(collect_until(:agent_end)) == "echo:prepared|two"
      assert_received {:conn, :init, new, _}
      assert new != harness
    end
  end

  # #227: a local turn checks the context of each plugin like a connected
  # turn.
  describe "the context check of a local turn" do
    for {mode, model, text} <- [{"local", "test/system", "prepared"}],
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

  # #282: two Cores that resumed one session continue one harness session.
  # A fork below its label drops it, so a later resume of either branch
  # starts a fresh harness session and gets the branch replayed.
  describe "two Cores on one session file" do
    @describetag :tmp_dir

    # The registry entry frees after the process is gone; polls every
    # 10 ms, for at most 5 s.
    defp stop(session) do
      GenServer.stop(Session.pid(session))
      wait_free(Helyx.Core.sessions_registry(session.core), session.id, 500)
    end

    defp wait_free(registry, id, tries) when tries > 0 do
      if Registry.lookup(registry, id) != [] do
        Process.sleep(10)
        wait_free(registry, id, tries - 1)
      end
    end

    defp wait_free(_registry, _id, 0), do: flunk("the registry entry did not free")

    defp label(events), do: Enum.find(events, &(&1.type == :harness_session)).data

    defp init_label do
      assert_receive {:conn, :init, _, {"label", _, opts}}
      opts[:harness_session_id]
    end

    test "a resume of a branch with a fork below its label starts a fresh harness session",
         %{core: core, tmp_dir: dir} do
      other = :"core_#{System.unique_integer([:positive])}"
      start_supervised!({Helyx.Core, name: other, plugins: [Connected]}, id: other)

      {:ok, a} = Session.start(core, model: "conn/label", sessions_dir: dir)
      {:ok, _} = Session.subscribe(a)
      %{harness_session_id: first} = label(turn(a, "shared"))
      assert init_label() == nil

      # B continues the label too: the hole of two live Cores.
      {:ok, b} = Session.resume(other, sessions_dir: dir)
      {:ok, _} = Session.subscribe(b)
      refute Enum.any?(turn(b, "b1"), &(&1.type == :harness_session))
      turn(a, "a1")
      stop(a)
      stop(b)

      # A wrote last, so its branch resumes, with a fork below the label.
      {:ok, resumed} = Session.resume(core, sessions_dir: dir)
      {:ok, _} = Session.subscribe(resumed)
      events = turn(resumed, "a2")
      assert init_label() == nil
      assert %{harness_session_id: second, lost: false} = label(events)
      assert second != first

      # The new label has no fork below it, so the next resume continues it.
      stop(resumed)
      {:ok, resumed} = Session.resume(core, sessions_dir: dir)
      {:ok, _} = Session.subscribe(resumed)
      turn(resumed, "a3")
      assert init_label() == second
    end
  end
end
