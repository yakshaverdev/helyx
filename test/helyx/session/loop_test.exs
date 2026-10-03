defmodule Helyx.Session.LoopTest do
  # The turn loop: the provider context, tool calls, abort, the ownership
  # chain, and steers and follow-ups.
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Event, Session}

  setup :start_core

  defp turn_end_usage(events),
    do: final_message(events).usage

  test "the provider context goes through model context, then compaction" do
    core = start_core([Helyx.Test.Provider, Helyx.Test.ModelContext, Helyx.Test.Compaction])

    {:ok, session} = Session.start(core, model: "test/system")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:turn_end)) == "built for #{File.cwd!()}, compacted"
  end

  test "without model context and compaction plugins the context is unchanged", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/system")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:turn_end)) == "no system"
  end

  test "the hands report the registered tools and the provider sees them", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/tools")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:turn_end)) == "binary,hold,kill,slow,upcase"
  end

  test "tool calls run on the hands and the loop continues until the provider stops", %{
    core: core
  } do
    {:ok, session} = Session.start(core, model: "test/loop")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)
    assert final_text(events) == "HI|unknown tool: nope"

    types = Enum.map(events, & &1.type)
    assert Enum.count(types, &(&1 == :turn_start)) == 1
    assert Enum.count(types, &(&1 == :turn_end)) == 1
    assert Enum.count(types, &(&1 == :tool_execution_end)) == 2
    assert Enum.map(events, & &1.seq) == Enum.to_list(1..length(events))

    ends = for %{type: :tool_execution_end, data: data} <- events, do: data.message
    by_id = Map.new(ends, &{&1.tool_call_id, &1})
    assert %Helyx.Message{role: :tool_result, tool_name: "upcase", is_error: false} = by_id["c1"]
    assert %Helyx.Message{role: :tool_result, tool_name: "nope", is_error: true} = by_id["c2"]
    assert Helyx.Message.text(by_id["c1"]) == "HI"
  end

  # One encode of the 400,000 digits took 5.8 s alone on 2026-10-02. The
  # right code sends each event in milliseconds, so 3 s for each event is
  # the margin for load, and a slow encode fails the test.
  @load_event_ms 3_000

  @tag :tmp_dir
  test "a tool call with an integer over the digit limit gets an error result and never runs",
       %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/big_int", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end, @load_event_ms)

    rejected = "tool call not run: an integer in the arguments has more than 100 digits"
    assert final_text(events) == "#{rejected}|TWO|THREE|FOUR|#{rejected}|#{rejected}"

    assert %{input: 2, output: 3} = turn_end_usage(events)

    [first, _, third, _, fifth, sixth] =
      for %{type: :message_end, data: %{message: %{role: :assistant} = m}} <- events,
          %Helyx.Message.ToolCall{} = call <- m.content,
          do: call

    assert first.arguments == %{}
    assert third.arguments["n"] == 10 ** 100 - 1
    assert fifth.arguments == %{}
    assert sixth.arguments == %{}

    [result | _] = for %{type: :tool_execution_end, data: %{message: m}} <- events, do: m
    assert %Helyx.Message{tool_call_id: "c1", is_error: true} = result

    # No event, and thus no later encode, holds the large integer.
    refute Enum.any?(events, &(:erlang.external_size(&1) > 10_000))
    [path] = Path.wildcard(Path.join(dir, "**/*.jsonl"))
    assert File.stat!(path).size < 10_000
    assert Enum.map(events, & &1.seq) == Enum.to_list(1..length(events))
  end

  test "a call whose arguments are not a JSON object gets an error result; the text and the good call stay",
       %{core: core} do
    {:ok, session} = Session.start(core, model: "test/rejected")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)

    # The next provider call gets both results, in call order.
    rejected = "tool call not run: the arguments are not a valid JSON object"
    assert final_text(events) == "ONE|#{rejected}"

    [first_end | _] =
      for %{type: :message_end, data: %{message: %{role: :assistant} = m}} <- events, do: m

    assert [
             %Helyx.Message.Text{text: "Trying"},
             %Helyx.Message.ToolCall{id: "c1"},
             %Helyx.Message.ToolCall{id: "c2", arguments: %{}}
           ] = first_end.content

    ends = for %{type: :tool_execution_end, data: data} <- events, do: data.message

    assert [
             %Helyx.Message{tool_call_id: "c1", is_error: false},
             %Helyx.Message{tool_call_id: "c2", is_error: true} = bad
           ] = ends

    assert Helyx.Message.text(bad) == rejected
  end

  test "tool calls run one at a time, in call order", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/serial")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)
    assert final_text(events) == "1|2|3"

    order =
      for %{type: :tool_execution_end, data: d} <- events, do: d.message.tool_call_id

    # The results come in call order.
    assert order == ["1", "2", "3"]
  end

  @tag :tmp_dir
  test "a terminal the file cannot hold fails the turn and leaves persistence on", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/recover", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)

    assert {:bad_stream_event, {:done, %{usage: %{"in" => {1, 2}}}}} =
             List.last(events).data.error

    :ok = Session.prompt(session, "again")
    collect_until(:turn_end)

    {:ok, restored} = Helyx.Session.File.resume(dir, File.cwd!())
    assert "recovered" in Enum.map(restored.messages, &Helyx.Message.text/1)
  end

  test "a tool result with invalid bytes is made valid before it reaches the session", %{
    core: core
  } do
    {:ok, session} = Session.start(core, model: "test/binary")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)
    assert final_text(events) == "a�b"

    result = Enum.find(events, &(&1.type == :tool_execution_end)).data.message
    assert Helyx.Message.text(result) == "a�b"
    refute result.is_error

    # The second turn runs the tool again with the repaired result in the
    # transcript.
    :ok = Session.prompt(session, "again")
    events = collect_until(:turn_end)
    assert stop_reason(events) == :end_turn
    result = Enum.find(events, &(&1.type == :tool_execution_end)).data.message
    assert Helyx.Message.text(result) == "a�b"
  end

  test "a tool Task that dies gives an error result and the loop continues", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/kill")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)
    assert stop_reason(events) == :end_turn
    assert final_text(events) == "tool crashed: :killed"
  end

  test "two tools with one name are rejected at session start" do
    core = start_core([Helyx.Test.Provider, Helyx.Test.Tool.Upcase, Helyx.Test.Tool.UpcaseTwin])

    assert {:error, {:duplicate_tool_name, "upcase"}} = Session.start(core, model: "test/ok")
  end

  test "abort during tool calls ends the turn and answers every open call", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")

    assert_receive {:helyx_event,
                    %Event{type: :message_end, data: %{message: %{role: :assistant}}} = started}

    :ok = Session.abort(session)
    events = collect_until(:turn_end)
    assert stop_reason(events) == :aborted

    results = for %{type: :tool_execution_end, data: %{message: m}} <- events, do: m
    assert length(results) == 3
    assert Enum.all?(results, & &1.is_error)
    assert Enum.all?(results, &(Helyx.Message.text(&1) == "aborted"))

    # A late result for the aborted turn is dropped.
    [{pid, _}] = Registry.lookup(Helyx.Core.sessions_registry(core), session.id)
    send(pid, {:tool_result, started.turn_id, "1", {:ok, "late"}})

    :ok = Session.prompt(session, "again")
    events = collect_until(:turn_end)
    assert final_text(events) == "aborted|aborted|aborted"
    refute Enum.any?(events, &(inspect(&1.data) =~ "late"))
  end

  test "abort during the provider stream closes the partial message", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/hang")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :message_update}}

    :ok = Session.abort(session)
    events = collect_until(:turn_end)
    assert stop_reason(events) == :aborted

    message_end =
      Enum.find(events, fn event ->
        event.type == :message_end and match?(%{role: :assistant}, event.data.message)
      end)

    assert Helyx.Message.text(message_end.data.message) == "so far"
    assert message_end.data.error == :aborted
  end

  test "abort with no running turn is ok", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _, _} = Session.subscribe(session)

    assert :ok = Session.abort(session)
    refute_received {:helyx_event, _}
  end

  # Each abort kills a model Task in the provider process. The session
  # keeps no record of it, and no signal stays in its mailbox (#261).
  test "many aborts in a row leave no growing state", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/hang")
    {:ok, _, _} = Session.subscribe(session)
    pid = Session.pid(session)

    abort = fn ->
      :ok = Session.prompt(session, "hello")
      assert_receive {:helyx_event, %Event{type: :message_update}}
      :ok = Session.abort(session)
      assert stop_reason(collect_until(:turn_end)) == :aborted
      state = :sys.get_state(pid)
      assert Process.info(pid, :message_queue_len) == {:message_queue_len, 0}
      :erts_debug.flat_size(%{state | transcript: [], seq: 0})
    end

    size = abort.()
    for _ <- 1..20, do: assert(abort.() == size)
  end

  # A crash of a linked process that is not the provider process, the sessions
  # Registry for example, must take the session with it: a session that
  # outlives its registration keeps working where no client can reach it.
  @tag :capture_log
  test "an exit that is not from the provider process stops the session", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    pid = Session.pid(session)
    ref = Process.monitor(pid)

    Process.exit(pid, {:shutdown, :registry_gone})
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :registry_gone}}
  end

  # The ownership chain (ADR 0004): work inside the VM is linked to its
  # owner, so a killed session takes the provider process, the hands, and
  # the tool Tasks with it, even through an untrappable kill. The model
  # Task is linked to the provider process (`Helyx.Provider.Loop`).
  @tag :capture_log
  test "killing the session kills the provider process", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/hang")
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :message_update}}

    [task] = Task.Supervisor.children(Helyx.Core.task_supervisor(core))
    ref = Process.monitor(task)
    Process.exit(Session.pid(session), :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  @tag :capture_log
  test "killing the session kills the hands and the tool Task", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    {:ok, _, _} = Session.subscribe(session)
    pid = Session.pid(session)
    hands = :sys.get_state(pid).hands
    :erlang.trace(hands, true, [:receive])
    :ok = Session.prompt(session, "go")

    # `Hands.run/3` is a cast, and the hands start the Task before they
    # answer the next call.
    assert_receive {:trace, ^hands, :receive, {:"$gen_cast", {:run, _, _}}}
    :erlang.trace(hands, false, [:receive])
    :sys.get_state(hands)
    provider = :sys.get_state(pid).conn.pid

    # The provider process is a Task of the hands too.
    [task] =
      for task <- Task.Supervisor.children(Helyx.Core.task_supervisor(core)),
          task != provider,
          {:dictionary, dict} = Process.info(task, :dictionary),
          Keyword.has_key?(dict, :helyx_hands) do
        task
      end

    hands_ref = Process.monitor(hands)
    task_ref = Process.monitor(task)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^hands_ref, :process, _, _}
    assert_receive {:DOWN, ^task_ref, :process, _, _}
  end

  test "steers during a tool run reach the next provider call after the result, in order" do
    core = start_core([Helyx.Test.Provider, Helyx.Test.Gate])
    {:ok, session} = Session.start(core, model: "test/steer." <> Helyx.Test.Gate.open())
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, tool}
    # The gate holds the tool, so the steers have no timer to beat. The
    # wait for both answers checks that the provider took each steer
    # before the tool result goes out.
    pid = Session.pid(session)
    :erlang.trace(pid, true, [:receive])
    :ok = Session.steer(session, "s1")
    :ok = Session.steer(session, "s2")
    assert_receive {:trace, ^pid, :receive, {:provider_reply, _, :steer, :ok}}
    assert_receive {:trace, ^pid, :receive, {:provider_reply, _, :steer, :ok}}
    :erlang.trace(pid, false, [:receive])
    send(tool, :go)

    events = collect_until(:turn_end)
    assert final_text(events) == "hello|s1|s2"

    result_at = Enum.find_index(events, &(&1.type == :tool_execution_end))

    steer_at =
      Enum.find_index(events, fn
        %Event{type: :message_end, data: %{message: %Helyx.Message{role: :user} = m}} ->
          Helyx.Message.text(m) == "s1"

        _ ->
          false
      end)

    assert result_at < steer_at
    # A steer of a running turn goes to the provider, not to the queue.
    assert queue_counts(events) == []
  end

  test "a follow-up during a turn starts a new turn after turn_end", %{core: core} do
    {:ok, session} = Session.start(core, model: gated_model())
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, stream}
    :ok = Session.follow_up(session, "next")
    send(stream, :go)

    first = collect_until(:turn_end)
    assert user_texts(first) == ["hello"]
    assert queue_counts(first) == [%{steers: 0, follow_ups: 1}]

    assert_receive {:waiting, stream}
    send(stream, :go)
    second = collect_until(:turn_end)
    assert [:queue_update, :turn_start | _] = Enum.map(second, & &1.type)
    assert List.first(second).turn_id == nil
    assert user_texts(second) == ["next"]
    assert queue_counts(second) == [%{steers: 0, follow_ups: 0}]
  end

  test "a steer in the last model call continues the same turn", %{core: core} do
    {:ok, session} = Session.start(core, model: gated_model())
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, stream}
    # The session replies before the provider process takes the steer; the
    # steer must be held before the model call ends.
    pid = Session.pid(session)
    :erlang.trace(pid, true, [:receive])
    :ok = Session.steer(session, "later")
    assert_receive {:trace, ^pid, :receive, {:provider_reply, _, :steer, :ok}}
    :erlang.trace(pid, false, [:receive])
    send(stream, :go)

    assert_receive {:waiting, stream}
    send(stream, :go)
    events = collect_until(:turn_end)
    assert user_texts(events) == ["hello", "later"]
    assert Enum.count(events, &(&1.type == :turn_start)) == 1
    refute_receive {:helyx_event, %Event{type: :turn_start}}, 100
  end

  test "a steer or follow-up with no turn running starts a turn at once", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.follow_up(session, "go")
    events = collect_until(:turn_end)
    assert user_texts(events) == ["go"]
    assert stop_reason(events) == :end_turn

    :ok = Session.steer(session, "again")
    events = collect_until(:turn_end)
    assert user_texts(events) == ["again"]
  end

  test "abort drops queued steers and follow-ups", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")

    assert_receive {:helyx_event,
                    %Event{type: :message_end, data: %{message: %{role: :assistant}}}}

    :ok = Session.steer(session, "s")
    :ok = Session.follow_up(session, "f")

    # The steer went to the provider; only the follow-up is queued.
    assert_receive {:helyx_event, %Event{type: :queue_update, data: %{steers: 0, follow_ups: 1}}}

    :ok = Session.abort(session)
    events = collect_until(:turn_end)
    assert stop_reason(events) == :aborted
    assert List.last(queue_counts(events)) == %{steers: 0, follow_ups: 0}

    refute_receive {:helyx_event, %Event{type: :turn_start}}, 100
  end

  test "a full queue rejects the next steer or follow-up", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")

    assert_receive {:helyx_event,
                    %Event{type: :message_end, data: %{message: %{role: :assistant}}}}

    # One under the limit, then at the limit, with multibyte text.
    for n <- 1..31, do: :ok = Session.steer(session, "stér #{n}")
    :ok = Session.steer(session, "stér 32 🚀")
    for n <- 1..32, do: :ok = Session.follow_up(session, "折り返し #{n}")

    # The steers went to the provider and count in the limit until their
    # `user_message`; each queued follow-up emits a queue_update.
    counts =
      for _ <- 1..32 do
        assert_receive {:helyx_event, %Event{type: :queue_update, data: data}}
        data
      end

    assert List.last(counts) == %{steers: 0, follow_ups: 32}

    # One over the limit is rejected, changes nothing, and emits no event.
    assert Session.steer(session, "s33") == {:error, :queue_full}
    assert Session.follow_up(session, "f33") == {:error, :queue_full}
    refute_received {:helyx_event, %Event{type: :queue_update}}

    :ok = Session.abort(session)
  end
end
