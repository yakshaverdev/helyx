defmodule Helyx.Session.BackgroundDeliveryTest do
  # The end of a background run reaches the session as a user message: a
  # turn of its own while idle, a steer in a turn, held after an abort,
  # lost at a resume (docs/features/background-bash.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Event, Session}
  alias Helyx.Session.Background

  @done {:done, %{stop_reason: :end_turn, usage: nil}}

  # The test process holds the name of a gate, so a proxy holds the name
  # of the controller of `Helyx.Test.Connected` and forwards its messages.
  setup do
    core =
      start_core([
        Helyx.Test.Provider,
        Helyx.Test.Connected,
        Helyx.Test.Gate,
        Helyx.Test.Tool.Background
      ])

    test = self()
    proxy = spawn_link(fn -> forward(test) end)
    Process.register(proxy, Helyx.Test.Connected.controller(core))
    %{core: core}
  end

  defp forward(pid) do
    receive do
      message -> send(pid, message)
    end

    forward(pid)
  end

  # A session of the model "bg.<gate>": its first turn starts a background
  # run and ends. Returns the session, the waiting run, its id and its
  # output path, and the gate.
  defp started(core, opts \\ []) do
    gate = Helyx.Test.Gate.open()
    {:ok, session} = Session.start(core, [model: "test/bg." <> gate] ++ opts)
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, run}

    events = collect_until(:turn_end)
    assert final_text(events) == "hello"
    [answer] = for %{type: :tool_execution_end, data: %{message: m}} <- events, do: m
    refute answer.is_error

    [_all, id, path] =
      Regex.run(
        ~r/\A<background id="(\S+)" status="started">\nstarted (\S+)\n/,
        Helyx.Message.text(answer)
      )

    %{session: session, run: run, id: id, path: path, gate: gate}
  end

  defp done(id), do: Background.finish(id, {:ok, "done"})

  # Sends :go to the run, and returns once the session has handled its end.
  defp finish(session, run) do
    pid = Session.pid(session)
    :erlang.trace(pid, true, [:receive])
    send(run, :go)
    assert_receive {:trace, ^pid, :receive, {:background_end, _text}}
    :erlang.trace(pid, false, [:receive])
    :sys.get_state(pid)
  end

  test "an end while idle opens a turn with the end as its user message", %{core: core} do
    %{run: run, id: id} = started(core)
    send(run, :go)

    events = collect_until(:turn_end)
    assert [:turn_start | _] = Enum.map(events, & &1.type)
    assert user_texts(events) == [done(id)]
    assert final_text(events) == "hello|" <> done(id)
  end

  test "after an abort an end waits, wakes nothing, and joins the next turn", %{core: core} do
    %{session: session, run: run, id: id} = started(core)
    :ok = Session.abort(session)
    finish(session, run)
    refute_received {:helyx_event, %Event{type: :turn_start}}

    :ok = Session.prompt(session, "next")
    events = collect_until(:turn_end)
    assert Enum.count(events, &(&1.type == :turn_start)) == 1
    assert user_texts(events) == ["next", done(id)]
  end

  # #591: a client sees the held ends, so print mode does not wait for them.
  test "the held ends are counted in queue_update and in the snapshot", %{core: core} do
    %{session: session, run: run} = started(core)
    :ok = Session.abort(session)
    finish(session, run)
    held = %{steers: 0, follow_ups: 0, held: 1}
    assert_receive {:helyx_event, %Event{type: :queue_update, data: ^held}}
    assert {:ok, %{queue: ^held}, _ref} = Session.subscribe(session)

    :ok = Session.prompt(session, "next")
    events = collect_until(:turn_end)
    assert of_type(events, :queue_update) == [%{steers: 0, follow_ups: 0, held: 0}]
  end

  test "an end during a submitted turn goes to the provider as a steer", %{core: core} do
    %{session: session, run: run, id: id, gate: gate} = started(core)
    :ok = Session.set_model(session, "test/gate." <> gate)
    :ok = Session.prompt(session, "two")
    assert_receive {:waiting, stream}

    pid = Session.pid(session)
    :erlang.trace(pid, true, [:receive])
    send(run, :go)
    assert_receive {:trace, ^pid, :receive, {:provider_reply, _, :steer, :ok}}
    :erlang.trace(pid, false, [:receive])
    send(stream, :go)

    assert_receive {:waiting, stream}
    send(stream, :go)
    events = collect_until(:turn_end)
    assert Enum.count(events, &(&1.type == :turn_start)) == 1
    assert user_texts(events) == ["two", done(id)]
  end

  test "an end that waits for steer room goes in the same turn once a steer frees its place",
       %{core: core} do
    %{session: session, run: run, id: id, gate: gate} = started(core)
    :ok = Session.set_model(session, "test/gate." <> gate)
    :ok = Session.prompt(session, "two")
    assert_receive {:waiting, stream}

    pid = Session.pid(session)
    :erlang.trace(pid, true, [:receive])
    for n <- 1..32, do: :ok = Session.steer(session, "s#{n}")

    for _n <- 1..32,
        do: assert_receive({:trace, ^pid, :receive, {:provider_reply, _, :steer, :ok}})

    :erlang.trace(pid, false, [:receive])
    finish(session, run)
    assert :sys.get_state(pid).queue.ends == [done(id)]

    send(stream, :go)
    assert List.last(user_texts(drive([]))) == done(id)
  end

  test "a compaction does not end the hold of the ends", %{core: core} do
    %{session: session, run: run} = started(core)
    :ok = Session.abort(session)
    :ok = Session.set_model(session, "conn/hang")
    :ok = Session.compact(session)
    assert_receive {:conn, :compact, proc, {:compact, turn_id, _}}
    send(proc, {:batch, [{:event, turn_id, {:compaction, 300, 40}}, {:event, turn_id, @done}]})
    assert List.last(collect_until(:turn_end)).data == %{outcome: :done}

    finish(session, run)
    refute_received {:helyx_event, %Event{type: :turn_start}}
  end

  test "a failed compaction sets the hold, so a later end wakes nothing", %{core: core} do
    %{session: session, run: run} = started(core)
    :ok = Session.set_model(session, "conn/hang")
    :ok = Session.compact(session)
    assert_receive {:conn, :compact, proc, {:compact, turn_id, _}}
    send(proc, {:event, turn_id, @done})
    refute List.last(collect_until(:turn_end)).data == %{outcome: :done}

    assert %{queue: %{hold: true}} = finish(session, run)
    refute_received {:helyx_event, %Event{type: :turn_start}}
  end

  test "an end that the provider rejects waits for the next turn and is not sent again in its turn",
       %{core: core} do
    %{session: session, run: run, id: id} = started(core)
    :ok = Session.set_model(session, "conn/steer_reject")
    :ok = Session.prompt(session, "two")
    assert_receive {:conn, :turn, proc, {:turn, turn_id, _}}
    collect_until(:message_update)

    pid = Session.pid(session)
    :erlang.trace(pid, true, [:receive])
    send(run, :go)
    assert_receive {:trace, ^pid, :receive, {:provider_reply, _, :steer, :rejected}}
    :erlang.trace(pid, false, [:receive])
    assert :sys.get_state(pid).queue.ends == [done(id)]
    assert_receive {:conn, :steer, ^proc, _request}
    refute_received {:conn, :steer, _, _}

    send(proc, {:finish, turn_id})
    collect_until(:turn_end)
    assert_receive {:conn, :turn, next, {:turn, next_id, context}}
    assert Helyx.Message.text(List.last(context.messages)) == done(id)
    send(next, {:finish, next_id})
    collect_until(:turn_end)
  end

  test "an end sent with no answer in a turn that ended goes back held when the provider process ends, and joins the next prompt",
       %{core: core} do
    %{session: session, run: run, id: id} = started(core)
    :ok = Session.set_model(session, "conn/steer_hold")
    :ok = Session.prompt(session, "two")
    assert_receive {:conn, :turn, proc, {:turn, turn_id, _}}
    collect_until(:message_update)

    finish(session, run)
    assert_receive {:held, _from}
    send(proc, {:finish, turn_id})
    collect_until(:turn_end)
    refute_received {:helyx_event, %Event{type: :turn_start}}

    pid = Session.pid(session)
    :erlang.trace(pid, true, [:receive])
    send(proc, :stop)
    assert_receive {:trace, ^pid, :receive, {:provider_down, ^proc, _reason}}
    :erlang.trace(pid, false, [:receive])
    assert %{ends: [ended], hold: true} = :sys.get_state(pid).queue
    assert ended == done(id)
    refute_received {:helyx_event, %Event{type: :turn_start}}

    :ok = Session.prompt(session, "three")
    assert_receive {:conn, :turn, next, {:turn, next_id, context}}
    assert Helyx.Message.text(List.last(context.messages)) == done(id)
    send(next, {:finish, next_id})
    assert user_texts(collect_until(:turn_end)) == ["three", done(id)]
  end

  test "an end whose steer gets an error answer and no user_message goes back held, with no notice",
       %{core: core} do
    %{session: session, run: run, id: id} = started(core)
    :ok = Session.set_model(session, "conn/steer_error")
    :ok = Session.prompt(session, "two")
    assert_receive {:conn, :turn, proc, {:turn, turn_id, _}}
    collect_until(:message_update)

    finish(session, run)
    send(proc, {:finish, turn_id})
    events = collect_until(:turn_end)
    refute Enum.any?(events, &(&1.type == :steer_unconfirmed))
    assert %{ends: [ended], hold: true} = :sys.get_state(Session.pid(session)).queue
    assert ended == done(id)
    refute_received {:helyx_event, %Event{type: :turn_start}}
  end

  # Opens each gate of the turn and collects its events until `turn_end`.
  defp drive(events) do
    receive do
      {:waiting, stream} ->
        send(stream, :go)
        drive(events)

      {:helyx_event, %Event{type: :turn_end} = event} ->
        Enum.reverse([event | events])

      {:helyx_event, event} ->
        drive([event | events])
    after
      wait_ms() -> flunk("no turn_end")
    end
  end

  @tag :tmp_dir
  test "a resume gives each run that was live at the stop a lost end, held for the next turn",
       %{core: core, tmp_dir: dir} do
    %{session: session, id: id} = started(core, sessions_dir: dir)
    stop_session(session, &GenServer.stop/1)

    {:ok, resumed} = Session.resume(core, sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(resumed)
    :ok = Session.prompt(resumed, "again")

    events = collect_until(:turn_end)
    assert Enum.count(events, &(&1.type == :turn_start)) == 1
    assert ["again", lost] = user_texts(events)
    assert String.starts_with?(lost, ~s(<background id="#{id}" status="lost">\n))

    # Once it joined a turn, the lost end is a user message of the file.
    stop_session(resumed, &GenServer.stop/1)
    {:ok, again} = Session.resume(core, sessions_dir: dir)
    {:ok, snapshot, _} = Session.subscribe(again)
    assert Background.lost(snapshot.messages) == []
  end

  test "the stop of the session deletes its background folder", %{core: core} do
    %{session: session, path: path} = started(core)
    dir = Path.dirname(path)
    assert File.dir?(dir)
    assert %File.Stat{mode: mode} = File.stat!(dir)
    assert Bitwise.band(mode, 0o777) == 0o700

    stop_session(session, &GenServer.stop/1)
    refute File.exists?(dir)
  end
end
