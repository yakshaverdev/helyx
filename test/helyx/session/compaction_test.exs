defmodule Helyx.Session.CompactionTest do
  # The compaction of the provider's own history
  # (docs/features/harness-compaction.md), through the session with the
  # fake connected provider and a provider of `Helyx.Provider.Loop`.
  use ExUnit.Case, async: true

  import Helyx.Test.Events

  alias Helyx.{Event, Session}
  alias Helyx.Test.Connected

  @done {:done, %{stop_reason: :end_turn, usage: nil}}

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Connected, Helyx.Test.Provider]})
    Process.register(self(), Connected.controller(core))
    %{core: core}
  end

  defp start(core, model, opts \\ []) do
    {:ok, session} = Session.start(core, [model: model] ++ opts)
    {:ok, _, _} = Session.subscribe(session)
    session
  end

  # Starts a compaction on an idle "hang" session and returns its request.
  defp compacting(core, model \\ "conn/hang") do
    session = start(core, model)
    assert :ok = Session.compact(session, "keep the plan")
    assert_receive {:conn, :compact, proc, {:compact, turn_id, "keep the plan"}}
    {session, proc, turn_id}
  end

  test "a compaction is a turn with no user message and no assistant message", %{core: core} do
    {session, proc, turn_id} = compacting(core)
    assert_receive {:helyx_event, %Event{type: :turn_start, turn_id: ^turn_id, data: data}}
    assert data == %{origin: :compaction}

    # A second compaction and a prompt are refused; a steer waits for the
    # next turn, as a compaction cannot be steered.
    assert {:error, :turn_running} = Session.compact(session)
    assert {:error, :turn_running} = Session.prompt(session, "now")
    assert :ok = Session.steer(session, "after")
    refute_received {:conn, :steer, _, _}

    send(proc, {:batch, [{:event, turn_id, {:compaction, 300, 40}}, {:event, turn_id, @done}]})
    events = collect_until(:turn_end)

    assert [%{trigger: :manual, tokens_before: 300, tokens_after: 40}] =
             of_type(events, :compaction)

    assert List.last(events).data == %{outcome: :done}
    assert messages(events) == []

    # The steer opens the next turn.
    assert_receive {:conn, :turn, ^proc, {:turn, _id, context}}
    assert Helyx.Message.text(List.last(context.messages)) == "after"
  end

  test "a compaction turn that ends with no compaction event fails", %{core: core} do
    {_session, proc, turn_id} = compacting(core)
    send(proc, {:batch, [{:event, turn_id, @done}]})
    events = collect_until(:turn_end)

    assert List.last(events).data == %{
             outcome: :error,
             error: "the provider reported no compaction"
           }
  end

  test "a context request in a compaction turn is a bad action", %{core: core} do
    {_session, proc, turn_id} = compacting(core, "conn/context")
    send(proc, {:need_context, turn_id, "x"})
    events = collect_until(:turn_end)
    assert %{outcome: :error, error: error} = List.last(events).data
    assert error =~ "need_context"
  end

  test "a compaction during a turn aborts the turn, then compacts", %{core: core} do
    session = start(core, "conn/hang")
    :ok = Session.prompt(session, "one")
    assert_receive {:conn, :turn, _proc, _request}
    assert_receive {:helyx_event, %Event{type: :message_update}}

    assert :ok = Session.compact(session)
    events = collect_until(:turn_end)
    assert List.last(events).data == %{outcome: :aborted}
    assert {:error, :turn_running} = Session.compact(session)

    assert_receive {:conn, :compact, _proc, {:compact, turn_id, ""}}
    assert_receive {:helyx_event, %Event{type: :turn_start, turn_id: ^turn_id}}
    refute_received {:conn, :turn, _, _}
  end

  test "an abort in the wait drops the compaction that waits", %{core: core} do
    session = start(core, "conn/late_interrupt")
    pid = Session.pid(session)
    :ok = Session.prompt(session, "one")
    assert_receive {:conn, :turn, proc, _request}

    assert :ok = Session.compact(session)
    assert_receive {:held, from}
    abort = Task.async(fn -> Session.abort(session) end)
    # The abort call reaches the session before the interrupt answer.
    Helyx.Test.SessionCase.await(
      fn ->
        match?(%Helyx.Session.Server.Wait{callers: [_ | _]}, :sys.get_state(pid).activity)
      end,
      "the abort call in the wait"
    )

    send(proc, {:answer, from, :ok})

    assert :ok = Task.await(abort)
    assert :sys.get_state(pid).activity == :idle
    refute_received {:conn, :compact, _, _}
  end

  @tag :tmp_dir
  test "a compaction in the wait starts before a queued follow-up, and the file records it",
       %{core: core, tmp_dir: dir} do
    session = start(core, "conn/late_interrupt", sessions_dir: dir)
    :ok = Session.prompt(session, "one")
    assert_receive {:conn, :turn, proc, _request}

    assert :ok = Session.compact(session, "keep")
    assert_receive {:held, from}
    assert List.last(collect_until(:turn_end)).data == %{outcome: :aborted}
    assert :ok = Session.follow_up(session, "f")
    send(proc, {:answer, from, :ok})

    assert_receive {:conn, :compact, ^proc, {:compact, turn_id, "keep"}}
    refute_received {:conn, :turn, _, _}
    send(proc, {:batch, [{:event, turn_id, {:compaction, 9, 2}}, {:event, turn_id, @done}]})
    assert_receive {:conn, :turn, ^proc, {:turn, _id, context}}
    assert Helyx.Message.text(List.last(context.messages)) == "f"

    [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
    entries = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert [%{"trigger" => "manual", "tokens_before" => 9, "tokens_after" => 2}] =
             for(%{"type" => "compaction"} = e <- entries, do: e)
  end

  test "a provider that keeps no history answers with a notice", %{core: core} do
    session = start(core, "test/ok")
    :ok = Session.prompt(session, "before")
    collect_until(:turn_end)
    provider = :sys.get_state(Session.pid(session)).conn.pid

    assert :ok = Session.compact(session)
    events = collect_until(:turn_end)

    assert [%{text: text}] = of_type(events, :notice)
    assert text =~ "no history"
    assert List.last(events).data == %{outcome: :done}
    assert messages(events) == []
    assert of_type(events, :compaction) == []

    :ok = Session.prompt(session, "after")
    assert List.last(collect_until(:turn_end)).data == %{outcome: :done}
    assert :sys.get_state(Session.pid(session)).conn.pid == provider
  end

  test "a compaction in a model turn is automatic, and the turn goes on", %{core: core} do
    session = start(core, "conn/events.compaction")
    :ok = Session.prompt(session, "one")
    events = collect_until(:turn_end)

    assert [%{trigger: :auto, tokens_before: 5, tokens_after: nil}] =
             of_type(events, :compaction)

    assert [%{role: :user}, %{role: :assistant}] = messages(events)
  end

  test "a token count is at most 10^9 and not negative", %{core: core} do
    session = start(core, "conn/events.compaction_max")
    :ok = Session.prompt(session, "one")
    events = collect_until(:turn_end)
    assert [%{tokens_before: 1_000_000_000, tokens_after: 0}] = of_type(events, :compaction)

    for name <- ["compaction_over", "compaction_neg"] do
      session = start(core, "conn/events." <> name)
      :ok = Session.prompt(session, "one")
      events = collect_until(:turn_end)
      assert of_type(events, :compaction) == []
      assert %{outcome: :error, error: error} = List.last(events).data
      assert error =~ "bad_stream_event"
    end
  end

  test "instructions that are not valid UTF-8 are refused", %{core: core} do
    session = start(core, "conn/hang")
    assert {:error, :invalid_utf8} = Session.compact(session, <<255>>)
    refute_received {:conn, :compact, _, _}
  end

  @tag :tmp_dir
  test "the session file records the compaction, and a resume adds no message", %{
    core: core,
    tmp_dir: dir
  } do
    session = start(core, "conn/events.compaction", sessions_dir: dir)
    :ok = Session.prompt(session, "one")
    collect_until(:turn_end)

    [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
    entries = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert [entry] = for(%{"type" => "compaction"} = e <- entries, do: e)

    assert %{"provider" => "conn", "trigger" => "auto", "tokens_before" => 5} = entry
    assert entry["tokens_after"] == nil

    :ok = GenServer.stop(Session.pid(session))
    assert {:ok, resumed} = Session.resume(core, sessions_dir: dir)
    {:ok, snapshot, _} = Session.subscribe(resumed)
    assert [%{role: :user}, %{role: :assistant}] = snapshot.messages
  end

  describe "a reconnect after a compaction" do
    @describetag :tmp_dir

    # A turn of a fresh program with the label "L"; its reply "so far" is
    # open. Returns the session, the provider, and the turn id.
    defp labelled(core, dir) do
      session = start(core, "conn/hang", sessions_dir: dir)
      :ok = Session.prompt(session, "one")
      assert_receive {:conn, :init, proc, {"hang", _tools, _opts}}
      assert_receive {:conn, :turn, ^proc, {:turn, turn_id, _}}
      send(proc, {:batch, [{:event, turn_id, {:resume_id, "L", 0}}]})
      assert_receive {:helyx_event, %Event{type: :resume_id}}
      {session, proc, turn_id}
    end

    defp compacted(proc) do
      assert_receive {:conn, :compact, ^proc, {:compact, turn_id, _}}
      send(proc, {:batch, [{:event, turn_id, {:compaction, 9, 2}}, {:event, turn_id, @done}]})
      assert List.last(collect_until(:turn_end)).data == %{outcome: :done}
    end

    # The session restarts from its file, as after a crash or a quit, and
    # the next turn connects a new provider process.
    defp reconnect(core, session, dir) do
      :ok = GenServer.stop(Session.pid(session))
      {:ok, resumed} = Session.resume(core, sessions_dir: dir)
      :ok = Session.prompt(resumed, "two")
      assert_receive {:conn, :init, _proc, {"hang", _tools, opts}}
      opts[:resume_id]
    end

    test "after an aborted reply, the compacted history resumes", %{core: core, tmp_dir: dir} do
      {session, proc, _turn_id} = labelled(core, dir)
      assert :ok = Session.compact(session)
      assert List.last(collect_until(:turn_end)).data == %{outcome: :aborted}
      compacted(proc)

      state = :sys.get_state(Session.pid(session))

      assert {"L", _, _} =
               Helyx.Session.Transcript.resumable(state.transcript, state.resume_ids, "conn")

      assert reconnect(core, session, dir) == "L"
    end

    test "after an idle compaction, the history resumes", %{core: core, tmp_dir: dir} do
      {session, proc, turn_id} = labelled(core, dir)
      send(proc, {:finish, turn_id})
      collect_until(:turn_end)
      assert :ok = Session.compact(session)
      compacted(proc)
      assert reconnect(core, session, dir) == "L"
    end

    test "with no compaction after an abort, the program starts fresh", %{
      core: core,
      tmp_dir: dir
    } do
      {session, _proc, _turn_id} = labelled(core, dir)
      assert :ok = Session.abort(session)
      assert reconnect(core, session, dir) == nil
    end

    test "a reply after the compaction that an abort cuts starts fresh", %{
      core: core,
      tmp_dir: dir
    } do
      {session, proc, turn_id} = labelled(core, dir)
      send(proc, {:finish, turn_id})
      collect_until(:turn_end)
      assert :ok = Session.compact(session)
      compacted(proc)
      :ok = Session.prompt(session, "after")
      assert_receive {:conn, :turn, ^proc, _request}
      assert_receive {:helyx_event, %Event{type: :message_update}}
      assert :ok = Session.abort(session)
      assert reconnect(core, session, dir) == nil
    end

    test "a new resume id after the compaction drops it", %{core: core, tmp_dir: dir} do
      {session, proc, turn_id} = labelled(core, dir)
      send(proc, {:finish, turn_id})
      collect_until(:turn_end)
      assert :ok = Session.compact(session)
      assert_receive {:conn, :compact, ^proc, {:compact, turn_id, _}}
      events = [{:compaction, 9, 2}, {:resume_id, "M", 0}, @done]
      send(proc, {:batch, Enum.map(events, &{:event, turn_id, &1})})
      assert List.last(collect_until(:turn_end)).data == %{outcome: :done}

      state = :sys.get_state(Session.pid(session))
      assert Helyx.Session.Transcript.resumable(state.transcript, state.resume_ids, "conn") == nil
      assert reconnect(core, session, dir) == nil
    end
  end
end
