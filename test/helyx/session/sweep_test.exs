defmodule Helyx.Session.SweepTest do
  # Client calls during a sweep of the hands (#93).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Event, Session}
  alias Helyx.Test.Gate

  setup :start_core

  describe "client calls during a sweep of the hands (issue #93)" do
    # The "stuck" turn holds a handle whose release waits for the gate of
    # this test, and one that stays held, so each sweep ends unconfirmed. The
    # release waits until the test sends :go, so a call that answers before
    # that did not wait for the sweep, whatever the load.

    # Starts a turn whose tool call holds a handle that no release confirms.
    defp start_stuck_turn(core) do
      {:ok, session} = Session.start(core, model: "test/stuck")
      {:ok, _, _} = Session.subscribe(session)
      hands = :sys.get_state(Session.pid(session)).hands
      :erlang.trace(hands, true, [:receive])

      :ok = Session.prompt(session, Gate.open())

      assert_receive {:helyx_event,
                      %Event{type: :message_end, data: %{message: %{role: :assistant}}}}

      {session, hands, await_tool_task(hands)}
    end

    # The pid of the tool Task, once the hands handled its two hold calls.
    defp await_tool_task(hands) do
      assert_receive {:trace, ^hands, :receive, {:"$gen_call", {task, _}, {:hold, _}}}
      assert_receive {:trace, ^hands, :receive, {:"$gen_call", {^task, _}, {:hold, _}}}
      :erlang.trace(hands, false, [:receive])
      assert [{^task, [_, _]}] = Map.to_list(:sys.get_state(hands).held)
      task
    end

    # Runs the call and returns its result, or the exit.
    defp result_or_exit(fun) do
      fun.()
    catch
      :exit, {reason, _call} -> {:exit, reason}
    end

    # Makes every client call but abort while the release waits, and returns
    # the results and the release. The release waits for :go, so a call that
    # waits for the sweep exits at its timeout, and the check fails.
    defp calls(session) do
      assert_receive {:waiting, release}

      results = [
        set_model: result_or_exit(fn -> Session.set_model(session, "test/stuck") end),
        steer: result_or_exit(fn -> Session.steer(session, "steer") end),
        follow_up: result_or_exit(fn -> Session.follow_up(session, "follow") end),
        prompt: result_or_exit(fn -> Session.prompt(session, "prompt") end)
      ]

      for {name, result} <- results,
          do: refute(match?({:exit, _}, result), "#{name} waited for the sweep")

      {results, release}
    end

    @tag :capture_log
    test "every client call answers during the sweep of an abort", %{core: core} do
      {session, _hands, _task} = start_stuck_turn(core)

      abort = Task.async(fn -> Session.abort(session) end)
      # The events of the abort go out at the start of the sweep.
      assert stop_reason(collect_until(:turn_end)) == :aborted

      {results, release} = calls(session)
      assert results[:steer] == :ok
      assert results[:follow_up] == :ok
      assert results[:prompt] == :ok

      # The abort waits for the sweep, and no turn starts during it: the
      # hands cannot take a tool call.
      assert Task.yield(abort, 0) == nil
      send(release, :go)
      assert :ok = Task.await(abort, wait_ms())

      # The messages sent during the sweep start one turn after it, steers
      # first.
      events = collect_until(:turn_end)
      assert user_texts(events) == ["steer", "follow", "prompt"]
      assert stop_reason(events) == :end_turn
    end

    @tag :capture_log
    test "an abort whose cleanup fails gives a notice and still replies :ok", %{core: core} do
      {session, _hands, _task} = start_stuck_turn(core)

      abort = Task.async(fn -> Session.abort(session) end)
      assert stop_reason(collect_until(:turn_end)) == :aborted
      assert_receive {:waiting, release}
      send(release, :go)
      assert :ok = Task.await(abort, wait_ms())

      assert_receive {:helyx_event,
                      %Event{
                        type: :notice,
                        turn_id: nil,
                        data: %{text: "abort cleanup failed" <> _}
                      }}
    end

    @tag :capture_log
    test "a second abort during the sweep drops the messages sent before it", %{core: core} do
      {session, _hands, _task} = start_stuck_turn(core)

      abort = Task.async(fn -> Session.abort(session) end)
      assert queue_counts(collect_until(:turn_end)) == []
      assert_receive {:waiting, release}
      :ok = Session.prompt(session, "dropped")

      assert_receive {:helyx_event,
                      %Event{type: :queue_update, data: %{steers: 0, follow_ups: 1}}}

      second = Task.async(fn -> Session.abort(session) end)

      assert_receive {:helyx_event,
                      %Event{type: :queue_update, data: %{steers: 0, follow_ups: 0}}}

      send(release, :go)
      assert :ok = Task.await(second, wait_ms())
      assert :ok = Task.await(abort, wait_ms())

      refute_receive {:helyx_event, %Event{type: :queue_update}}, 100
      refute_receive {:helyx_event, %Event{type: :turn_start}}, 100
    end

    @tag :capture_log
    test "every client call answers during the sweep of a delivered call", %{core: core} do
      {session, _hands, task} = start_stuck_turn(core)

      # The Task dies, and the hands release its handles before the result.
      Process.exit(task, :kill)
      {results, release} = calls(session)
      assert results[:prompt] == {:error, :turn_running}
      send(release, :go)

      events = collect_until(:turn_end)
      assert [%{message: result}] = of_type(events, :tool_execution_end)
      assert Helyx.Message.text(result) =~ "could not be released"
    end

    @tag :capture_log
    test "hands that die during the sweep stop the session and the abort call", %{core: core} do
      {session, hands, _task} = start_stuck_turn(core)
      ref = Process.monitor(Session.pid(session))

      abort = Task.async(fn -> Session.abort(session) end)
      collect_until(:turn_end)
      assert_receive {:waiting, _release}
      Process.exit(hands, :kill)

      assert_receive {:DOWN, ^ref, :process, _pid, :killed}
      assert {:error, :session_not_found} = Task.await(abort, wait_ms())
    end
  end
end
