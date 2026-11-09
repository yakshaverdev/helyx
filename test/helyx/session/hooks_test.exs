defmodule Helyx.Session.HooksTest do
  # The chain of `before_tool` and `after_tool` hooks around a Helyx tool
  # call (ADR 0013, docs/features/hooks.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [collect_until: 1, of_type: 2, snapshot: 1, wait_until: 1]
  import Helyx.Test.SessionCase, only: [start_core: 1, stop_session: 2]

  alias Helyx.{Message, Session}
  alias Helyx.Test.Hook

  @tools [Helyx.Test.Tool.Upcase, Helyx.Test.Tool.Ask]

  # The margin of a wait for a message that must not come: a hook that ran
  # would send it within this time even on a loaded machine.
  @load_ms 300

  # The hooks report to a proxy of the test process, so that the test
  # process stays free for a gate (`Helyx.Test.Gate.open/0`).
  defp core(hooks, tools \\ @tools) do
    core = start_core([Helyx.Test.Provider | tools ++ hooks])
    Hook.proxy(core, self())
    core
  end

  defp run(core, model, opts \\ []) do
    {:ok, session} = Session.start(core, [model: "test/#{model}"] ++ opts)
    {:ok, _snapshot, _ref} = Session.subscribe(session, answers: true)
    :ok = Session.prompt(session, "go")
    session
  end

  defp results(events),
    do:
      for(
        %{message: m} <- of_type(events, :tool_execution_end),
        do: {m.tool_call_id, m.is_error, Message.text(m)}
      )

  # The pid of the after_tool hook Task of "c1" whose record waits in the
  # mailbox of the session `pid`, or nil.
  defp after_record(pid) do
    {:messages, messages} = Process.info(pid, :messages)

    Enum.find_value(messages, fn
      {:asker, _turn_id, hook, {:hook, "c1"}} -> hook
      _other -> nil
    end)
  end

  # Whether the start answer of "1" waits in the mailbox of `pid`.
  defp start_answer?(pid) do
    {:messages, messages} = Process.info(pid, :messages)
    Enum.any?(messages, &match?({:tool_result, _, "1", {:started, _, _}}, &1))
  end

  # The index of the first message in the mailbox of `pid` that `fun`
  # takes, or nil.
  defp mailbox_index(pid, fun) do
    {:messages, messages} = Process.info(pid, :messages)
    Enum.find_index(messages, fun)
  end

  # The events that came so far.
  defp collect_until_quiet(acc \\ []) do
    receive do
      {:helyx_event, event} -> collect_until_quiet([event | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp hook_entries(dir) do
    [path] = Path.wildcard(Path.join([dir, "*", "*.jsonl"]))

    for line <- String.split(File.read!(path), "\n", trim: true),
        %{"type" => "hook"} = entry <- [JSON.decode!(line)],
        do: Map.drop(entry, ["id", "parent_id", "ts"])
  end

  describe "before_tool" do
    @tag :tmp_dir
    test "every hook allows: the call runs, and each answer is an entry", %{tmp_dir: dir} do
      core = core([Hook.A, Hook.B])
      Hook.script(core, Hook.B, :before_tool, fn _ -> {:allow, "fine"} end)
      session = run(core, "loop", sessions_dir: dir)
      events = collect_until(:turn_end)

      assert [{"c1", false, "HI"}, {"c2", true, "unknown tool: nope"}] = results(events)
      assert_receive {:hook, Hook.A, :before_tool, input}
      assert_receive {:hook, Hook.B, :before_tool, _input}

      turn_id = List.last(events).turn_id

      assert %{
               tool: "upcase",
               arguments: %{"text" => "hi"},
               call_id: "c1",
               turn_id: ^turn_id,
               provider: nil,
               session_id: id,
               cwd: cwd
             } = input

      assert id == session.id and is_binary(cwd)

      assert [first, second | _] = hook_entries(dir)

      assert first == %{
               "type" => "hook",
               "point" => "before_tool",
               "turn_id" => turn_id,
               "call_id" => "c1",
               "hook" => "Helyx.Test.Hook.A",
               "answer" => "allow",
               "reason" => nil,
               "tool" => "upcase",
               "arguments" => ~s({"text":"hi"}),
               "arguments_cut" => false
             }

      # The later entries of the chain hold the call id only.
      assert second == %{
               "type" => "hook",
               "point" => "before_tool",
               "turn_id" => turn_id,
               "call_id" => "c1",
               "hook" => "Helyx.Test.Hook.B",
               "answer" => "allow",
               "reason" => "fine"
             }
    end

    @tag :tmp_dir
    test "a deny wins: the call does not run, and no later hook is asked", %{tmp_dir: dir} do
      core = core([Hook.A, Hook.B])
      Hook.script(core, Hook.A, :before_tool, fn %{tool: tool} -> {:deny, "no #{tool}"} end)
      run(core, "loop", sessions_dir: dir)

      assert [{"c1", true, "the hook Helyx.Test.Hook.A denied the call: no upcase"} | _] =
               results(collect_until(:turn_end))

      refute_received {:hook, Hook.B, :before_tool, _}
      refute_received {:hook, _, :after_tool, %{call_id: "c1"}}

      assert [%{"answer" => "deny", "reason" => "no upcase", "call_id" => "c1"} | _] =
               hook_entries(dir)
    end

    test "a deny reason over the result bound is cut as a result" do
      core = core([Hook.A])
      reason = String.duplicate("é", 40_000)
      Hook.script(core, Hook.A, :before_tool, fn _ -> {:deny, reason} end)
      run(core, "loop")

      assert [{"c1", true, text} | _] = results(collect_until(:turn_end))
      assert byte_size(text) <= Message.max_result_bytes() and String.valid?(text)
      assert text =~ "[cut to"
    end

    test "a failed hook denies the call: a raise, a bad return, a bad reason" do
      core = core([Hook.A, Hook.B])

      for {answer, how} <- [
            {fn _ -> raise "boom" end, "boom"},
            {fn _ -> exit(:gone) end, "exit"},
            {fn _ -> :yes end, "it returned a value outside its contract"},
            {fn _ -> {:deny, <<255>>} end, "it returned a value outside its contract"},
            {fn _ -> {:allow, :atom} end, "it returned a value outside its contract"}
          ] do
        Hook.script(core, Hook.A, :before_tool, answer)
        run(core, "loop")

        assert [{"c1", true, text} | _] = results(collect_until(:turn_end))
        assert text =~ "the hook Helyx.Test.Hook.A failed: "
        assert text =~ how
        assert text =~ "; the call was not run"
        refute_received {:hook, Hook.B, :before_tool, %{call_id: "c1"}}
      end
    end

    @tag :tmp_dir
    test "a hook past its limit fails closed and is recorded", %{tmp_dir: dir} do
      core = core([Hook.Short])
      Hook.script(core, Hook.Short, :before_tool, fn _ -> Process.sleep(:infinity) end)
      run(core, "loop", sessions_dir: dir)

      assert [{"c1", true, text} | _] = results(collect_until(:turn_end))

      assert text ==
               "the hook Helyx.Test.Hook.Short failed: it ran past its limit of 100 ms; " <>
                 "the call was not run"

      assert [%{"answer" => "failed", "reason" => "it ran past its limit of 100 ms"} | _] =
               hook_entries(dir)
    end
  end

  describe "the hook entry" do
    @tag :tmp_dir
    test "a reason and the arguments are cut at 4,096 bytes at a character boundary",
         %{tmp_dir: dir} do
      core = core([Hook.A])

      Hook.script(core, Hook.A, :before_tool, fn _ ->
        {:allow, "x" <> String.duplicate("é", 3_000)}
      end)

      run(core, "big_args", sessions_dir: dir)
      collect_until(:turn_end)

      assert [%{"reason" => reason, "arguments" => arguments, "arguments_cut" => true}] =
               hook_entries(dir)

      # "x" and 2,047 "é" fill 4,095 bytes: the next "é" does not fit.
      assert reason == "x" <> String.duplicate("é", 2_047)
      # `{"text":"` is 9 bytes, then 2,043 "é" fill 4,095 bytes.
      assert arguments == ~s({"text":") <> String.duplicate("é", 2_043)
    end

    test "a text at the bound is not cut" do
      text = String.duplicate("a", 4_096)
      assert Helyx.Session.HookEntry.cut(text) == {text, false}
      assert Helyx.Session.HookEntry.cut(text <> "a") == {text, true}
      assert Helyx.Session.HookEntry.cut(text <> "é") == {text, true}
    end

    @tag :tmp_dir
    @tag :capture_log
    test "a resume reads no hook entry, and drops a bad one", %{tmp_dir: dir} do
      core = core([Hook.A])
      session = run(core, "loop", sessions_dir: dir)
      collect_until(:turn_end)
      transcript = snapshot(session).messages
      stop_session(session, &GenServer.stop/1)

      [path] = Path.wildcard(Path.join([dir, "*", "*.jsonl"]))

      last =
        path |> File.read!() |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()

      bad = %{"type" => "hook", "id" => "badhookentry", "parent_id" => last["id"], "point" => 1}
      File.write!(path, JSON.encode!(bad) <> "\n", [:append])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, resumed} = Session.resume(core, id: session.id, sessions_dir: dir)
          {:ok, snapshot, _ref} = Session.subscribe(resumed)
          send(self(), {:messages, snapshot.messages})
        end)

      assert_received {:messages, messages}
      assert Enum.map(messages, & &1.id) == Enum.map(transcript, & &1.id)
      assert log =~ "a hook entry of the session file is not valid"
    end
  end

  describe "an abort" do
    @tag :tmp_dir
    test "kills the running hook with a cancel release, and it has no entry", %{tmp_dir: dir} do
      core = core([Hook.A, Hook.B])
      test = self()
      Hook.script(core, Hook.A, :before_tool, fn _ -> {:allow, "first"} end)

      Hook.script(core, Hook.B, :before_tool, fn _ ->
        :ok = Helyx.Tool.hold({test, :handle})
        send(test, :holding)
        Process.sleep(:infinity)
      end)

      session = run(core, "loop", sessions_dir: dir)
      assert_receive :holding
      :ok = Session.abort(session)
      assert_receive {:released, Hook.B, [{_test, :handle}], :cancel}
      assert %{data: %{outcome: :aborted}} = List.last(collect_until(:turn_end))

      assert [%{"hook" => "Helyx.Test.Hook.A", "reason" => "first"}] = hook_entries(dir)
    end
  end

  describe "a late answer" do
    @tag :tmp_dir
    test "an answer of a turn that ended is written, with no notice", %{tmp_dir: dir} do
      core = core([Hook.A])
      session = run(core, "loop", sessions_dir: dir)
      collect_until(:turn_end)

      # As the hands send it after an abort raced it.
      record = %{
        point: :after_tool,
        call_id: "c9",
        hook: Hook.A,
        outcome: {:failed, "late"},
        call: nil,
        pid: nil
      }

      send(Session.pid(session), {:hook_answer, "ended-turn", record})
      _ = snapshot(session)

      assert %{"turn_id" => "ended-turn", "answer" => "failed", "reason" => "late"} =
               List.last(hook_entries(dir))

      assert of_type(collect_until_quiet(), :notice) == []
    end
  end

  describe "after_tool" do
    @tag :tmp_dir
    test "each hook gets the result the hook before it left; a keep is not recorded",
         %{tmp_dir: dir} do
      core = core([Hook.A, Hook.B])

      Hook.script(core, Hook.A, :after_tool, fn
        %{result: {:ok, text}} -> {:replace, {:error, text <> "!"}}
        _other -> :keep
      end)

      run(core, "loop", sessions_dir: dir)

      assert [{"c1", true, "HI!"}, {"c2", true, "unknown tool: nope"}] =
               results(collect_until(:turn_end))

      assert_receive {:hook, Hook.A, :after_tool, %{call_id: "c1", result: {:ok, "HI"}}}
      assert_receive {:hook, Hook.B, :after_tool, %{call_id: "c1", result: {:error, "HI!"}}}

      after_entries = for %{"point" => "after_tool"} = e <- hook_entries(dir), do: e

      assert [
               %{
                 "hook" => "Helyx.Test.Hook.A",
                 "answer" => "replace",
                 "reason" => nil,
                 "call_id" => "c1",
                 "tool" => "upcase"
               }
             ] = after_entries
    end

    test "a failed hook keeps the result and emits a notice" do
      core = core([Hook.A, Hook.B])
      Hook.script(core, Hook.A, :after_tool, fn _ -> throw(:nope) end)

      Hook.script(core, Hook.B, :after_tool, fn %{result: {s, t}} -> {:replace, {s, t <> "+"}} end)

      run(core, "loop")
      events = collect_until(:turn_end)

      assert [{"c1", false, "HI+"} | _] = results(events)

      assert Enum.any?(of_type(events, :notice), fn %{text: text} ->
               text =~ "the hook Helyx.Test.Hook.A failed after the call c1: "
             end)
    end

    test "a replaced result over the result bound is cut" do
      core = core([Hook.A])
      big = String.duplicate("a", 100_000)
      Hook.script(core, Hook.A, :after_tool, fn _ -> {:replace, {:ok, big}} end)
      run(core, "loop")

      assert [{"c1", false, text} | _] = results(collect_until(:turn_end))
      assert byte_size(text) <= Message.max_result_bytes()
    end
  end

  describe "background" do
    test "the after_tool hooks run once, on the start answer, and keep its status" do
      core = core([Hook.A], [Helyx.Test.Gate, Helyx.Test.Tool.Background])

      Hook.script(core, Hook.A, :after_tool, fn %{result: {:ok, text}} ->
        {:replace, {:error, "hooked " <> text}}
      end)

      gate = Helyx.Test.Gate.open()
      {:ok, session} = Session.start(core, model: "test/bg." <> gate)
      {:ok, _snapshot, _ref} = Session.subscribe(session)
      :ok = Session.prompt(session, "go")
      assert_receive {:waiting, run}

      assert [{"1", true, text}] = results(collect_until(:turn_end))
      assert text =~ ~r/\A<background id="\S+" status="started">\nhooked started /
      assert_receive {:hook, Hook.A, :after_tool, %{call_id: "1"}}

      send(run, :go)
      collect_until(:turn_end)
      refute_received {:hook, Hook.A, :after_tool, _}
    end
  end

  describe "background, no place" do
    test "a start answer with no place runs no after_tool hook on it; the error result gets them" do
      core = core([Hook.A], [Helyx.Test.Tool.NoPlace])
      run(core, "call.no_place")

      assert [{"c1", true, "started/1 needs a place from background/0"}] =
               results(collect_until(:turn_end))

      assert_receive {:hook, Hook.A, :after_tool, %{result: {:error, _}}}
      refute_received {:hook, Hook.A, :after_tool, %{result: {:ok, "phantom"}}}
    end

    test "started/1 in a hook Task raises: a failed hook" do
      core = core([Hook.A])
      test = self()

      Hook.script(core, Hook.A, :before_tool, fn _ ->
        send(test, {:raised, catch_error(Helyx.Tool.started("x"))})
        :allow
      end)

      run(core, "loop")
      assert_receive {:raised, %ArgumentError{}}
      collect_until(:turn_end)
    end
  end

  describe "hook Tasks" do
    test "a hook holds a handle; the hands release it at its end, before the call runs" do
      core = core([Hook.A])
      test = self()

      Hook.script(core, Hook.A, :before_tool, fn _ ->
        :ok = Helyx.Tool.hold({test, :handle})
        :allow
      end)

      run(core, "loop")
      assert_receive {:released, Hook.A, [{_test, :handle}], :deliver}
      assert [{"c1", false, "HI"} | _] = results(collect_until(:turn_end))
    end

    # The limit counts the wait of the hook for its go (hooks.md): a hook
    # that must hold before its kill has the limit of 2,000 ms of Hook.A,
    # the margin for load, and the wait for that kill makes the test slow.
    @tag :slow
    test "a hook killed at its limit gets a cancel release" do
      core = core([Hook.A])
      test = self()

      Hook.script(core, Hook.A, :before_tool, fn _ ->
        :ok = Helyx.Tool.hold({test, :handle})
        Process.sleep(:infinity)
      end)

      run(core, "loop")
      assert_receive {:released, Hook.A, [{_test, :handle}], :cancel}
      collect_until(:turn_end)
    end

    test "an unconfirmed release fails its hook and refuses the next hook start" do
      core = core([Hook.A, Hook.B])
      test = self()

      Hook.script(core, Hook.A, :after_tool, fn _ ->
        :ok = Helyx.Tool.hold({test, :stuck})
        {:replace, {:ok, "replaced"}}
      end)

      run(core, "loop")
      events = collect_until(:turn_end)

      # A's answer does not count: its handle is unconfirmed. B is refused.
      assert [{"c1", false, "HI"}, {"c2", true, text2}] = results(events)
      assert text2 =~ "could not be released; the call was not run"
      notices = for %{text: text} <- of_type(events, :notice), do: text

      assert Enum.any?(
               notices,
               &(&1 =~ "Hook.A failed after the call c1: a resource of the hook")
             )

      assert Enum.any?(notices, &(&1 =~ "Hook.B failed after the call c1: a resource from an"))
      refute_received {:hook, Hook.B, :after_tool, _}
    end

    test "a hook Task is no tool call: background/0 refuses it" do
      core = core([Hook.A])
      test = self()

      Hook.script(core, Hook.A, :before_tool, fn _ ->
        send(test, {:background, Helyx.Tool.background()})
        :allow
      end)

      run(core, "loop")
      assert_receive {:background, {:error, "only a tool call can run in the background"}}
      collect_until(:turn_end)
    end
  end

  describe "the hands" do
    # A limit of 2,000 ms, as in the cancel release test above.
    @tag :slow
    test "the limit holds while the hands are busy: the hook is killed by the timer server" do
      core = core([Hook.A])
      test = self()

      Hook.script(core, Hook.A, :before_tool, fn _ ->
        send(test, {:hook_task, self()})
        Process.sleep(:infinity)
      end)

      session = run(core, "loop")
      assert_receive {:hook_task, hook_task}
      hands = :sys.get_state(Session.pid(session)).hands
      ref = Process.monitor(hook_task)
      :erlang.suspend_process(hands)
      # The kill at 2,000 ms comes from the timer server, not from the hands.
      assert_receive {:DOWN, ^ref, :process, ^hook_task, :killed}, 5_000
      :erlang.resume_process(hands)

      assert [{"c1", true, text} | _] = results(collect_until(:turn_end))
      assert text =~ "past its limit of 2000 ms"
    end

    test "a call Task that dies while its hook runs takes the hook with it, released" do
      core = core([Hook.A])
      test = self()

      Hook.script(core, Hook.A, :after_tool, fn
        %{call_id: "c1"} ->
          :ok = Helyx.Tool.hold({test, :handle})
          send(test, {:hook_task, self()})
          Process.sleep(:infinity)

        _other ->
          :keep
      end)

      session = run(core, "loop")
      assert_receive {:hook_task, hook_task}
      %{tasks: tasks} = :sys.get_state(:sys.get_state(Session.pid(session)).hands)
      [call_task] = for {_ref, {task, _turn, "c1", _tool, _place}} <- tasks, do: task.pid
      ref = Process.monitor(hook_task)
      Process.exit(call_task, :kill)

      assert_receive {:DOWN, ^ref, :process, ^hook_task, _reason}
      assert_receive {:released, Hook.A, [{_test, :handle}], :cancel}
      assert [{"c1", true, "tool crashed: :killed"} | _] = results(collect_until(:turn_end))
    end

    test "a hook request of a process that is no call Task gets no answer, and the hands live" do
      core = core([Hook.A])
      Hook.script(core, Hook.A, :before_tool, fn _ -> Process.sleep(:infinity) end)
      session = run(core, "loop")
      assert_receive {:hook, Hook.A, :before_tool, _}
      hands = :sys.get_state(Session.pid(session)).hands

      # As a call Task that a cancel killed after it sent its request.
      request = %{
        module: Hook.A,
        ms: 100,
        point: :before_tool,
        input: %{},
        record: nil,
        context: %{}
      }

      assert catch_exit(GenServer.call(hands, {:hook, request}, 200))
      assert Process.alive?(hands)
      :ok = Session.abort(session)
      collect_until(:turn_end)
    end
  end

  describe "asks" do
    test "a hook asks with Helyx.Hook.ask/1, and the answer goes to the hook" do
      core = core([Hook.A])

      Hook.script(core, Hook.A, :before_tool, fn
        %{tool: "ask"} ->
          {:ok, %{"ok" => ok}} = Helyx.Hook.ask(%{"allow?" => true})
          if ok, do: :allow, else: {:deny, "the user said no"}

        _other ->
          :allow
      end)

      session = run(core, "ask")

      [%{ask_id: id, call_id: "a1", tool: "ask", request: %{"allow?" => true}}] =
        of_type(collect_until(:ask), :ask)

      assert Session.answer(session, id, %{"ok" => false}) == :ok
      assert [{"a1", true, text}] = results(collect_until(:turn_end))
      assert text == "the hook Helyx.Test.Hook.A denied the call: the user said no"
    end

    # The test kills the hook while it asks: a hook of 100 ms could be
    # killed at its limit before it asks, since the limit counts its wait
    # for its go.
    @tag :capture_log
    test "the end of the hook Task ends its ask, so no question stays open" do
      core = core([Hook.A])
      test = self()

      Hook.script(core, Hook.A, :before_tool, fn _ ->
        send(test, {:asking, self()})
        Helyx.Hook.ask(%{"q" => 1})
      end)

      session = run(core, "ask")
      assert_receive {:asking, hook}
      [%{ask_id: id}] = of_type(collect_until(:ask), :ask)
      Process.exit(hook, :kill)

      assert [%{ask_id: ^id, outcome: :ended}] = of_type(collect_until(:ask_end), :ask_end)
      assert Session.answer(session, id, %{}) == {:error, :not_waiting}
      assert [{"a1", true, text}] = results(collect_until(:turn_end))
      assert text =~ "the hook Helyx.Test.Hook.A failed"
      assert snapshot(session).asks == []
    end

    test "a hook Task runs only after the session stored its record and let it go" do
      core = core([Hook.A])
      test = self()

      Hook.script(core, Hook.A, :before_tool, fn _ ->
        send(test, {:before, self()})
        receive do: (:go -> :allow)
      end)

      Hook.script(core, Hook.A, :after_tool, fn _ ->
        send(test, :after_ran)
        :keep
      end)

      session = run(core, "loop")
      pid = Session.pid(session)
      assert_receive {:before, before}
      # The session handles no message until it resumes.
      :ok = :sys.suspend(pid)
      send(before, :go)

      # The hands started the after_tool hook and sent its record; the
      # hook waits for the session.
      wait_until(fn -> after_record(pid) != nil end)
      hook = after_record(pid)
      assert Process.alive?(hook)
      refute_receive :after_ran, @load_ms

      :ok = :sys.resume(pid)
      assert_receive :after_ran
      assert [{"c1", false, "HI"} | _] = results(collect_until(:turn_end))
    end

    test "a background run goes on only after the session took its start answer" do
      core = core([Hook.Before], [Helyx.Test.Tool.BgAsk, Helyx.Test.Tool.GateWait])
      test = self()

      Hook.script(core, Hook.Before, :before_tool, fn _ ->
        send(test, {:before, self()})
        receive do: (:go -> :allow)
      end)

      gate = Helyx.Test.Gate.open()
      session = run(core, "reuse." <> gate)
      pid = Session.pid(session)
      assert_receive {:before, before}
      :ok = :sys.suspend(pid)
      send(before, :go)

      # The start answer waits in the mailbox of the session, and the run
      # waits for the session.
      wait_until(fn -> start_answer?(pid) end)
      refute_receive {:bg, _run}, @load_ms

      :ok = :sys.resume(pid)
      assert_receive {:bg, run}
      assert_receive {:before, second}
      send(second, :go)
      assert_receive {:call, call}
      send(run, :go)
      assert_receive {:bg_ask, {:error, :not_running}}
      send(call, :go)
      collect_until(:turn_end)
    end

    test "an ask is taken at once while the hands release another Task" do
      core = core([], [Helyx.Test.Tool.SlowRelease, Helyx.Test.Tool.GateAsk])
      gate = Helyx.Test.Gate.open()
      session = run(core, "release_ask." <> gate)
      assert_receive {:ready, asker}
      # The hands are in the release of c1 until `releaser` gets :go.
      assert_receive {:releasing, releaser}
      send(asker, :go)

      assert [%{ask_id: id, call_id: "a1", request: %{"q" => "now"}}] =
               of_type(collect_until(:ask), :ask)

      assert Session.answer(session, id, %{"ok" => true}) == :ok
      send(releaser, :go)

      assert Enum.sort(results(collect_until(:turn_end))) ==
               [{"a1", false, ~s({"ok":true})}, {"c1", false, "held"}]
    end

    test "a background run cannot ask as a later call of the same id" do
      core = core([], [Helyx.Test.Tool.BgAsk, Helyx.Test.Tool.GateWait])
      gate = Helyx.Test.Gate.open()
      run(core, "reuse." <> gate)
      assert_receive {:bg, bg}
      # The second call "1" runs now.
      assert_receive {:call, call}
      send(bg, :go)
      assert_receive {:bg_ask, {:error, :not_running}}
      send(call, :go)
      collect_until(:turn_end)
    end

    test "a call Task that calls Helyx.Hook.ask/1 gets not_running" do
      core = core([Hook.A], [Helyx.Test.Tool.HookAsk])
      run(core, "call.hook_ask")
      assert [{"c1", false, "not_running"}] = results(collect_until(:turn_end))
    end

    test "the answer of a hook ends its ask, whatever the order of its :DOWN" do
      core = core([Hook.A])
      test = self()

      Hook.script(core, Hook.A, :before_tool, fn _ ->
        send(test, {:asking, self()})
        Helyx.Hook.ask(%{"q" => 1})
      end)

      session = run(core, "ask")
      assert_receive {:asking, hook}
      assert %{data: %{ask_id: id}, turn_id: turn_id} = List.last(collect_until(:ask))

      # The answer of the hook as the hands send it when the hook ended,
      # here while the hook Task lives, so no :DOWN can end the ask.
      record = %{point: :before_tool, call_id: "a1", hook: Hook.A, outcome: {:failed, "x"}}

      send(
        Session.pid(session),
        {:hook_answer, turn_id, Map.merge(record, %{call: nil, pid: hook})}
      )

      assert [%{ask_id: ^id, outcome: :ended}] = of_type(collect_until(:ask_end), :ask_end)
      assert Process.alive?(hook)
      assert snapshot(session).asks == []
      :ok = Session.abort(session)
      collect_until(:turn_end)
    end

    # The test kills B while it asks, as in the test above.
    @tag :capture_log
    test "the hands send the answer of a hook killed while it asks with its pid, before the next record" do
      core = core([Hook.B, Hook.A])
      test = self()

      # The after_tool chain goes on past a failed hook.
      Hook.script(core, Hook.B, :after_tool, fn _ ->
        send(test, {:asking, self()})
        Helyx.Hook.ask(%{"q" => 1})
      end)

      session = run(core, "loop")
      pid = Session.pid(session)
      assert_receive {:asking, hook}
      collect_until(:ask)
      :ok = :sys.suspend(pid)
      Process.exit(hook, :kill)

      # B is killed; the hands answer for it, then start A.
      next = &match?({:asker, _, _, {:hook, "c1"}}, &1)
      wait_until(fn -> mailbox_index(pid, next) != nil end)
      answer = mailbox_index(pid, &match?({:hook_answer, _, %{pid: ^hook}}, &1))
      assert answer != nil
      assert answer < mailbox_index(pid, next)

      :ok = :sys.resume(pid)
      collect_until(:turn_end)
    end

    test "a hook Task that calls Helyx.Tool.ask/1 gets not_running" do
      core = core([Hook.A])
      test = self()

      Hook.script(core, Hook.A, :before_tool, fn _ ->
        send(test, {:tool_ask, Helyx.Tool.ask(%{"q" => 1})})
        :allow
      end)

      run(core, "loop")
      assert_receive {:tool_ask, {:error, :not_running}}
      collect_until(:turn_end)
    end

    test "a process that a hook starts gets not_running" do
      core = core([Hook.A])
      test = self()

      Hook.script(core, Hook.A, :after_tool, fn _ ->
        # A process that the hook starts has no hands.
        context = Helyx.Tool.context()

        spawned =
          Task.async(fn ->
            Process.put(:helyx_call, context)
            Helyx.Hook.ask(%{"q" => 1})
          end)

        send(test, {:spawned, Task.await(spawned)})
        :keep
      end)

      run(core, "loop")
      assert_receive {:spawned, {:error, :not_running}}
      collect_until(:turn_end)
    end
  end
end
