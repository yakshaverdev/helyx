defmodule Helyx.SessionTest do
  # Session seam with a test provider whose streams end badly. The happy path
  # lives in the Fake provider plugin's tests.
  use ExUnit.Case, async: true

  import Helyx.Test.Events

  alias Helyx.{Event, Session}

  setup do
    core = :"core_#{System.unique_integer([:positive])}"

    plugins = [
      Helyx.Test.Provider,
      Helyx.Test.ProviderOther,
      Helyx.Test.Harness,
      Helyx.Test.BadTurn,
      Helyx.Test.RaisingTurn,
      Helyx.Test.Tool.Upcase,
      Helyx.Test.Tool.Kill,
      Helyx.Test.Tool.Slow,
      Helyx.Test.Tool.Binary,
      Helyx.Test.Tool.Hold
    ]

    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    %{core: core}
  end

  defp final_text(events) do
    Helyx.Message.text(Enum.find(events, &(&1.type == :turn_end)).data.message)
  end

  defp turn_end_usage(events),
    do: Enum.find(events, &(&1.type == :turn_end)).data.message.usage

  defp stop_reason(events), do: List.last(events).data.stop_reason

  # The model "test/gate.<name>" with the test process registered as <name>:
  # each turn sends {:waiting, pid} and waits for :go.
  defp gated_model, do: "test/gate." <> Helyx.Test.Gate.open()

  # Stops the session and waits until it is down. A resume that follows
  # needs no wait for the Registry cleanup: a register replaces an entry
  # whose owner is dead.
  defp stop_session(session, stop) do
    pid = Session.pid(session)
    ref = Process.monitor(pid)
    stop.(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  # The messages in the mailbox now, in order.
  defp mailbox, do: elem(Process.info(self(), :messages), 1)

  # Polls a condition every 10 ms, for at most 5 s by default.
  defp await(condition, what, tries \\ 500)
  defp await(_condition, what, 0), do: flunk("timed out waiting for #{what}")

  defp await(condition, what, tries) do
    unless condition.() do
      Process.sleep(10)
      await(condition, what, tries - 1)
    end
  end

  test "subscribe returns the empty state of a new session", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")

    assert {:ok,
            %Helyx.Session.Snapshot{
              contract_version: 1,
              seq: 0,
              messages: [],
              turn: nil,
              model: "test/ok",
              queue: %{steers: 0, follow_ups: 0}
            }} = Session.subscribe(session)
  end

  test "a snapshot of a local turn lists only the running call", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    {:ok, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    %Event{seq: seq} =
      List.last(collect_until(:tool_execution_start))

    # A second client subscribes during the turn; the test process already
    # has its registration.
    test = self()
    pid = spawn(fn -> send(test, {:snapshot, self(), Session.subscribe(session)}) end)

    assert_receive {:snapshot, ^pid, {:ok, snapshot}}
    assert %{seq: ^seq, turn: %{partial: nil, running: ["1"]}} = snapshot

    assert [%Helyx.Message{role: :user}, %Helyx.Message{role: :assistant, content: calls}] =
             snapshot.messages

    assert Enum.map(calls, & &1.id) == ["1", "2", "3"]
    :ok = Session.abort(session)
  end

  test "a stream that ends without a terminal event ends the turn with an error", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/empty")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :error
    assert List.last(events).data.error == :stream_ended

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :error
  end

  @tag :capture_log
  test "a task crash fails the turn and the session accepts the next prompt", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/crash")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :error
    assert {:task_exit, {%RuntimeError{message: "boom"}, _}} = List.last(events).data.error

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :error
  end

  # Halt-on-error only cancels the provider's request if the session never
  # pulls past the error; the fixture's tail raises on a drain.
  test "an error event fails the turn without pulling the stream further", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/error_tail")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :error
    assert List.last(events).data.error == :overloaded

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :error
  end

  test "consumption stops at the first terminal event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/overrun")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :end_turn
    assert final_text(events) == "kept"
    refute_receive {:helyx_event, _}, 100
  end

  @tag :capture_log
  test "a failure after deltas closes the partial message with an error", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/crash")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    types = Enum.map(events, & &1.type)

    assert Enum.slice(types, -4..-1) == [
             :message_start,
             :message_update,
             :message_end,
             :agent_end
           ]

    message_end = Enum.at(events, -2)
    assert %Helyx.Message{role: :assistant, stop_reason: :error} = message_end.data.message
    assert Helyx.Message.text(message_end.data.message) == "so far"
    assert {:task_exit, _} = message_end.data.error
    refute Enum.any?(events, &(&1.type == :turn_end))
  end

  test "thinking, text, and tool call events build one assistant message in order", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/blocks")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

    message =
      Enum.find_value(events, fn
        %{type: :message_end, data: %{message: %{role: :assistant} = m}} -> m
        _ -> nil
      end)

    assert message.content == [
             %Helyx.Message.Thinking{thinking: "hmm"},
             %Helyx.Message.Text{text: "Listing."},
             %Helyx.Message.ToolCall{id: "call_1", name: "bash", arguments: %{"command" => "ls"}}
           ]

    assert Helyx.Message.text(message) == "Listing."
    updates = for %{type: :message_update, data: data} <- events, do: data

    assert Enum.take(updates, 5) == [
             %{thinking_delta: "hm"},
             %{thinking_delta: "m"},
             %{text_delta: "Listing"},
             %{text_delta: "."},
             %{tool_call: List.last(message.content)}
           ]
  end

  describe "harness events (#10)" do
    defp harness_turn(core, model) do
      {:ok, session} = Session.start(core, model: "harness/#{model}")
      {:ok, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      collect_until(:agent_end)
    end

    test "a provider turn other than :local or :external is refused at start and switch",
         %{core: core} do
      assert {:error, {:bad_provider_turn, "bad_turn"}} =
               Session.start(core, model: "bad_turn/m")

      assert {:error, {:bad_provider_turn, "raising_turn"}} =
               Session.start(core, model: "raising_turn/m")

      {:ok, session} = Session.start(core, model: "test/ok")

      assert {:error, {:bad_provider_turn, "raising_turn"}} =
               Session.set_model(session, "raising_turn/m")
    end

    @tag :tmp_dir
    test "a provider turn that raises is refused at resume", %{core: core, tmp_dir: dir} do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      GenServer.stop(Session.pid(session))

      line = %{type: "model_change", id: "m1", parent_id: nil, ts: "t", model: "raising_turn/m"}
      File.write!(path, [JSON.encode!(line), "\n"], [:append])

      assert {:error, {:bad_provider_turn, "raising_turn"}} =
               Session.resume(core, sessions_dir: dir)
    end

    test "a harness session id of 1 byte is kept", %{core: core} do
      events = harness_turn(core, "id1")

      assert [%{harness_session_id: "a"}] =
               for(%Event{type: :harness_session, data: d} <- events, do: d)
    end

    test "a harness session id of 256 bytes is kept", %{core: core} do
      events = harness_turn(core, "id256")

      assert [%{harness_session_id: id}] =
               for(%Event{type: :harness_session, data: d} <- events, do: d)

      assert byte_size(id) == 256
      assert stop_reason(events) == :end_turn
    end

    test "a cut of 100 digits is kept", %{core: core} do
      events = harness_turn(core, "max_cut")
      cut = Integer.pow(10, 100) - 1

      assert [%{cut: ^cut}] = for(%Event{type: :harness_session, data: d} <- events, do: d)
      assert stop_reason(events) == :end_turn
    end

    test "an id of 257 bytes, 0 bytes, or not UTF-8, or a cut over the digit limit or below 0 fails the turn",
         %{core: core} do
      for model <- ["id257", "id0", "raw_id", "big_cut", "neg_cut"] do
        assert {:bad_stream_event, {:harness_session, _, _}} =
                 List.last(harness_turn(core, model)).data.error,
               model
      end
    end

    test "a harness tool result of at most 65,536 bytes is recorded as the provider sent it",
         %{core: core} do
      for bytes <- [65_535, 65_536] do
        events = harness_turn(core, "result_#{bytes}")

        assert [%{message: result}] =
                 for(%Event{type: :tool_execution_end, data: d} <- events, do: d)

        assert Helyx.Message.text(result) == String.duplicate("x", bytes)
        assert stop_reason(events) == :end_turn
      end
    end

    test "the size check runs before the UTF-8 repair, which can make the text larger",
         %{core: core} do
      events = harness_turn(core, "result_raw")

      assert [%{message: result}] =
               for(%Event{type: :tool_execution_end, data: d} <- events, do: d)

      assert Helyx.Message.text(result) == String.duplicate("�", 65_536)
      assert stop_reason(events) == :end_turn
    end

    test "a harness tool result over 65,536 bytes fails the turn with no text, and the session goes on",
         %{core: core} do
      for {model, bytes} <- [{"result_65537", 65_537}, {"result_multibyte", 65_537}] do
        {:ok, session} = Session.start(core, model: "harness/#{model}")
        {:ok, _} = Session.subscribe(session)
        :ok = Session.prompt(session, "hello")
        events = collect_until(:agent_end)

        assert List.last(events).data.error == {:tool_result_too_large, bytes, 65_536}
        assert stop_reason(events) == :error

        transcript = :sys.get_state(Session.pid(session)).transcript

        assert [:user, :assistant, :tool_result] = Enum.map(transcript, & &1.role)
        assert Helyx.Message.text(List.last(transcript)) == "aborted"

        :ok = Session.set_model(session, "harness/id1")
        :ok = Session.prompt(session, "again")
        assert stop_reason(collect_until(:agent_end)) == :end_turn
      end
    end

    test "a result goes to the first open call with its id", %{core: core} do
      events = harness_turn(core, "dup_id")
      ends = for %Event{type: :tool_execution_end, data: d} <- events, do: d.message

      assert [{"read", "one"}, {"bash", "two"}] =
               Enum.map(ends, &{&1.tool_name, Helyx.Message.text(&1)})
    end

    test "a call with no result at done gets its aborted result before the last message",
         %{core: core} do
      {:ok, session} = Session.start(core, model: "harness/open_call")
      {:ok, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      collect_until(:agent_end)

      transcript = :sys.get_state(Session.pid(session)).transcript

      assert [:user, :assistant, :tool_result, :tool_result, :assistant] =
               Enum.map(transcript, & &1.role)

      assert [{"read", "one"}, {"bash", "aborted"}] =
               for(m <- Enum.slice(transcript, 2, 2), do: {m.tool_name, Helyx.Message.text(m)})
    end

    test "a new message gives the open calls their aborted results, and a late result is dropped",
         %{core: core} do
      {:ok, session} = Session.start(core, model: "harness/late_result")
      {:ok, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      collect_until(:agent_end)
      transcript = :sys.get_state(Session.pid(session)).transcript

      assert [:user, :assistant, :tool_result, :assistant, :assistant] =
               Enum.map(transcript, & &1.role)

      assert Helyx.Message.text(Enum.at(transcript, 2)) == "aborted"
    end

    test "a result for a call of no completed message is dropped", %{core: core} do
      events = harness_turn(core, "orphan")
      refute Enum.any?(events, &(&1.type == :tool_execution_end))
      assert final_text(events) == "ok"
    end

    test "a result whose id is not valid UTF-8 is dropped like an unknown id", %{core: core} do
      events = harness_turn(core, "raw_result_id")
      refute Enum.any?(events, &(&1.type == :tool_execution_end))
      assert final_text(events) == "ok"
    end

    @tag :capture_log
    test "a crash reason with an integer over the digit limit is capped", %{core: core} do
      marker = "integer of more than #{Helyx.Message.max_integer_digits()} digits removed"

      assert {:task_exit, {:boom, ^marker}} =
               List.last(harness_turn(core, "exit_big")).data.error
    end

    test "a model provider that sends a harness event fails the turn", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/harness_event")
      {:ok, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")

      assert {:bad_stream_event, {:message_end, :end_turn, %{}}} =
               List.last(collect_until(:agent_end)).data.error
    end
  end

  test "a malformed stream event fails the turn and the session lives", %{core: core} do
    # The reason of `wide_int` holds the marker, not the 400,000 digits (#79).
    for {model, event} <- [
          garbage: {:text_delta, 42},
          wide: {:text_delta, "hello", :extra},
          wide_int: {:text_delta, "hello", "integer of more than 100 digits removed"}
        ] do
      {:ok, session} = Session.start(core, model: "test/#{model}")
      {:ok, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "hello")
      events = collect_until(:agent_end)
      assert List.last(events).data.error == {:bad_stream_event, event}

      :ok = Session.prompt(session, "again")
      assert stop_reason(collect_until(:agent_end)) == :error
    end
  end

  test "a prompt during a turn is rejected", %{core: core} do
    {:ok, session} = Session.start(core, model: gated_model())
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, stream}
    assert {:error, :turn_running} = Session.prompt(session, "again")
    send(stream, :go)
    assert stop_reason(collect_until(:agent_end)) == :end_turn
  end

  test "an error reason from a provider holds no integer over the digit limit", %{core: core} do
    for model <- ["error_int", "refuse_int"] do
      {:ok, session} = Session.start(core, model: "test/#{model}")
      {:ok, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "hello")
      error = List.last(collect_until(:agent_end)).data.error
      assert error == {:oops, "integer of more than 100 digits removed"}
    end
  end

  test "arguments or a usage that are a struct fail the turn and the session lives",
       %{core: core} do
    for model <- ["struct_usage", "struct_args"] do
      {:ok, session} = Session.start(core, model: "test/#{model}")
      {:ok, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "hello")
      events = collect_until(:agent_end)
      assert {:bad_stream_event, _} = List.last(events).data.error
      refute Enum.any?(events, &(:erlang.external_size(&1) > 10_000))

      :ok = Session.prompt(session, "again")
      assert stop_reason(collect_until(:agent_end)) == :error
    end
  end

  test "a done payload that is a struct with the large integer ends the turn", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/struct_done")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert final_text(events) == "hi"
    assert stop_reason(events) == :end_turn
    refute Enum.any?(events, &(:erlang.external_size(&1) > 10_000))

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :end_turn
  end

  test "the provider context goes through model context, then compaction" do
    core = :"core_#{System.unique_integer([:positive])}"
    plugins = [Helyx.Test.Provider, Helyx.Test.ModelContext, Helyx.Test.Compaction]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})

    {:ok, session} = Session.start(core, model: "test/system")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:agent_end)) == "built for #{File.cwd!()}, compacted"
  end

  test "without model context and compaction plugins the context is unchanged", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/system")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:agent_end)) == "no system"
  end

  test "the hands report the registered tools and the provider sees them", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/tools")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:agent_end)) == "binary,hold,kill,slow,upcase"
  end

  test "tool calls run on the hands and the loop continues until the provider stops", %{
    core: core
  } do
    {:ok, session} = Session.start(core, model: "test/loop")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert final_text(events) == "HI|unknown tool: nope"

    types = Enum.map(events, & &1.type)
    assert Enum.count(types, &(&1 == :turn_start)) == 1
    assert Enum.count(types, &(&1 == :turn_end)) == 1
    assert Enum.count(types, &(&1 == :tool_execution_start)) == 2
    assert Enum.count(types, &(&1 == :tool_execution_end)) == 2
    assert Enum.map(events, & &1.seq) == Enum.to_list(1..length(events))

    ends = for %{type: :tool_execution_end, data: data} <- events, do: data.message
    by_id = Map.new(ends, &{&1.tool_call_id, &1})
    assert %Helyx.Message{role: :tool_result, tool_name: "upcase", is_error: false} = by_id["c1"]
    assert %Helyx.Message{role: :tool_result, tool_name: "nope", is_error: true} = by_id["c2"]
    assert Helyx.Message.text(by_id["c1"]) == "HI"
  end

  test "a tool call with an integer over the digit limit gets an error result and never runs",
       %{core: core} do
    dir = Path.join(System.tmp_dir!(), "helyx_big_int_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, session} = Session.start(core, model: "test/big_int", sessions_dir: dir)
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    # One encode of the 400,000 digits takes seconds. collect_until/1 waits
    # at most 1 s for each event, so a slow encode fails the test.
    events = collect_until(:agent_end)

    rejected = "tool call not run: an integer in the arguments has more than 100 digits"
    # The fourth call has the id of the first call and good arguments: it runs.
    assert final_text(events) == "#{rejected}|TWO|THREE|FOUR|#{rejected}|#{rejected}"

    marker = "integer of more than 100 digits removed"
    assert %{input: ^marker, output: 3} = turn_end_usage(events)

    [first, _, third, _, fifth, sixth] =
      for %{type: :tool_execution_start, data: %{tool_call: call}} <- events, do: call

    assert first.arguments == %{
             "text" => "one",
             "n" => [%{"deep" => marker}]
           }

    assert third.arguments["n"] == 10 ** 100 - 1
    assert fifth.arguments == %{"text" => "five", marker => 1}
    assert sixth.arguments == %{"text" => "six", "d" => marker}

    [result | _] = for %{type: :tool_execution_end, data: %{message: m}} <- events, do: m
    assert %Helyx.Message{tool_call_id: "c1", is_error: true} = result

    # No event, and thus no later encode, holds the large integer.
    refute Enum.any?(events, &(:erlang.external_size(&1) > 10_000))
    [path] = Path.wildcard(Path.join(dir, "**/*.jsonl"))
    assert File.stat!(path).size < 10_000
    assert Enum.map(events, & &1.seq) == Enum.to_list(1..length(events))
  end

  test "a rejected call gets an error result with its reason; the text and the good call stay",
       %{core: core} do
    {:ok, session} = Session.start(core, model: "test/rejected")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

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
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert final_text(events) == "1|2|3"

    order =
      for %{type: t, data: d} <- events, t in [:tool_execution_start, :tool_execution_end] do
        case d do
          %{tool_call: call} -> {t, call.id}
          %{message: message} -> {t, message.tool_call_id}
        end
      end

    assert order == [
             {:tool_execution_start, "1"},
             {:tool_execution_end, "1"},
             {:tool_execution_start, "2"},
             {:tool_execution_end, "2"},
             {:tool_execution_start, "3"},
             {:tool_execution_end, "3"}
           ]
  end

  test "a tool call with a bad field shape is a malformed stream event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/bad_call")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

    assert {:bad_stream_event, {:tool_call, %Helyx.Message.ToolCall{name: %{}}}} =
             List.last(events).data.error
  end

  test "a notice goes out as an event and stays out of the assistant message", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/notice")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

    assert [%Event{turn_id: turn_id, data: %{text: "heads up"}}] =
             Enum.filter(events, &(&1.type == :notice))

    assert turn_id == hd(events).turn_id
    turn_end = Enum.find(events, &(&1.type == :turn_end))
    assert [%Helyx.Message.Text{text: "hi there"}] = turn_end.data.message.content
  end

  test "a stop reason outside the format's set is a malformed stream event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/bad_stop")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

    assert {:bad_stream_event, {:done, %{stop_reason: :refusal}}} =
             List.last(events).data.error
  end

  test "a tool call whose arguments the file cannot hold is a malformed stream event", %{
    core: core
  } do
    {:ok, session} = Session.start(core, model: "test/bad_args")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

    assert {:bad_stream_event, {:tool_call, _}} = List.last(events).data.error
  end

  @tag :tmp_dir
  test "a terminal the file cannot hold fails the turn and leaves persistence on", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/recover", sessions_dir: dir)
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

    assert {:bad_stream_event, {:done, %{usage: %{"in" => {1, 2}}}}} =
             List.last(events).data.error

    :ok = Session.prompt(session, "again")
    collect_until(:agent_end)

    {:ok, restored} = Helyx.Session.File.resume(dir, File.cwd!())
    assert "recovered" in Enum.map(restored.messages, &Helyx.Message.text/1)
  end

  test "a tool result with invalid bytes is made valid before it reaches the session", %{
    core: core
  } do
    {:ok, session} = Session.start(core, model: "test/binary")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert final_text(events) == "a�b"

    result = Enum.find(events, &(&1.type == :tool_execution_end)).data.message
    assert Helyx.Message.text(result) == "a�b"
    refute result.is_error

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :end_turn
  end

  test "a tool Task that dies gives an error result and the loop continues", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/kill")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :end_turn
    assert final_text(events) == "tool crashed: :killed"
  end

  test "two tools with one name are rejected at session start" do
    core = :"core_#{System.unique_integer([:positive])}"
    plugins = [Helyx.Test.Provider, Helyx.Test.Tool.Upcase, Helyx.Test.Tool.UpcaseTwin]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})

    assert {:error, {:duplicate_tool_name, "upcase"}} = Session.start(core, model: "test/ok")
  end

  test "abort during tool calls ends the turn and answers every open call", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start} = started}

    :ok = Session.abort(session)
    events = collect_until(:agent_end)
    assert stop_reason(events) == :aborted
    refute Enum.any?(events, &(&1.type == :turn_end))

    results = for %{type: :tool_execution_end, data: %{message: m}} <- events, do: m
    assert length(results) == 3
    assert Enum.all?(results, & &1.is_error)
    assert Enum.all?(results, &(Helyx.Message.text(&1) == "aborted"))

    # A late result for the aborted turn is dropped.
    [{pid, _}] = Registry.lookup(Helyx.Core.sessions_registry(core), session.id)
    send(pid, {:tool_result, started.turn_id, "1", {:ok, "late"}})

    :ok = Session.prompt(session, "again")
    events = collect_until(:agent_end)
    assert final_text(events) == "aborted|aborted|aborted"
    refute Enum.any?(events, &(inspect(&1.data) =~ "late"))
  end

  test "abort during the provider stream closes the partial message", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/hang")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :message_update}}

    :ok = Session.abort(session)
    events = collect_until(:agent_end)
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
    {:ok, _} = Session.subscribe(session)

    assert :ok = Session.abort(session)
    refute_received {:helyx_event, _}
  end

  # Each abort shuts down a provider Task. The session keeps no record of
  # it, and its exit signal does not stay in the mailbox (#261).
  test "many aborts in a row leave no growing state", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/hang")
    {:ok, _} = Session.subscribe(session)
    pid = Session.pid(session)

    abort = fn ->
      :ok = Session.prompt(session, "hello")
      assert_receive {:helyx_event, %Event{type: :message_update}}, 1_000
      :ok = Session.abort(session)
      assert stop_reason(collect_until(:agent_end)) == :aborted
      state = :sys.get_state(pid)
      assert Process.info(pid, :message_queue_len) == {:message_queue_len, 0}
      :erts_debug.flat_size(%{state | transcript: [], seq: 0})
    end

    size = abort.()
    for _ <- 1..20, do: assert(abort.() == size)
  end

  # A crash of a linked process that is not a provider Task, the sessions
  # Registry for example, must take the session with it: a session that
  # outlives its registration keeps working where no client can reach it.
  @tag :capture_log
  test "an exit that is not from a provider Task stops the session", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    pid = Session.pid(session)
    ref = Process.monitor(pid)

    Process.exit(pid, {:shutdown, :registry_gone})
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :registry_gone}}
  end

  # The ownership chain (ADR 0004): work inside the VM is linked to its
  # owner, so a killed session takes the provider Task, the hands, and the
  # tool Tasks with it, even through an untrappable kill.
  @tag :capture_log
  test "killing the session kills the provider Task", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/hang")
    {:ok, _} = Session.subscribe(session)
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
    {:ok, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}

    pid = Session.pid(session)
    hands = :sys.get_state(pid).hands
    # `Hands.run/3` is a cast: the hands start the Task before they answer.
    :sys.get_state(hands)

    [task] =
      for task <- Task.Supervisor.children(Helyx.Core.task_supervisor(core)),
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

  defp user_texts(events) do
    for %{type: :message_end, data: %{message: %Helyx.Message{role: :user} = m}} <- events,
        do: Helyx.Message.text(m)
  end

  defp queue_counts(events) do
    for %{type: :queue_update, data: data} <- events, do: data
  end

  test "steers during a tool run reach the next provider call after the result, in order", %{
    core: core
  } do
    {:ok, session} = Session.start(core, model: "test/steer")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}
    :ok = Session.steer(session, "s1")
    :ok = Session.steer(session, "s2")

    events = collect_until(:agent_end)
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

    assert queue_counts(events) == [
             %{steers: 1, follow_ups: 0},
             %{steers: 2, follow_ups: 0},
             %{steers: 0, follow_ups: 0}
           ]
  end

  test "a follow-up during a turn starts a new turn after agent_end", %{core: core} do
    {:ok, session} = Session.start(core, model: gated_model())
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, stream}
    :ok = Session.follow_up(session, "next")
    send(stream, :go)

    first = collect_until(:agent_end)
    assert user_texts(first) == ["hello"]
    assert queue_counts(first) == [%{steers: 0, follow_ups: 1}]

    assert_receive {:waiting, stream}
    send(stream, :go)
    second = collect_until(:agent_end)
    assert [:queue_update, :agent_start | _] = Enum.map(second, & &1.type)
    assert List.first(second).turn_id == nil
    assert user_texts(second) == ["next"]
    assert queue_counts(second) == [%{steers: 0, follow_ups: 0}]
  end

  test "a steer left at turn end starts a new turn", %{core: core} do
    {:ok, session} = Session.start(core, model: gated_model())
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, stream}
    :ok = Session.steer(session, "later")
    send(stream, :go)

    collect_until(:agent_end)
    assert_receive {:waiting, stream}
    send(stream, :go)
    second = collect_until(:agent_end)
    assert user_texts(second) == ["later"]
  end

  test "a steer or follow-up with no turn running starts a turn at once", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.follow_up(session, "go")
    events = collect_until(:agent_end)
    assert user_texts(events) == ["go"]
    assert stop_reason(events) == :end_turn

    :ok = Session.steer(session, "again")
    events = collect_until(:agent_end)
    assert user_texts(events) == ["again"]
  end

  test "abort drops queued steers and follow-ups", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}
    :ok = Session.steer(session, "s")
    :ok = Session.follow_up(session, "f")

    assert_receive {:helyx_event, %Event{type: :queue_update, data: %{steers: 1, follow_ups: 1}}}

    :ok = Session.abort(session)
    events = collect_until(:agent_end)
    assert stop_reason(events) == :aborted
    assert List.last(queue_counts(events)) == %{steers: 0, follow_ups: 0}

    refute_receive {:helyx_event, %Event{type: :agent_start}}, 100
  end

  test "a full queue rejects the next steer or follow-up", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}

    # One under the limit, then at the limit, with multibyte text.
    for n <- 1..31, do: :ok = Session.steer(session, "stér #{n}")
    :ok = Session.steer(session, "stér 32 🚀")
    for n <- 1..32, do: :ok = Session.follow_up(session, "折り返し #{n}")

    # 64 accepted writes, one queue_update each.
    counts =
      for _ <- 1..64 do
        assert_receive {:helyx_event, %Event{type: :queue_update, data: data}}
        data
      end

    assert Enum.at(counts, 30) == %{steers: 31, follow_ups: 0}
    assert List.last(counts) == %{steers: 32, follow_ups: 32}

    # One over the limit is rejected, changes nothing, and emits no event.
    assert Session.steer(session, "s33") == {:error, :queue_full}
    assert Session.follow_up(session, "f33") == {:error, :queue_full}
    refute_received {:helyx_event, %Event{type: :queue_update}}

    :ok = Session.abort(session)
  end

  @tag :tmp_dir
  test "a session with a sessions dir writes a header and completed messages", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/blocks", sessions_dir: dir)
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    collect_until(:agent_end)

    [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
    entries = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert [
             %{"type" => "session", "version" => 1, "model" => "test/blocks"},
             %{"type" => "message", "role" => "user"},
             %{"type" => "message", "role" => "assistant", "stop_reason" => "end_turn"},
             %{"type" => "message", "role" => "tool_result", "tool_call_id" => "call_1"},
             %{"type" => "message", "role" => "assistant"}
           ] = entries

    assert Enum.at(entries, 0)["cwd"] == File.cwd!()

    assert [%{"type" => "thinking"}, %{"type" => "text"}, %{"type" => "tool_call"}] =
             Enum.at(entries, 2)["content"]

    ids = Enum.map(entries, & &1["id"])
    assert Enum.map(entries, & &1["parent_id"]) == [nil | Enum.drop(ids, -1)]
  end

  @tag :tmp_dir
  test "resume restores the transcript and the next provider call sees it", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/transcript", sessions_dir: dir)
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:agent_end)) == "user:hello"

    stop_session(session, &GenServer.stop/1)

    {:ok, resumed} = Session.resume(core, sessions_dir: dir)
    assert resumed.id == session.id
    {:ok, _} = Session.subscribe(resumed)

    :ok = Session.prompt(resumed, "again")

    assert final_text(collect_until(:agent_end)) ==
             "user:hello\nassistant:user:hello\nuser:again"
  end

  describe "the session supervisor after a resume (#103)" do
    # The start message of a resume holds the whole transcript. The supervisor
    # hibernates after each message, which collects that copy. Short texts stay
    # on the heap; this transcript is about 7 MB there, and the margin is 1 MB.
    @describetag :tmp_dir

    setup %{core: core, tmp_dir: dir} do
      {:ok, file} = Helyx.Session.File.create(dir, "big", File.cwd!(), "test/transcript")

      Enum.reduce(1..20_000, file, fn i, file ->
        Helyx.Session.File.append_message(file, Helyx.Message.user("m#{i}"))
      end)

      sup = Process.whereis(Helyx.Core.session_supervisor(core))
      {:memory, before} = Process.info(sup, :memory)
      %{sup: sup, limit: before + 1_000_000}
    end

    test "keeps no copy after a start and after a failed start", %{
      core: core,
      tmp_dir: dir,
      sup: sup,
      limit: limit
    } do
      {:ok, _session} = Session.resume(core, sessions_dir: dir)
      await(fn -> memory(sup) < limit end, "supervisor memory under #{limit}")

      assert {:error, {:already_started, _}} = Session.resume(core, sessions_dir: dir)
      await(fn -> memory(sup) < limit end, "supervisor memory under #{limit}")
    end

    test "keeps no copy when the caller dies during the start", %{
      core: core,
      tmp_dir: dir,
      sup: sup,
      limit: limit
    } do
      # The start message waits in the mailbox of the suspended supervisor
      # while the caller dies.
      :erlang.suspend_process(sup)
      {caller, ref} = spawn_monitor(fn -> Session.resume(core, sessions_dir: dir) end)

      await(
        fn -> Process.info(sup, :message_queue_len) != {:message_queue_len, 0} end,
        "the start message in the supervisor mailbox"
      )

      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, _, _, :killed}
      :erlang.resume_process(sup)

      await(fn -> memory(sup) < limit end, "supervisor memory under #{limit}")
    end
  end

  defp memory(pid), do: pid |> Process.info(:memory) |> elem(1)

  @tag :tmp_dir
  test "resume keeps a reused tool call id open until its own result", %{
    core: core,
    tmp_dir: dir
  } do
    call = %Helyx.Message.ToolCall{id: "c1", name: "slow", arguments: %{}}
    {:ok, file} = Helyx.Session.File.create(dir, "reuse", File.cwd!(), "test/transcript")

    [
      %Helyx.Message{role: :assistant, stop_reason: :tool_use, content: [call]},
      Helyx.Message.tool_result(call, {:ok, "first answer"}),
      %Helyx.Message{role: :assistant, stop_reason: :tool_use, content: [call]}
    ]
    |> Enum.reduce(file, &Helyx.Session.File.append_message(&2, &1))

    {:ok, _session} = Session.resume(core, sessions_dir: dir)

    {:ok, restored} = Helyx.Session.File.resume(dir, File.cwd!())
    assert [_call1, _result1, _call2, aborted] = restored.messages
    assert %Helyx.Message{role: :tool_result, tool_call_id: "c1", is_error: true} = aborted
    assert Helyx.Message.text(aborted) == "aborted"
  end

  @tag :tmp_dir
  @tag :capture_log
  test "resume after a crash mid-turn answers every open tool call", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/abort", sessions_dir: dir)
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}

    stop_session(session, &Process.exit(&1, :kill))

    {:ok, resumed} = Session.resume(core, sessions_dir: dir)
    {:ok, _} = Session.subscribe(resumed)

    :ok = Session.prompt(resumed, "again")
    assert final_text(collect_until(:agent_end)) == "aborted|aborted|aborted"
  end

  test "a delta that is not valid UTF-8 is a malformed stream event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/raw_bytes")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert {:bad_stream_event, {:text_delta, <<"hi", 255>>}} = List.last(events).data.error
  end

  test "a tool call that is not valid UTF-8 is a malformed stream event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/raw_call")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert {:bad_stream_event, {:tool_call, _}} = List.last(events).data.error
  end

  test "a prompt that is not valid UTF-8 is rejected and the session lives", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _} = Session.subscribe(session)

    assert {:error, :invalid_utf8} = Session.prompt(session, <<255, 254>>)

    :ok = Session.prompt(session, "hello")
    assert stop_reason(collect_until(:agent_end)) == :end_turn
  end

  @tag :tmp_dir
  @tag :capture_log
  test "a write failure turns persistence off and the session lives", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _} = Session.subscribe(session)

    File.rm_rf!(dir)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :end_turn
    assert [%{text: "the session file could not be written" <> _}] = notices(events)

    # The notice goes out once: persistence stays off.
    :ok = Session.prompt(session, "again")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :end_turn
    assert notices(events) == []
  end

  defp notices(events), do: for(%Event{type: :notice, data: data} <- events, do: data)

  describe "tool specs at the session boundary (#142)" do
    # One bad test tool per rule of `Helyx.Tool.specs/1`, and one per
    # failure class of a spec callback (raise, throw, exit), with the label
    # the error gives. Each row holds the quoted callback bodies.
    @empty Macro.escape(%{})
    @bad_specs [
      {Helyx.SessionTest.EmptyName, "", "d", @empty, "Helyx.SessionTest.EmptyName"},
      {Helyx.SessionTest.AtomName, :bad, "d", @empty, "Helyx.SessionTest.AtomName"},
      {Helyx.SessionTest.BytesName, <<"b", 255>>, "d", @empty, "Helyx.SessionTest.BytesName"},
      {Helyx.SessionTest.NilDesc, "t", nil, @empty, "t"},
      {Helyx.SessionTest.BytesDesc, "t", <<"d", 255>>, @empty, "t"},
      {Helyx.SessionTest.ListParams, "t", "d", [], "t"},
      {Helyx.SessionTest.AtomKeys, "t", "d", Macro.escape(%{type: "object"}), "t"},
      {Helyx.SessionTest.TupleParams, "t", "d", Macro.escape(%{"type" => {:object}}), "t"},
      {Helyx.SessionTest.BytesParams, "t", "d", Macro.escape(%{"type" => <<255>>}), "t"},
      {Helyx.SessionTest.ThrowingEncoder, "t", "d",
       Macro.escape(%{"type" => %Helyx.Test.FailingJSON{kind: :throw}}),
       "Helyx.SessionTest.ThrowingEncoder"},
      {Helyx.SessionTest.ExitingEncoder, "t", "d",
       Macro.escape(%{"type" => %Helyx.Test.FailingJSON{kind: :exit}}),
       "Helyx.SessionTest.ExitingEncoder"},
      {Helyx.SessionTest.RaisingName, quote(do: raise("boom")), "d", @empty,
       "Helyx.SessionTest.RaisingName"},
      {Helyx.SessionTest.ThrowingDescription, "t", quote(do: throw(:boom)), @empty,
       "Helyx.SessionTest.ThrowingDescription"},
      {Helyx.SessionTest.ExitingParameters, "t", "d", quote(do: exit(:boom)),
       "Helyx.SessionTest.ExitingParameters"}
    ]

    for {module, name, description, parameters, _label} <- @bad_specs do
      defmodule module do
        @moduledoc false
        @behaviour Helyx.Tool

        @impl true
        def name, do: unquote(name)
        @impl true
        def description, do: unquote(description)
        @impl true
        def parameters, do: unquote(parameters)
        @impl true
        def run(_args, _cwd), do: {:ok, ""}
      end
    end

    defmodule Counted do
      @moduledoc false
      # Each spec callback tells the test process that it ran.
      @behaviour Helyx.Tool

      defp ran(callback) do
        send(:persistent_term.get({__MODULE__, :observer}), {:spec_callback, callback})
      end

      @impl true
      def name, do: tap("counted", fn _ -> ran(:name) end)
      @impl true
      def description, do: tap("Counts.", fn _ -> ran(:description) end)
      @impl true
      def parameters, do: tap(%{"type" => "object"}, fn _ -> ran(:parameters) end)
      @impl true
      def run(_args, _cwd), do: {:ok, ""}
    end

    defp start_core(plugins) do
      core = :"core_#{System.unique_integer([:positive])}"
      start_supervised!({Helyx.Core, name: core, plugins: plugins}, id: core)
      core
    end

    @tag :tmp_dir
    test "start rejects each bad or failing spec, names the tool, and makes nothing", %{
      tmp_dir: dir
    } do
      for {module, _name, _description, _parameters, label} <- @bad_specs do
        core = start_core([Helyx.Test.Provider, Helyx.Test.Tool.Upcase, module])

        assert {:error, {:bad_tool_spec, ^label}} =
                 Session.start(core, model: "test/ok", sessions_dir: dir)

        assert DynamicSupervisor.count_children(Helyx.Core.session_supervisor(core)).active == 0
      end

      assert File.ls!(dir) == []
    end

    @tag :tmp_dir
    test "resume rejects a bad or failing spec before it reads or repairs the file",
         %{core: core, tmp_dir: dir} do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      GenServer.stop(Session.pid(session))

      # A torn last line, which a resume would repair.
      File.write!(path, ~s({"type":"mess), [:append])
      before = File.read!(path)

      for {module, _name, _description, _parameters, label} <- @bad_specs do
        bad = start_core([Helyx.Test.Provider, module])
        assert {:error, {:bad_tool_spec, ^label}} = Session.resume(bad, sessions_dir: dir)
        assert DynamicSupervisor.count_children(Helyx.Core.session_supervisor(bad)).active == 0
      end

      assert File.read!(path) == before
    end

    test "the spec callbacks run once per session, not per provider call" do
      :persistent_term.put({Counted, :observer}, self())
      on_exit(fn -> :persistent_term.erase({Counted, :observer}) end)
      core = start_core([Helyx.Test.Provider, Counted])
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)

      for text <- ["one", "two"] do
        :ok = Session.prompt(session, text)
        assert stop_reason(collect_until(:agent_end)) == :end_turn
      end

      for callback <- [:name, :description, :parameters],
          do: assert_received({:spec_callback, ^callback})

      refute_received {:spec_callback, _}
    end
  end

  describe "tool checks at the session boundary (#150)" do
    # One test tool per failing `check/0`: the quoted body, and the reason
    # the error gives.
    @bad_checks [
      {Helyx.SessionTest.CheckRaises, quote(do: raise("boom")),
       "check/0 raised, threw, or exited"},
      {Helyx.SessionTest.CheckThrows, quote(do: throw(:boom)),
       "check/0 raised, threw, or exited"},
      {Helyx.SessionTest.CheckExits, quote(do: exit(:boom)), "check/0 raised, threw, or exited"},
      {Helyx.SessionTest.CheckBadValue, :yes, "check/0 returned a bad value"},
      {Helyx.SessionTest.CheckAtomReason, {:error, :enoent}, "check/0 returned a bad value"},
      {Helyx.SessionTest.CheckBytesReason, {:error, <<"x", 255>>}, "check/0 returned a bad value"}
    ]

    for {module, body, _reason} <- @bad_checks do
      defmodule module do
        @moduledoc false
        @behaviour Helyx.Tool

        @impl true
        def name, do: "checked"
        @impl true
        def description, do: "d"
        @impl true
        def parameters, do: %{}
        @impl true
        def run(_args, _cwd), do: {:ok, ""}
        @impl true
        def check, do: unquote(body)
      end
    end

    @cases [
      {Helyx.Test.Tool.Unavailable, "unavailable", "the frob is missing"}
      | for({module, _body, reason} <- @bad_checks, do: {module, "checked", reason})
    ]

    @tag :tmp_dir
    test "start rejects a failed check, names the tool, and makes nothing", %{tmp_dir: dir} do
      for {module, name, reason} <- @cases do
        core = start_core([Helyx.Test.Provider, Helyx.Test.Tool.Upcase, module])

        assert {:error, {:tool_unavailable, ^name, ^reason}} =
                 Session.start(core, model: "test/ok", sessions_dir: dir)

        assert DynamicSupervisor.count_children(Helyx.Core.session_supervisor(core)).active == 0
      end

      assert File.ls!(dir) == []
    end

    test "the check runs before the model ref resolves" do
      core = start_core([Helyx.Test.Provider, Helyx.Test.Tool.Unavailable])

      assert {:error, {:tool_unavailable, "unavailable", _reason}} =
               Session.start(core, model: "nope/x")
    end

    @tag :tmp_dir
    test "resume rejects a failed check before it reads or repairs the file",
         %{core: core, tmp_dir: dir} do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      GenServer.stop(Session.pid(session))

      # A torn last line, which a resume would repair.
      File.write!(path, ~s({"type":"mess), [:append])
      before = File.read!(path)

      for {module, name, reason} <- @cases do
        bad = start_core([Helyx.Test.Provider, module])

        assert {:error, {:tool_unavailable, ^name, ^reason}} =
                 Session.resume(bad, sessions_dir: dir)

        assert DynamicSupervisor.count_children(Helyx.Core.session_supervisor(bad)).active == 0
      end

      assert File.read!(path) == before
    end
  end

  describe "cwd at the session boundary (#140)" do
    @bad_cwds [:repo, ~c"/repo", <<"/repo", 255>>, "/re\0po"]

    @tag :tmp_dir
    test "start rejects a cwd that is not a UTF-8 string without a NUL byte, and makes nothing",
         %{core: core, tmp_dir: dir} do
      for cwd <- @bad_cwds do
        assert {:error, :invalid_cwd} =
                 Session.start(core, model: "test/ok", cwd: cwd, sessions_dir: dir)
      end

      assert File.ls!(dir) == []
      assert DynamicSupervisor.count_children(Helyx.Core.session_supervisor(core)).active == 0
    end

    @tag :tmp_dir
    test "resume rejects the same cwds before it reads the sessions dir",
         %{core: core, tmp_dir: dir} do
      for cwd <- @bad_cwds do
        assert {:error, :invalid_cwd} = Session.resume(core, cwd: cwd, sessions_dir: dir)
      end

      assert File.ls!(dir) == []
      assert DynamicSupervisor.count_children(Helyx.Core.session_supervisor(core)).active == 0
    end
  end

  @tag :tmp_dir
  test "a working directory that is gone gives an error result", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/loop", cwd: Path.join(dir, "gone"))
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert final_text(events) =~ "working directory does not exist"
  end

  describe "set_model/2" do
    test "the next turn uses the new provider, and a switch back works", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "one")
      first = collect_until(:agent_end)
      assert final_text(first) == "ok"

      assert :ok = Session.set_model(session, "other/any")
      assert_receive {:helyx_event, %Event{type: :model_change} = change}
      assert change.data == %{model: "other/any"}
      assert change.turn_id == nil
      assert change.seq == List.last(first).seq + 1
      refute_received {:helyx_event, _}
      assert GenServer.call(Session.pid(session), {:snapshot}).model == "other/any"

      :ok = Session.prompt(session, "two")
      second = collect_until(:agent_end)
      assert final_text(second) == "from other"
      assert Enum.find(second, &(&1.type == :turn_end)).data.message.model == "other/any"
      assert hd(second).seq == change.seq + 1

      assert :ok = Session.set_model(session, "test/ok")
      assert_receive {:helyx_event, %Event{type: :model_change}}
      :ok = Session.prompt(session, "three")
      assert final_text(collect_until(:agent_end)) == "ok"
    end

    @tag :tmp_dir
    test "a rejected ref leaves the model, the file, and the event stream unchanged", %{
      core: core,
      tmp_dir: dir
    } do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      {:ok, _} = Session.subscribe(session)
      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      before = File.read!(path)

      assert {:error, {:unknown_provider, "nope"}} = Session.set_model(session, "nope/model")
      assert {:error, {:invalid_model_ref, "test"}} = Session.set_model(session, "test")
      assert {:error, {:invalid_model_ref, _}} = Session.set_model(session, <<"test/", 255>>)

      assert GenServer.call(Session.pid(session), {:snapshot}).model == "test/ok"
      assert File.read!(path) == before
      refute_received {:helyx_event, _}
    end

    @tag :tmp_dir
    test "the switch is a model change entry and survives resume", %{core: core, tmp_dir: dir} do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      :ok = Session.set_model(session, "other/any")

      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))

      entries =
        path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      assert [%{"type" => "session", "id" => id}, %{"type" => "model_change"} = entry] = entries
      assert %{"model" => "other/any", "parent_id" => ^id} = entry

      stop_session(session, &GenServer.stop/1)

      {:ok, resumed} = Session.resume(core, sessions_dir: dir)
      assert GenServer.call(Session.pid(resumed), {:snapshot}).model == "other/any"
      {:ok, _} = Session.subscribe(resumed)
      :ok = Session.prompt(resumed, "hello")
      assert final_text(collect_until(:agent_end)) == "from other"
    end

    test "a switch during a turn takes effect on the next turn", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/steer")
      {:ok, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "hello")
      assert_receive {:helyx_event, %Event{type: :tool_execution_start}}
      :ok = Session.set_model(session, "other/any")
      :ok = Session.follow_up(session, "again")
      assert_receive {:helyx_event, %Event{type: :model_change, turn_id: nil}}

      # The running turn makes its second provider call on the old model.
      running = collect_until(:agent_end)
      assert final_text(running) == "hello"
      assert Enum.find(running, &(&1.type == :turn_end)).data.message.model == "test/steer"
      assert final_text(collect_until(:agent_end)) == "from other"
    end

    @tag :tmp_dir
    test "a switch to the current model is accepted and recorded like any other", %{
      core: core,
      tmp_dir: dir
    } do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      {:ok, _} = Session.subscribe(session)

      assert :ok = Session.set_model(session, "test/ok")
      assert_receive {:helyx_event, %Event{type: :model_change, data: %{model: "test/ok"}}}
      refute_received {:helyx_event, _}

      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert [_header, change] = Enum.map(lines, &JSON.decode!/1)
      assert %{"type" => "model_change", "model" => "test/ok"} = change
    end

    test "a ref outside the bounds is rejected at start too", %{core: core} do
      long = "test/" <> String.duplicate("m", 252)
      assert {:error, {:invalid_model_ref, ^long}} = Session.start(core, model: long)
      assert {:error, {:invalid_model_ref, "test/a b"}} = Session.start(core, model: "test/a b")
    end

    @tag :tmp_dir
    test "a model change entry for the largest ref stays under the stated size", %{
      core: core,
      tmp_dir: dir
    } do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      # 256 bytes, every model byte doubled by the JSON encoding.
      :ok = Session.set_model(session, "test/" <> String.duplicate("\"", 251))

      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      [_header, change] = path |> File.read!() |> String.split("\n", trim: true)
      assert byte_size(change) <= 660
    end

    @tag :tmp_dir
    test "a switch still works when the file cannot be written", %{core: core, tmp_dir: dir} do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      {:ok, _} = Session.subscribe(session)
      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      header = File.read!(path)
      File.rm!(path)
      File.mkdir!(path)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Session.set_model(session, "other/any")
        end)

      assert log =~ "persistence off"
      assert_receive {:helyx_event, %Event{type: :notice, turn_id: nil}}
      assert_receive {:helyx_event, %Event{type: :model_change, turn_id: nil}}
      assert GenServer.call(Session.pid(session), {:snapshot}).model == "other/any"

      # Persistence stays off: with the file back, a turn writes nothing.
      File.rmdir!(path)
      File.write!(path, header)
      :ok = Session.prompt(session, "hello")
      assert final_text(collect_until(:agent_end)) == "from other"
      assert File.read!(path) == header
    end
  end

  describe "client calls during a sweep of the hands (issue #93)" do
    # The "stuck" turn holds a handle whose release takes `@slow_ms` and one
    # that stays held, so each sweep takes its full time and ends
    # unconfirmed. The client calls must answer in far less: `@load_ms` is
    # room for scheduler load, far above the delays that load makes, far
    # below the sweep.
    @slow_ms 800
    @load_ms 400

    # Starts a turn whose tool call holds a handle that no release confirms.
    defp start_stuck_turn(core) do
      {:ok, session} = Session.start(core, model: "test/stuck")
      {:ok, _} = Session.subscribe(session)
      hands = :sys.get_state(Session.pid(session)).hands
      :erlang.trace(hands, true, [:receive])

      :ok = Session.prompt(session, "go")
      assert_receive {:helyx_event, %Event{type: :tool_execution_start}}
      {session, hands, await_tool_task(hands)}
    end

    # The pid of the tool Task, once the hands handled its two hold calls.
    defp await_tool_task(hands) do
      assert_receive {:trace, ^hands, :receive, {:"$gen_call", {task, _}, {:hold, _}}}
      assert_receive {:trace, ^hands, :receive, {:"$gen_call", {^task, _}, {:hold, _}}}
      :erlang.trace(hands, false, [:receive])
      :sys.get_state(hands)
      task
    end

    # Runs the call and returns its result, or the exit, with the time in ms.
    defp timed(fun) do
      start = System.monotonic_time(:millisecond)

      result =
        try do
          fun.()
        catch
          :exit, {reason, _call} -> {:exit, reason}
        end

      {result, System.monotonic_time(:millisecond) - start}
    end

    # Makes every client call but abort, and returns the results. No call
    # exits, and all of them together take less than `@load_ms`.
    defp timed_calls(session) do
      calls = [
        set_model: fn -> Session.set_model(session, "test/stuck") end,
        steer: fn -> Session.steer(session, "steer") end,
        follow_up: fn -> Session.follow_up(session, "follow") end,
        prompt: fn -> Session.prompt(session, "prompt") end
      ]

      timed = for {name, fun} <- calls, do: {name, timed(fun)}
      total = Enum.sum(for {_name, {_result, ms}} <- timed, do: ms)
      assert total < @load_ms, "the calls waited for the sweep: #{inspect(timed)}"
      for {name, {result, _ms}} <- timed, do: {name, result}
    end

    @tag :capture_log
    test "every client call answers during the sweep of an abort", %{core: core} do
      {session, _hands, _task} = start_stuck_turn(core)

      abort = Task.async(fn -> timed(fn -> Session.abort(session) end) end)
      # The events of the abort go out at the start of the sweep.
      assert stop_reason(collect_until(:agent_end)) == :aborted

      results = timed_calls(session)
      assert results[:steer] == :ok
      assert results[:follow_up] == :ok
      assert results[:prompt] == :ok

      # The abort waits for the sweep, and no turn starts during it: the
      # hands cannot take a tool call.
      assert {:ok, abort_ms} = Task.await(abort, 10_000)
      assert abort_ms >= @slow_ms

      # The messages sent during the sweep start one turn after it, steers
      # first.
      events = collect_until(:agent_end)
      assert user_texts(events) == ["steer", "follow", "prompt"]
      assert stop_reason(events) == :end_turn
    end

    @tag :capture_log
    test "an abort whose cleanup fails gives a notice and still replies :ok", %{core: core} do
      {session, _hands, _task} = start_stuck_turn(core)

      assert :ok = Session.abort(session)
      assert stop_reason(collect_until(:agent_end)) == :aborted

      assert_receive {:helyx_event,
                      %Event{
                        type: :notice,
                        turn_id: nil,
                        data: %{text: "abort cleanup failed" <> _}
                      }},
                     1_000
    end

    @tag :capture_log
    test "a second abort during the sweep drops the messages sent before it", %{core: core} do
      {session, _hands, _task} = start_stuck_turn(core)

      abort = Task.async(fn -> Session.abort(session) end)
      assert queue_counts(collect_until(:agent_end)) == []
      :ok = Session.prompt(session, "dropped")

      assert_receive {:helyx_event,
                      %Event{type: :queue_update, data: %{steers: 0, follow_ups: 1}}}

      assert :ok = Session.abort(session)
      assert :ok = Task.await(abort, 1_000)

      assert_receive {:helyx_event,
                      %Event{type: :queue_update, data: %{steers: 0, follow_ups: 0}}}

      refute_receive {:helyx_event, %Event{type: :queue_update}}, 100
      refute_receive {:helyx_event, %Event{type: :agent_start}}, 100
    end

    @tag :capture_log
    test "every client call answers during the sweep of a delivered call", %{core: core} do
      {session, _hands, task} = start_stuck_turn(core)

      # The Task dies, and the hands release its handles before the result.
      Process.exit(task, :kill)
      results = timed_calls(session)
      assert results[:prompt] == {:error, :turn_running}

      events = collect_until(:agent_end)
      assert [result] = for(%{type: :tool_execution_end, data: %{message: m}} <- events, do: m)
      assert Helyx.Message.text(result) =~ "could not be released"
    end

    @tag :capture_log
    test "hands that die during the sweep stop the session and the abort call", %{core: core} do
      {session, hands, _task} = start_stuck_turn(core)
      ref = Process.monitor(Session.pid(session))

      abort = Task.async(fn -> timed(fn -> Session.abort(session) end) end)
      collect_until(:agent_end)
      Process.exit(hands, :kill)

      assert_receive {:DOWN, ^ref, :process, _pid, :killed}
      assert {{:error, :session_not_found}, _ms} = Task.await(abort, 1_000)
    end
  end

  describe "a session that is not running (#188)" do
    defp operations do
      [
        subscribe: &Session.subscribe/1,
        prompt: &Session.prompt(&1, "hi"),
        steer: &Session.steer(&1, "hi"),
        follow_up: &Session.follow_up(&1, "hi"),
        abort: &Session.abort/1,
        set_model: &Session.set_model(&1, "test/ok")
      ]
    end

    defp assert_not_found(session, core) do
      for {name, op} <- operations() do
        assert {name, {:error, :session_not_found}} == {name, op.(session)}
      end

      assert Registry.keys(Helyx.Core.events_registry(core), self()) == []
    end

    test "every operation on an id that never existed", %{core: core} do
      assert_not_found(%Session{id: "never", core: core}, core)
    end

    test "every operation on a session that ended", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      stop_session(session, &GenServer.stop/1)
      assert_not_found(session, core)
    end

    @tag :capture_log
    test "every operation on a dead session that is still registered", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      pid = Session.pid(session)
      # Holding the Registry keeps the dead name in its table.
      registry = Helyx.Core.sessions_registry(core)
      partitions = for {_, p, _, _} <- Supervisor.which_children(registry), do: p
      Enum.each(partitions, &:sys.suspend/1)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert_not_found(session, core)
      Enum.each(partitions, &:sys.resume/1)
    end

    @tag :capture_log
    test "a session that ends during the snapshot call", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      pid = Session.pid(session)
      :ok = :sys.suspend(pid)

      # The call is in the mailbox of the suspended session: the caller has
      # registered and waits for the snapshot. The session dies there.
      spawn(fn ->
        await(
          fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 1} end,
          "the call"
        )

        Process.exit(pid, :kill)
      end)

      assert Session.subscribe(session) == {:error, :session_not_found}
      # The session ended, so the entry of the first subscribe goes too.
      assert Registry.keys(Helyx.Core.events_registry(core), self()) == []
    end

    # A reconnect subscribes again from the same process. The session then
    # sends the events of a turn and stops while the snapshot call waits.
    @tag :capture_log
    test "a second subscribe keeps one entry, and a failed one removes it", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      {:ok, _} = Session.subscribe(session)
      registry = Helyx.Core.events_registry(core)
      assert [watch] = Registry.values(registry, session.id, self())
      assert is_pid(watch)

      pid = Session.pid(session)
      queued = fn n -> Process.info(pid, :message_queue_len) == {:message_queue_len, n} end
      test = self()

      # Only the process that suspends the session can resume it. The
      # mailbox: the prompt, the stop, then the snapshot call.
      spawn(fn ->
        true = :erlang.suspend_process(pid)
        send(test, :suspended)
        await(fn -> queued.(3) end, "the snapshot call")
        true = :erlang.resume_process(pid)
      end)

      assert_receive :suspended
      Task.start(fn -> Session.prompt(session, "hi") end)
      await(fn -> queued.(1) end, "the prompt")
      Task.start(fn -> GenServer.stop(pid) end)
      await(fn -> queued.(2) end, "the stop")

      assert Session.subscribe(session) == {:error, :session_not_found}
      assert Registry.values(registry, session.id, self()) == []

      # The accepted hole: the events sent before the stop stay, each once.
      seqs =
        for {:helyx_event, %Event{seq: seq}} <- mailbox(),
            do: seq

      assert seqs != []
      assert seqs == Enum.uniq(seqs)
    end

    test "every operation after the Core stopped", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      :ok = Supervisor.stop(core)

      for {name, op} <- operations() do
        assert {name, {:error, :session_not_found}} == {name, op.(session)}
      end
    end

    # When a Core stops, the events Registry stops its partitions before it
    # stops itself. For a moment it has no partition, and a register raises
    # `ErlangError`.
    test "a subscribe while the Core stops", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      stop_session(session, &GenServer.stop/1)
      registry = Helyx.Core.events_registry(core)

      for {id, _, _, _} <- Supervisor.which_children(registry),
          do: :ok = Supervisor.terminate_child(registry, id)

      assert Session.subscribe(session) == {:error, :session_not_found}
    end

    # A session can stop with the reason `:timeout`, and the call then exits
    # like a call that timed out. The session traps exits, so the exit signal
    # is a message before the call, and the session stops on it before it
    # answers.
    @tag :capture_log
    test "a session that stops with the reason :timeout during a call", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      pid = Session.pid(session)
      true = :erlang.suspend_process(pid)
      Process.exit(pid, :timeout)
      task = Task.async(fn -> Session.prompt(session, "hi") end)

      await(
        fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 2} end,
        "the call"
      )

      ref = Process.monitor(pid)
      true = :erlang.resume_process(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :timeout}
      assert Task.await(task) == {:error, :session_not_found}
    end

    # An earlier entry of the caller goes too: a timeout is not a snapshot.
    test "a subscribe that times out leaves no entry", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      pid = Session.pid(session)
      true = :erlang.suspend_process(pid)

      exit = catch_exit(Session.subscribe(session))
      true = :erlang.resume_process(pid)
      assert {:timeout, _} = exit
      assert Registry.values(Helyx.Core.events_registry(core), session.id, self()) == []
    end

    test "input errors win over session_not_found", %{core: core} do
      session = %Session{id: "never", core: core}
      assert Session.steer(session, <<0xFF>>) == {:error, :invalid_utf8}
      assert Session.set_model(session, "bad") == {:error, {:invalid_model_ref, "bad"}}
    end
  end

  describe "the end signal (#189)" do
    defp watches(core, id),
      do: Registry.lookup(Helyx.Core.events_registry(core), {Helyx.Session.Watch, id})

    # Waits for the signal, then checks that no event follows it and that no
    # second signal follows.
    defp assert_end(id, reason) do
      await(fn -> Enum.any?(mailbox(), &match?({:helyx_session_end, _, _}, &1)) end, "the signal")
      after_signal = Enum.drop_while(mailbox(), &(not match?({:helyx_session_end, _, _}, &1)))
      assert [{:helyx_session_end, ^id, ^reason} | rest] = after_signal
      refute Enum.any?(rest, &match?({:helyx_event, _}, &1))
      assert_receive {:helyx_session_end, ^id, ^reason}
      refute_receive {:helyx_session_end, ^id, _}, 50
    end

    test "a normal stop gives :stopped, after the last event", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hi")
      assert_receive {:helyx_event, %Event{type: :message_start}}
      :ok = GenServer.stop(Session.pid(session))

      assert_end(session.id, :stopped)
      await(fn -> watches(core, session.id) == [] end, "the watch to leave")
    end

    @tag :capture_log
    test "a kill and a raise give :crashed", %{core: core} do
      {:ok, killed} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(killed)
      :ok = Session.prompt(killed, "hi")
      assert_receive {:helyx_event, %Event{type: :message_start}}
      Process.exit(Session.pid(killed), :kill)
      assert_end(killed.id, :crashed)

      # No clause takes this message, so the session raises.
      {:ok, raised} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(raised)
      :ok = Session.prompt(raised, "hi")
      assert_receive {:helyx_event, %Event{type: :message_start}}
      send(Session.pid(raised), :unexpected)
      assert_end(raised.id, :crashed)
    end

    test "a Core that stops gives :stopped", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      # The link of the events Registry would end the test process.
      Process.flag(:trap_exit, true)
      :ok = Supervisor.stop(core)
      assert_end(session.id, :stopped)
    end

    @tag :capture_log
    test "a subscribe that gets a snapshot gets the end signal after it", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      pid = Session.pid(session)
      :ok = :sys.suspend(pid)
      queued = fn n -> Process.info(pid, :message_queue_len) == {:message_queue_len, n} end

      # The session traps exits, so the exit signal is a message behind the
      # snapshot call: the session answers the call, then stops.
      spawn(fn ->
        await(fn -> queued.(1) end, "the call")
        Process.exit(pid, :shutdown)
        await(fn -> queued.(2) end, "the exit")
        :ok = :sys.resume(pid)
      end)

      assert {:ok, _snapshot} = Session.subscribe(session)
      assert_end(session.id, :stopped)
    end

    @tag :capture_log
    test "a subscribe that fails as the session ends leaves no signal and no watch", %{
      core: core
    } do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      pid = Session.pid(session)
      :ok = :sys.suspend(pid)

      spawn(fn ->
        await(
          fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 1} end,
          "the call"
        )

        Process.exit(pid, :kill)
      end)

      assert Session.subscribe(session) == {:error, :session_not_found}
      refute_received {:helyx_session_end, _, _}
      await(fn -> watches(core, session.id) == [] end, "the watch to leave")
    end

    test "a subscribe to a session that never ran starts no watch", %{core: core} do
      assert Session.subscribe(%Session{id: "never", core: core}) ==
               {:error, :session_not_found}

      assert watches(core, "never") == []
    end

    # The lost signal waits until the supervisor that restarts the Registry
    # has handled the exit: the test holds that supervisor suspended. A
    # crash of the partition: the Registry supervisor restarts it. A crash
    # of the Registry supervisor: the Core restarts it.
    for name <- [:partition, :registry] do
      @tag :capture_log
      test "a restart of the events Registry (#{name}) gives a lost signal, and the session runs",
           %{core: core} do
        Process.flag(:trap_exit, true)
        {:ok, session} = Session.start(core, model: "test/ok")
        pid = Session.pid(session)
        {:ok, _} = Session.subscribe(session)
        registry = Helyx.Core.events_registry(core)
        [{_, partition, _, _}] = Supervisor.which_children(registry)

        {restarter, target} =
          case unquote(name) do
            :partition -> {Process.whereis(registry), partition}
            :registry -> {Process.whereis(core), Process.whereis(registry)}
          end

        :ok = :sys.suspend(restarter)
        Process.exit(target, :kill)
        id = session.id
        # Longer than the 5 s timeout the barrier once had: no timeout ends it.
        refute_receive {:helyx_subscription_lost, ^id}, 5_500
        assert Process.alive?(pid)
        :ok = :sys.resume(restarter)
        assert_receive {:helyx_subscription_lost, ^id}
        refute_receive {:helyx_subscription_lost, _}, 50
        refute_received {:helyx_session_end, _, _}

        assert {:ok, _snapshot} = Session.subscribe(session)
        assert Session.pid(session) == pid
        :ok = Session.prompt(session, "hi")
        seqs = Enum.map(collect_until(:agent_end), & &1.seq)
        assert seqs == Enum.uniq(seqs)
        refute_received {:helyx_event, _}

        :ok = GenServer.stop(pid)
        assert_end(id, :stopped)
      end
    end

    # The old entry is gone from the new Registry, but its watch still waits
    # to send a lost signal. A subscribe in that window stops it, so the
    # signal does not reach the new subscription.
    @tag :capture_log
    test "a subscribe after a restart stops the old watch that has not signalled",
         %{core: core} do
      Process.flag(:trap_exit, true)
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      [{old, nil}] = watches(core, session.id)
      registry = Helyx.Core.events_registry(core)
      supervisor = Process.whereis(registry)
      [{_, partition, _, _}] = Supervisor.which_children(registry)
      # `:messages` also counts the signals that a suspended process has not
      # fetched; `:message_queue_len` does not.
      queued = fn pid, n -> length(elem(Process.info(pid, :messages), 1)) == n end

      # The old watch calls the suspended supervisor behind the exit. The BIF
      # suspend holds it inside that call after the Registry is back.
      :ok = :sys.suspend(supervisor)
      Process.exit(partition, :kill)
      await(fn -> queued.(supervisor, 2) end, "the exit and the call")
      true = :erlang.suspend_process(old)
      :ok = :sys.resume(supervisor)
      await(fn -> queued.(old, 1) end, "the reply")

      assert {:ok, _snapshot} = Session.subscribe(session)
      refute Process.alive?(old)
      id = session.id
      refute_receive {:helyx_subscription_lost, ^id}, 100
      assert [{new, nil}] = watches(core, id)
      assert new != old

      :ok = GenServer.stop(Session.pid(session))
      assert_end(id, :stopped)
    end

    # Each subscribe gets a live watch of its session, also when the watch
    # of the last one is gone (a lost signal that raced the register).
    test "a second subscribe replaces the watch", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      [{first, nil}] = watches(core, session.id)
      ref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first, :killed}

      {:ok, _} = Session.subscribe(session)
      registry = Helyx.Core.events_registry(core)
      assert [second] = Registry.values(registry, session.id, self())
      assert second != first
      assert [{^second, nil}] = watches(core, session.id)

      :ok = GenServer.stop(Session.pid(session))
      assert_end(session.id, :stopped)
    end

    test "a subscribe removes the entries of dead watches and keeps their signals",
         %{core: core} do
      {:ok, ended} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(ended)
      :ok = GenServer.stop(Session.pid(ended))
      id = ended.id
      assert_receive {:helyx_session_end, ^id, :stopped} = signal
      send(self(), signal)

      {:ok, other} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(other)
      assert Process.get({Helyx.Session.Watch, core, ended.id}) == nil
      assert is_pid(Process.get({Helyx.Session.Watch, core, other.id}))
      assert_received {:helyx_session_end, ^id, :stopped}
    end

    test "a subscriber that exits stops its watch", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      test = self()

      subscriber =
        spawn(fn ->
          {:ok, _} = Session.subscribe(session)
          send(test, :subscribed)
          Process.sleep(:infinity)
        end)

      assert_receive :subscribed
      [{watch, nil}] = watches(core, session.id)
      ref = Process.monitor(watch)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^watch, :normal}
    end
  end

  describe "session instance (#204)" do
    @describetag :tmp_dir

    defp prompt_events(session) do
      :ok = Session.prompt(session, "hi")
      collect_until(:agent_end)
    end

    test "each start has its own instance, and its events carry it", %{core: core, tmp_dir: dir} do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      {:ok, first} = Session.subscribe(session)
      assert Enum.all?(prompt_events(session), &(&1.instance_id == first.instance_id))

      stop_session(session, &GenServer.stop/1)
      {:ok, resumed} = Session.resume(core, sessions_dir: dir)
      {:ok, second} = Session.subscribe(resumed)

      assert is_binary(second.instance_id) and second.instance_id != first.instance_id
      assert Enum.all?(prompt_events(resumed), &(&1.instance_id == second.instance_id))
    end

    # The review of #188, round 4, spec item 1: the entry of the old
    # subscription stays across the resume, and the new instance starts
    # `seq` at 0 again.
    test "a subscriber that keeps its entry across a resume can tell the new instance", %{
      core: core,
      tmp_dir: dir
    } do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      {:ok, old} = Session.subscribe(session)
      prompt_events(session)

      stop_session(session, &GenServer.stop/1)
      assert_receive {:helyx_session_end, _id, :stopped}
      {:ok, resumed} = Session.resume(core, sessions_dir: dir)

      events = prompt_events(resumed)
      assert hd(events).seq == 1
      refute Enum.any?(events, &(&1.instance_id == old.instance_id))
    end

    # The review of #188, round 4, failure-path item 1.
    test "a subscribe to the id in another Core leaves the events of the first", %{
      core: core,
      tmp_dir: dir
    } do
      other = start_core([Helyx.Test.Provider])

      {:ok, a} = Session.start(core, model: "test/ok", sessions_dir: dir)
      {:ok, b} = Session.resume(other, sessions_dir: dir)
      assert a.id == b.id

      {:ok, snapshot_a} = Session.subscribe(a)
      :ok = Session.prompt(a, "hi")
      queued = fn -> for {:helyx_event, event} <- mailbox(), do: event end
      await(fn -> Enum.any?(queued.(), &(&1.type == :agent_end)) end, "the events of Core A")
      before = queued.()

      {:ok, snapshot_b} = Session.subscribe(b)
      assert snapshot_a.instance_id != snapshot_b.instance_id
      assert collect_until(:agent_end) == before
      assert Enum.all?(before, &(&1.instance_id == snapshot_a.instance_id))
      assert Enum.all?(prompt_events(b), &(&1.instance_id == snapshot_b.instance_id))
    end
  end

  describe "client_start_error/1" do
    test "the errors of the contract pass unchanged" do
      for error <- [
            :invalid_cwd,
            :not_found,
            {:invalid_model_ref, "x"},
            {:unknown_provider, "p"},
            {:bad_provider_turn, "p"}
          ] do
        assert Session.client_start_error(error) == error
      end
    end

    test "any other error is a fixed text, and the log has the full term" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Session.client_start_error({:tool_unavailable, "bash", "/secret/path"}) ==
                   {:start_failed, "the session did not start; the server log has the reason"}

          assert {:start_failed, _} = Session.client_start_error({:bad, Helyx.Session})
          assert {:start_failed, _} = Session.client_start_error({:unknown_provider, :atom})
        end)

      assert log =~ ~s({:tool_unavailable, "bash", "/secret/path"})
      assert log =~ "Helyx.Session"
    end

    @tag :capture_log
    test "an invalid ref passes only within the bounds of Helyx.ModelRef" do
      failed = {:start_failed, "the session did not start; the server log has the reason"}

      # Each fails to parse only for its form: no slash, or an empty part.
      for ref <- [String.duplicate("a", 256), String.duplicate("é", 128), "a/", "/b"] do
        assert Session.client_start_error({:invalid_model_ref, ref}) == {:invalid_model_ref, ref}
      end

      for ref <- [
            String.duplicate("a", 257),
            String.duplicate("é", 128) <> "a",
            <<0xFF>>,
            "a b",
            "a/\e[2J",
            "a/b\n"
          ] do
        assert Session.client_start_error({:invalid_model_ref, ref}) == failed
      end
    end

    test "a real start error of a client", %{core: core} do
      {:error, reason} = Session.start(core, model: "nope/m")
      assert Session.client_start_error(reason) == {:unknown_provider, "nope"}
    end
  end
end
