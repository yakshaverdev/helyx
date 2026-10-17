defmodule Helyx.Session.HandsBusyTest do
  # A provider start while the hands are busy (#677): the session takes the
  # answer of the hands in its loop, so it takes calls while it waits
  # (docs/features/session-lifecycle.md, "Provider death"). A suspended
  # hands process stands in for a release that blocks it past any call
  # timeout.
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.Session

  setup :start_core

  defp start(core) do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _, _} = Session.subscribe(session)
    {session, :sys.get_state(Session.pid(session)).hands}
  end

  defp state(session), do: :sys.get_state(Session.pid(session))

  test "a turn start waits for busy hands, and the session takes calls meanwhile",
       %{core: core} do
    {session, hands} = start(core)
    :sys.suspend(hands)

    assert :ok = Session.prompt(session, "hi")
    assert {:error, :turn_running} = Session.prompt(session, "again")
    assert %{conn: %{pid: nil, status: :starting}} = state(session)

    :sys.resume(hands)
    assert stop_reason(collect_until(:turn_end)) == :end_turn
  end

  test "an abort while the start waits ends the turn, and the wait holds until the answer",
       %{core: core} do
    {session, hands} = start(core)
    :sys.suspend(hands)
    :ok = Session.prompt(session, "hi")
    abort = Task.async(fn -> Session.abort(session) end)

    assert List.last(collect_until(:turn_end)).data == %{outcome: :aborted}
    # The suspended hands cannot answer, so the wait cannot end.
    assert Task.yield(abort, 0) == nil
    assert :ok = Session.follow_up(session, "next")

    :sys.resume(hands)
    assert :ok = Task.await(abort)

    # The follow-up runs.
    assert stop_reason(collect_until(:turn_end)) == :end_turn
    assert %{activity: :idle, conn: %{pid: pid, status: :ready}} = state(session)
    assert is_pid(pid)
  end

  # `Helyx.Test.Connected` reports its `init/3` to the test process. The
  # process runs as one whose start answer came before the abort (#726), and
  # its idle close is armed.
  test "a start whose turn ended runs init/3, and the session idles with the process",
       %{core: core} do
    Process.register(self(), Helyx.Test.Connected.controller(core))
    {:ok, session} = Session.start(core, model: "conn/hang")
    {:ok, _, _} = Session.subscribe(session)
    hands = state(session).hands
    :sys.suspend(hands)
    :ok = Session.prompt(session, "hi")
    abort = Task.async(fn -> Session.abort(session) end)
    assert List.last(collect_until(:turn_end)).data == %{outcome: :aborted}

    :sys.resume(hands)
    assert :ok = Task.await(abort)
    assert_receive {:conn, :init, proc, _}

    wait_until(fn ->
      match?(
        %{activity: :idle, idle: ref, conn: %{pid: ^proc, status: :ready}} when ref != nil,
        state(session)
      )
    end)
  end

  # An unconfirmed handle makes the hands refuse the start.
  defp refuse(hands), do: :sys.replace_state(hands, &%{&1 | unconfirmed?: true})

  test "a refused start fails the turn with the text of the hands", %{core: core} do
    {session, hands} = start(core)
    refuse(hands)
    :ok = Session.prompt(session, "hi")

    assert List.last(collect_until(:turn_end)).data == %{
             outcome: :error,
             error: "a resource from an earlier call could not be released; the call was not run"
           }

    assert %{conn: nil} = state(session)
  end

  test "a refused start in the wait of an aborted turn ends the wait", %{core: core} do
    {session, hands} = start(core)
    :sys.suspend(hands)
    :ok = Session.prompt(session, "hi")
    abort = Task.async(fn -> Session.abort(session) end)
    assert List.last(collect_until(:turn_end)).data == %{outcome: :aborted}
    refuse(hands)

    :sys.resume(hands)
    assert :ok = Task.await(abort)
    assert %{activity: :idle, conn: nil} = state(session)
  end
end
