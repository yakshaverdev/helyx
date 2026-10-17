defmodule Helyx.Session.TailSnapshotTest do
  # A tail snapshot with the full state, and the history pages of the live
  # transcript (docs/features/session-snapshot.md, "Tail", "History", #658).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Message, Session}
  alias Helyx.Session.Totals

  setup :start_core

  # The "usage" model: the user message, an assistant message with a call
  # and a full usage, its result, and an assistant message with the unknown
  # usage.
  defp session_with_turn(core) do
    {:ok, session} = Session.start(core, model: "test/usage")
    {:ok, _, ref} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    collect_until(:turn_end)
    Process.demonitor(ref, [:flush])
    session
  end

  test "a tail leaves out old messages and keeps the totals and the context of all", %{core: core} do
    session = session_with_turn(core)
    {:ok, full, _} = Session.subscribe(session)

    assert [%{role: :user}, %{role: :assistant, usage: %{cost: 0.5}}, %{role: :tool_result}, last] =
             full.messages

    refute full.more
    assert {full.usage, full.context} == Totals.of(full.messages)

    assert %Totals{input: 3, output: 4, cache_read: 5, cache_write: 6, unknown: true, list: true} =
             full.usage

    assert full.usage.cost == 0.5

    {:ok, tail, _} = Session.subscribe(session, tail: 1)
    assert tail.messages == [last]
    assert tail.more
    # The tail has no message with a cost, and the totals still count it.
    assert {tail.usage, tail.context} == {full.usage, full.context}

    # Two would start at the result: the cut moves to the last message.
    assert {:ok, %{messages: [^last], more: true}, _} = Session.subscribe(session, tail: 2)
    assert {:ok, %{messages: messages, more: true}, _} = Session.subscribe(session, tail: 3)
    assert messages == tl(full.messages)
    assert Map.drop(tail, [:messages, :more]) == Map.drop(full, [:messages, :more])
  end

  test "a tail during a turn keeps the turn and its partial", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/hang")
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Helyx.Event{type: :message_update}}

    {:ok, full, _} = Session.subscribe(session)
    {:ok, tail, _} = Session.subscribe(session, tail: 1)
    assert %{id: _, partial: %Message{role: :assistant}} = tail.turn
    assert tail.turn.partial == full.turn.partial
    assert {tail.seq, tail.queue, tail.messages} == {full.seq, full.queue, full.messages}
    :ok = Session.abort(session)
  end

  test "the pages before the tail give the rest of the transcript, and change no state",
       %{core: core} do
    session = session_with_turn(core)
    {:ok, full, _} = Session.subscribe(session)
    {:ok, tail, _} = Session.subscribe(session, tail: 1)
    [first] = tail.messages

    assert {:ok, %{messages: older, more: true, next: next}} =
             Session.history(session, tail.instance_id, first.id, limit: 1)

    # The page of one would start at the result: it is the group of the call.
    assert older == Enum.slice(full.messages, 1, 2)
    assert next == hd(older).id

    assert Session.history(session, tail.instance_id, next) ==
             {:ok, %{messages: [hd(full.messages)], more: false, next: nil}}

    # No event, and the same seq, totals, and transcript.
    refute_received {:helyx_event, _}
    assert {:ok, ^full, _} = Session.subscribe(session)
  end

  test "the errors of a page and of a tail", %{core: core} do
    session = session_with_turn(core)
    {:ok, snapshot, _} = Session.subscribe(session)
    id = hd(snapshot.messages).id

    assert Session.history(session, "other", id) == {:error, :instance_changed}
    assert Session.history(session, snapshot.instance_id, "nope") == {:error, :unknown_message}

    for bad <- [[limit: 0], [limit: 1_001], [tail: 5]] do
      assert Session.history(session, snapshot.instance_id, id, bad) == {:error, :invalid_limit}
    end

    assert {:ok, %{messages: [_ | _]}} =
             Session.history(session, snapshot.instance_id, List.last(snapshot.messages).id,
               limit: 1_000
             )

    gone = %Session{id: "nosuchsessio", core: core}
    assert Session.history(gone, snapshot.instance_id, id) == {:error, :session_not_found}
    assert Session.subscribe(gone, tail: 5) == {:error, :session_not_found}
  end

  test "a bad tail is :invalid_limit before the session is called, with no subscription",
       %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")

    for bad <- [[tail: 0], [tail: 1_001], [tail: :all], [limit: 5]] do
      assert Session.subscribe(session, bad) == {:error, :invalid_limit}
    end

    gone = %Session{id: "nosuchsessio", core: core}
    assert Session.subscribe(gone, tail: 0) == {:error, :invalid_limit}

    assert :sys.get_state(Session.pid(session)).subscribers == %{}
    assert mailbox() == []
  end

  # The live transcript of a resume holds the interrupted result, which the
  # file does not hold, and a page serves it.
  @tag :tmp_dir
  test "a page of a resumed session holds the interrupted result of the resume",
       %{core: core, tmp_dir: dir} do
    call = %Message.ToolCall{id: "c1", name: "slow", arguments: %{}}
    {:ok, file} = Session.File.create(dir, "tailpage0000", File.cwd!(), "test/ok")

    file
    |> Helyx.Test.SessionFile.append_message(Message.user("push"))
    |> Helyx.Test.SessionFile.append_message(%Message{
      role: :assistant,
      model: "test/ok",
      stop_reason: :tool_use,
      content: [call]
    })
    |> Helyx.Test.SessionFile.append_message(Message.user("later"))

    {:ok, session} = Session.resume(core, sessions_dir: dir)
    {:ok, tail, _} = Session.subscribe(session, tail: 1)
    assert [%{role: :user} = later] = tail.messages
    assert Message.text(later) == "later"

    {:ok, %{messages: [assistant, interrupted], more: true}} =
      Session.history(session, tail.instance_id, later.id, limit: 2)

    assert interrupted.role == :tool_result
    assert interrupted.id == assistant.id <> ":0"
  end
end
