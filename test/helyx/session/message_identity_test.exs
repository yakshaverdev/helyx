defmodule Helyx.Session.MessageIdentityTest do
  # A stable id on every message and an origin on every user message
  # (docs/features/message-identity.md, #649).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Event, Message, Session}

  setup :start_core

  defp event_messages(events, types) do
    for %Event{type: type, data: %{message: message}} <- events, type in types, do: message
  end

  test "each message keeps one id from its message_start to the snapshot, with no file",
       %{core: core} do
    {:ok, session} = Session.start(core, model: "test/loop")
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)
    {:ok, snapshot, _ref} = Session.subscribe(session)

    starts = event_messages(events, [:message_start])
    ends = event_messages(events, [:message_end, :tool_execution_end])
    ids = Enum.map(snapshot.messages, & &1.id)

    assert Enum.map(ends, & &1.id) == ids
    assert Enum.all?(ids, &Session.Id.valid?/1)
    assert Enum.uniq(ids) == ids
    assert Enum.map(starts, & &1.id) == for(%{role: r, id: id} <- ends, r != :tool_result, do: id)
    assert [%Message{role: :user, origin: %{kind: :user, id: nil}} | rest] = snapshot.messages
    assert Enum.all?(rest, &(&1.origin == nil))
  end

  test "the partial message of the snapshot turn has the id of its message_start",
       %{core: core} do
    {:ok, session} = Session.start(core, model: "test/hang")
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")

    assert_receive {:helyx_event,
                    %Event{type: :message_start, data: %{message: %{role: :assistant} = m}}}

    assert_receive {:helyx_event, %Event{type: :message_update}}
    {:ok, %{turn: %{partial: partial}}, _ref} = Session.subscribe(session)
    assert partial.id == m.id

    # The cut reply joins the transcript at the abort with the same id.
    :ok = Session.abort(session)
    events = collect_until(:turn_end)
    assert %{id: id, stop_reason: :aborted} = List.last(event_messages(events, [:message_end]))
    assert id == m.id
  end

  test "product code sets a :product origin on prompt, steer, and follow_up", %{core: core} do
    {:ok, session} = Session.start(core, model: gated_model())
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "p", origin: %{kind: :product, id: "job 1 · run 1"})
    assert_receive {:waiting, stream}
    :ok = Session.follow_up(session, "f", origin: %{kind: :product, id: "f1"})
    send(stream, :go)
    assert_receive {:waiting, stream}
    send(stream, :go)
    collect_until(:turn_end)
    collect_until(:turn_end)

    {:ok, snapshot, _ref} = Session.subscribe(session)

    assert [%{kind: :product, id: "job 1 · run 1"}, %{kind: :product, id: "f1"}] =
             for(%Message{role: :user, origin: o} <- snapshot.messages, do: o)
  end

  test "any other origin is :invalid_origin, and nothing is queued", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _, _} = Session.subscribe(session)

    bad = [
      [origin: %{kind: :user, id: nil}],
      [origin: %{kind: :background, id: "run000000001"}],
      [origin: %{kind: :unknown, id: nil}],
      [origin: %{kind: :product, id: ""}],
      [origin: %{kind: :product, id: nil}],
      [origin: %{kind: :product, id: String.duplicate("a", 257)}],
      [origin: %{kind: :product, id: String.duplicate("é", 128) <> "a"}],
      [origin: %{kind: :product, id: <<0xFF>>}],
      [origin: %{kind: :product, id: "x", extra: 1}],
      [origin: %{kind: :product, id: "x"}, origin: %{kind: :product, id: "y"}],
      [origin: :product],
      [other: 1]
    ]

    for opts <- bad, op <- [:prompt, :steer, :follow_up] do
      assert apply(Session, op, [session, "hi", opts]) == {:error, :invalid_origin}, inspect(opts)
    end

    refute_received {:helyx_event, _}

    # At the bound: 256 bytes, multibyte too.
    for id <- [String.duplicate("a", 256), String.duplicate("é", 128)] do
      :ok = Session.prompt(session, "hi", origin: %{kind: :product, id: id})
      collect_until(:turn_end)
    end
  end

  test "a taken steer keeps its origin, and its id reaches the snapshot" do
    core = start_core([Helyx.Test.Provider, Helyx.Test.Gate])
    {:ok, session} = Session.start(core, model: "test/steer." <> Helyx.Test.Gate.open())
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, tool}
    pid = Session.pid(session)
    :erlang.trace(pid, true, [:receive])
    :ok = Session.steer(session, "s1", origin: %{kind: :product, id: "s1"})
    assert_receive {:trace, ^pid, :receive, {:provider_reply, _, :steer, :ok}}
    :erlang.trace(pid, false, [:receive])
    send(tool, :go)
    events = collect_until(:turn_end)

    assert [%{origin: %{kind: :user}}, %{origin: %{kind: :product, id: "s1"}, id: id}] =
             for(%{role: :user} = m <- event_messages(events, [:message_end]), do: m)

    {:ok, snapshot, _ref} = Session.subscribe(session)
    assert Enum.any?(snapshot.messages, &(&1.id == id))
  end

  test "a dropped follow-up gives back its message with its origin", %{core: core} do
    {:ok, session} = Session.start(core, model: gated_model())
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, _stream}
    :ok = Session.follow_up(session, "f", origin: %{kind: :product, id: "f1"})
    :ok = Session.abort(session)

    assert [%{texts: ["f"], messages: [%Message{origin: %{kind: :product, id: "f1"}} = m]}] =
             of_type(collect_until(:turn_end), :queue_dropped)

    assert Session.Id.valid?(m.id)
  end

  @tag :tmp_dir
  test "a resume reuses the ids and the origins of the file", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/loop", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello", origin: %{kind: :product, id: "p1"})
    collect_until(:turn_end)
    {:ok, live, _ref} = Session.subscribe(session)
    stop_session(session, &GenServer.stop/1)

    {:ok, resumed} = Session.resume(core, sessions_dir: dir)
    {:ok, snapshot, _ref} = Session.subscribe(resumed)
    assert snapshot.messages == live.messages
    assert [%{kind: :product, id: "p1"} | _] = Enum.map(snapshot.messages, & &1.origin)
  end
end
