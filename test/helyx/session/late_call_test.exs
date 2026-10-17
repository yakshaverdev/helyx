defmodule Helyx.Session.LateCallTest do
  # A call that the session takes past the deadline of its caller does not
  # act (#679, docs/features/session-lifecycle.md, "Late calls").
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.Session

  setup :start_core

  # The call timeout of `Helyx.Session`.
  @call_ms 5_000

  # The request shape of `Helyx.Session`, with a deadline that has come and
  # one that has not.
  test "a call at or past its deadline does not act, a call before it acts", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    pid = Session.pid(session)
    prompt = {:prompt, "hi", %{kind: :user, id: nil}}

    # No client cleanup follows the late subscribe, so only the drop keeps
    # `other` out.
    other = spawn(fn -> Process.sleep(:infinity) end)
    now = System.monotonic_time(:millisecond)
    request = :gen_server.send_request(pid, {:until, now, prompt})
    subscribe = :gen_server.send_request(pid, {:until, now, {:subscribe, other}})
    state = :sys.get_state(pid)
    assert Map.keys(state.subscribers) == [self()]
    assert state.activity == :idle
    assert :gen_server.receive_response(request, 0) == :timeout
    assert :gen_server.receive_response(subscribe, 0) == :timeout
    refute_received {:helyx_event, _}

    assert GenServer.call(pid, {:until, System.monotonic_time(:millisecond) + 60_000, prompt}) ==
             :ok

    assert Enum.any?(collect_until(:turn_end), &(&1.type == :turn_start))
  end

  @tag :slow
  test "calls that timed out in a stalled session do not act when it goes on", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    pid = Session.pid(session)
    :ok = :sys.suspend(pid)

    calls = [
      prompt: &Session.prompt(&1, "late text"),
      steer: &Session.steer(&1, "late text"),
      follow_up: &Session.follow_up(&1, "late text"),
      compact: &Session.compact(&1, "late text"),
      set_model: &Session.set_model(&1, "test/other"),
      subscribe: &Session.subscribe/1
    ]

    test = self()

    for {name, call} <- calls do
      spawn(fn -> send(test, {name, catch_exit(call.(session))}) end)
    end

    for {name, _call} <- calls do
      assert_receive {^name, {:timeout, _}}, @call_ms + wait_ms()
    end

    # The state is a barrier behind the late calls: the session took them all.
    {state, log} =
      with_log(fn ->
        :ok = :sys.resume(pid)
        :sys.get_state(pid)
      end)

    for {name, _call} <- calls do
      assert length(String.split(log, "late session call dropped: #{name}\n")) == 2
    end

    refute log =~ "late text"
    refute_received {:helyx_event, _}
    assert state.activity == :idle
    assert state.model.model == "ok"
    assert Map.keys(state.subscribers) == [self()]

    # A call within its deadline still acts.
    :ok = Session.prompt(session, "hi")
    assert Enum.any?(collect_until(:turn_end), &(&1.type == :turn_start))
  end
end
