defmodule Helyx.Session.BeforeSettleTest do
  # The `before_settle` chain and the continue turn (ADR 0013,
  # docs/features/before-settle.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [collect_until: 1, messages: 1, of_type: 2, wait_until: 1]
  import Helyx.Test.SessionCase, only: [start_core: 2, stop_session: 2]

  alias Helyx.{Message, Session}
  alias Helyx.Test.Hook

  # The margin of a wait for a message that must not come: a turn or a
  # hook that ran would send it within this time even on a loaded machine.
  @load_ms 300

  defp core(hooks, opts \\ []) do
    core = start_core([Helyx.Test.Provider | hooks], opts)
    test = self()
    proxy = spawn_link(fn -> forward(test) end)
    Process.register(proxy, Hook.test_name(core))
    core
  end

  defp forward(pid) do
    receive do
      message -> send(pid, message)
    end

    forward(pid)
  end

  defp run(core, model, opts \\ []) do
    {:ok, session} = Session.start(core, [model: "test/#{model}"] ++ opts)
    {:ok, _snapshot, _ref} = Session.subscribe(session, answers: true)
    :ok = Session.prompt(session, "go")
    session
  end

  # A gate whose messages a proxy forwards to the test, so a test can open
  # more than one (`Helyx.Test.Gate.open/0` names the test process itself).
  defp gate do
    gate = :"gate_#{System.unique_integer([:positive])}"
    test = self()
    proxy = spawn_link(fn -> forward(test) end)
    Process.register(proxy, gate)
    Atom.to_string(gate)
  end

  # A Core with the connected provider, the gate, background, and
  # slow-release tools, and a controller proxy that forwards to the test.
  defp connected(hooks) do
    core =
      core([
        Helyx.Test.Connected,
        Helyx.Test.Gate,
        Helyx.Test.Tool.Background,
        Helyx.Test.Tool.SlowRelease | hooks
      ])

    test = self()
    proxy = spawn_link(fn -> forward(test) end)
    Process.register(proxy, Helyx.Test.Connected.controller(core))
    core
  end

  # A session of the connected provider `model`, at the request of its turn.
  defp connect(core, model) do
    {:ok, session} = Session.start(core, model: "conn/#{model}")
    {:ok, _snapshot, _ref} = Session.subscribe(session, answers: true)
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, proc, {:turn, turn_id, _}}
    {session, proc, turn_id}
  end

  # Starts a background run of the turn at `gate`, holds `handles`, and
  # returns the run and its id.
  defp background(proc, turn_id, gate, handles) do
    args = %{"gate" => gate, "handles" => handles}
    send(proc, {:tool_request, turn_id, "bg", "background", args})
    assert_receive {:waiting, run}
    assert_receive {:conn, :tool_result, ^proc, {:tool_result, ^turn_id, "bg", {:ok, start}}}
    [_, id] = Regex.run(~r/\A<background id="(\S+)"/, start)
    {run, id}
  end

  # Starts a call whose release waits for :go from `gate`; its result waits
  # for the release, so the call still runs. Returns the release Task.
  defp slow_release(proc, turn_id, gate) do
    send(proc, {:tool_request, turn_id, "slow", "slow_release", %{"gate" => gate}})
    assert_receive {:releasing, release}
    release
  end

  # The ends that wait for a turn.
  defp held_ends(session),
    do: Helyx.Session.Queue.counts(:sys.get_state(Session.pid(session)).queue).held

  # Waits until the session holds a wait with a hands request pending.
  defp wait_behind_hands(session) do
    pid = Session.pid(session)

    wait_until(fn ->
      match?(%{phase: %{wait: %{hands: hands}}} when hands != nil, :sys.get_state(pid))
    end)
  end

  # Waits until the session holds a wait whose turn ended at `:done`, with
  # its hands request pending and its `before_settle` chain due.
  defp due_chain_behind_hands(session) do
    pid = Session.pid(session)

    wait_until(fn ->
      match?(
        %{phase: %{wait: %{hands: hands, settle: {:due, _, _}}}} when hands != nil,
        :sys.get_state(pid)
      )
    end)
  end

  # `module` answers each of `answers` in turn, then settles.
  defp answers(core, module, answers) do
    {:ok, agent} = Agent.start_link(fn -> answers end)

    Hook.script(core, module, :before_settle, fn _input ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {:settle, []}
      end)
    end)
  end

  defp status(session), do: GenServer.call(Session.pid(session), :live).status

  defp idle(session), do: wait_until(fn -> status(session) == :idle end)

  # The `hook` entries of the session files in `dir`.
  defp hook_entries(dir) do
    for path <- Path.wildcard(Path.join([dir, "*", "*.jsonl"])),
        line <- String.split(File.read!(path), "\n", trim: true),
        %{"type" => "hook"} = entry <- [JSON.decode!(line)],
        do: Map.drop(entry, ["id", "parent_id", "ts"])
  end

  defp notices(events), do: for(%{text: text} <- of_type(events, :notice), do: text)

  defp users(events), do: for(%Message{role: :user} = m <- messages(events), do: m)

  describe "the continue" do
    @tag :tmp_dir
    test "starts the next turn with the hook's message, and is recorded", %{tmp_dir: dir} do
      core = core([Hook.SettleA], sessions_dir: dir)
      answers(core, Hook.SettleA, [{:continue, "the tests fail"}])
      cwd = Path.join(dir, "work")
      File.mkdir_p!(cwd)
      session = run(core, "ok", sessions_dir: dir, cwd: cwd)

      first = collect_until(:turn_end)
      turn_id = List.last(first).turn_id
      assert_receive {:hook, Hook.SettleA, :before_settle, input}

      assert input == %{
               session_id: session.id,
               turn_id: turn_id,
               stop_reason: :end_turn,
               cwd: cwd
             }

      second = collect_until(:turn_end)
      assert [%{origin: %{kind: :hook, id: "Helyx.Test.Hook.SettleA"}} = user] = users(second)
      assert Message.text(user) == "the tests fail"
      second_id = List.last(second).turn_id
      assert second_id != turn_id

      # The continue turn ends too, and its chain settles.
      assert_receive {:hook, Hook.SettleA, :before_settle, %{turn_id: ^second_id}}
      idle(session)
      refute_receive {:helyx_event, %{type: :turn_start}}, @load_ms

      # One entry: the continue; a settle is not written.
      assert hook_entries(dir) == [
               %{
                 "type" => "hook",
                 "point" => "before_settle",
                 "turn_id" => turn_id,
                 "call_id" => nil,
                 "hook" => "Helyx.Test.Hook.SettleA",
                 "answer" => "continue",
                 "reason" => nil
               }
             ]

      # The message of the continue reads back with its origin.
      stop_session(session, &GenServer.stop/1)
      {:ok, resumed, _} = Session.resume(core, sessions_dir: dir, cwd: cwd)
      {:ok, snapshot, _ref} = Session.subscribe(resumed)

      assert [_go, %{origin: %{kind: :hook, id: "Helyx.Test.Hook.SettleA"}}] =
               for(%Message{role: :user} = m <- snapshot.messages, do: m)
    end

    test "goes ahead of the follow-ups that queued while the chain ran" do
      core = core([Hook.SettleA])
      test = Hook.test_name(core)

      Hook.script(core, Hook.SettleA, :before_settle, fn %{turn_id: _} ->
        send(test, {:blocked, self()})

        receive do
          :continue -> {:continue, "again"}
          :settle -> :settle
        end
      end)

      session = run(core, "ok")
      collect_until(:turn_end)
      assert_receive {:blocked, hook}

      # The wait lasts while the chain runs: a prompt queues as a follow-up,
      # a steer as a steer.
      assert status(session) == :running
      :ok = Session.prompt(session, "later")
      :ok = Session.steer(session, "now")
      send(hook, :continue)

      # The steer joins the continue turn at its send.
      second = collect_until(:turn_end)
      assert [%{origin: %{kind: :hook}}, steer] = users(second)
      assert Message.text(steer) == "now"
      assert :sys.get_state(Session.pid(session)).queue.hook_turns == 1
      assert_receive {:blocked, hook}
      send(hook, :settle)

      # The follow-up, a client message, resets the count.
      third = collect_until(:turn_end)
      assert [%{origin: %{kind: :user}} = user] = users(third)
      assert Message.text(user) == "later"
      assert :sys.get_state(Session.pid(session)).queue.hook_turns == 0
      assert_receive {:blocked, hook}
      send(hook, :settle)
      idle(session)
    end

    test "a compaction that waits starts before the continue turn" do
      core = core([Hook.SettleA])
      test = Hook.test_name(core)

      Hook.script(core, Hook.SettleA, :before_settle, fn _ ->
        send(test, {:blocked, self()})

        receive do
          :continue -> {:continue, "again"}
          :settle -> :settle
        end
      end)

      session = run(core, "ok")
      collect_until(:turn_end)
      assert_receive {:blocked, hook}
      :ok = Session.compact(session)
      send(hook, :continue)

      assert [%{origin: :compaction}] = of_type(collect_until(:turn_start), :turn_start)
      collect_until(:turn_end)
      assert [%{origin: %{kind: :hook}}] = users(collect_until(:turn_end))
      assert_receive {:blocked, hook}
      send(hook, :settle)
      idle(session)
    end

    test "the first continue ends the chain" do
      core = core([Hook.SettleA, Hook.SettleB])
      answers(core, Hook.SettleA, [{:continue, "again"}])
      run(core, "ok")

      first_id = List.last(collect_until(:turn_end)).turn_id
      assert_receive {:hook, Hook.SettleA, :before_settle, _input}
      second_id = List.last(collect_until(:turn_end)).turn_id

      # The second chain settles at A and asks B; B was not asked before,
      # by the order of the proxy that forwards both.
      assert_receive {:hook, Hook.SettleB, :before_settle, %{turn_id: ^second_id}}
      refute_received {:hook, Hook.SettleB, :before_settle, %{turn_id: ^first_id}}
    end

    @tag :tmp_dir
    test "at most 8 turns in a row start from a continue; a client message resets it",
         %{tmp_dir: dir} do
      core = core([Hook.SettleA], sessions_dir: dir)
      Hook.script(core, Hook.SettleA, :before_settle, fn _ -> {:continue, "more"} end)
      session = run(core, "ok", sessions_dir: dir)

      events = Enum.flat_map(1..9, fn _ -> collect_until(:turn_end) end)
      assert length(of_type(events, :turn_start)) == 9
      assert length(for %{origin: %{kind: :hook}} <- users(events), do: true) == 8

      idle(session)
      refute_receive {:helyx_event, %{type: :turn_start}}, @load_ms

      assert_receive {:helyx_event, %{type: :notice, turn_id: nil, data: %{text: text}}}

      assert text ==
               "the hook Helyx.Test.Hook.SettleA asked for one more turn past the limit " <>
                 "of 8 turns in a row that hooks start; the session settled"

      # The continue past the count is written too: a log of answers.
      assert length(hook_entries(dir)) == 9

      # A client message resets the count: 8 more.
      :ok = Session.prompt(session, "go on")
      events = Enum.flat_map(1..9, fn _ -> collect_until(:turn_end) end)
      assert length(for %{origin: %{kind: :hook}} <- users(events), do: true) == 8
      idle(session)
    end

    test "a text over the bound of a client text is a failed hook" do
      core = core([Hook.SettleA])
      text = String.duplicate("a", Session.Input.max_text_bytes() + 1)
      answers(core, Hook.SettleA, [{:continue, text}])
      session = run(core, "ok")
      collect_until(:turn_end)

      assert_receive {:helyx_event, %{type: :notice, data: %{text: notice}}}
      assert notice =~ "the hook Helyx.Test.Hook.SettleA failed before the session settled: "
      assert notice =~ "it returned a value outside its contract"
      idle(session)
      refute_receive {:helyx_event, %{type: :turn_start}}, @load_ms
    end

    test "a text at the bound starts a turn" do
      core = core([Hook.SettleA])
      text = String.duplicate("a", Session.Input.max_text_bytes())
      answers(core, Hook.SettleA, [{:continue, text}])
      run(core, "ok")
      collect_until(:turn_end)

      assert [%{origin: %{kind: :hook}} = user] = users(collect_until(:turn_end))
      assert byte_size(Message.text(user)) == Session.Input.max_text_bytes()
    end
  end

  describe "a failed hook" do
    @tag :tmp_dir
    test "fails open: a notice, the chain goes on, and it is recorded", %{tmp_dir: dir} do
      core = core([Hook.SettleA, Hook.SettleB], sessions_dir: dir)

      for {answer, how} <- [
            {fn _ -> raise "boom" end, "boom"},
            {fn _ -> :yes end, "it returned a value outside its contract"},
            {fn _ -> {:continue, <<255>>} end, "it returned a value outside its contract"}
          ] do
        Hook.script(core, Hook.SettleA, :before_settle, answer)
        session = run(core, "ok", sessions_dir: dir)
        collect_until(:turn_end)

        assert_receive {:hook, Hook.SettleB, :before_settle, _input}
        idle(session)
        assert [notice] = notices(collect_until_quiet())
        assert notice =~ "the hook Helyx.Test.Hook.SettleA failed before the session settled: "
        assert notice =~ how
        stop_session(session, &GenServer.stop/1)
      end

      entries = hook_entries(dir)
      assert length(entries) == 3

      assert Enum.all?(
               entries,
               &match?(
                 %{"point" => "before_settle", "answer" => "failed", "call_id" => nil},
                 &1
               )
             )
    end

    # The limit counts the wait of the hook for its go (hooks.md): a hook
    # that must hold before its kill has the limit of 2,000 ms of SettleA,
    # the margin for load, and the wait for that kill makes the test slow.
    @tag :slow
    test "a hook past its limit fails, its handles are released, and the session settles" do
      core = core([Hook.SettleA])
      test = self()

      Hook.script(core, Hook.SettleA, :before_settle, fn _ ->
        :ok = Helyx.Tool.hold({test, :held})
        Process.sleep(:infinity)
      end)

      session = run(core, "ok")
      collect_until(:turn_end)

      assert_receive {:released, Hook.SettleA, [{^test, :held}], :cancel}
      assert_receive {:helyx_event, %{type: :notice, turn_id: nil, data: %{text: notice}}}
      assert notice =~ "it ran past its limit of 2000 ms"
      idle(session)
    end

    test "an ask of a before_settle hook gets :not_running" do
      core = core([Hook.SettleA])
      test = self()

      Hook.script(core, Hook.SettleA, :before_settle, fn _input ->
        send(test, {:ask, Helyx.Hook.ask(%{"q" => 1}), Helyx.Tool.context()})
        :settle
      end)

      session = run(core, "ok")
      collect_until(:turn_end)
      assert_receive {:ask, {:error, :not_running}, context}

      assert %{
               core: ^core,
               session_id: id,
               tools: [],
               tool: nil,
               call_id: nil,
               model: "test/ok",
               provider_opts: [],
               model_context: nil
             } = context

      assert id == session.id
    end
  end

  describe "the chain does not run" do
    test "after an abort, a failure, or a compaction turn" do
      core = core([Hook.SettleA])
      session = run(core, "hang")
      assert_receive {:helyx_event, %{type: :message_update}}
      :ok = Session.abort(session)
      collect_until(:turn_end)

      :ok = Session.set_model(session, "test/crash")
      :ok = Session.prompt(session, "again")
      assert [%{outcome: :error}] = of_type(collect_until(:turn_end), :turn_end)

      :ok = Session.set_model(session, "test/ok")
      :ok = Session.compact(session)
      assert [%{origin: :compaction}] = of_type(collect_until(:turn_start), :turn_start)
      collect_until(:turn_end)

      idle(session)
      refute_receive {:hook, Hook.SettleA, :before_settle, _}, @load_ms
    end
  end

  describe "an abort" do
    test "while the chain runs ends its hook, releases its handles, and starts no turn" do
      core = core([Hook.SettleA])
      test = self()
      proxy = Hook.test_name(core)

      Hook.script(core, Hook.SettleA, :before_settle, fn _ ->
        :ok = Helyx.Tool.hold({test, :held})
        send(proxy, {:blocked, self()})
        receive do: (:go -> {:continue, "never"})
      end)

      session = run(core, "ok")
      collect_until(:turn_end)
      assert_receive {:blocked, hook}
      ref = Process.monitor(hook)

      assert :ok = Session.abort(session)
      assert_receive {:released, Hook.SettleA, [{^test, :held}], :cancel}
      assert_receive {:DOWN, ^ref, :process, ^hook, _reason}
      assert status(session) == :idle
      refute_receive {:helyx_event, %{type: :turn_start}}, @load_ms
    end
  end

  describe "an abort with background runs" do
    test "while the chain runs revokes the run of the ended turn" do
      core = connected([Hook.SettleA])
      proxy = Hook.test_name(core)
      run_gate = gate()
      release_gate = gate()

      Hook.script(core, Hook.SettleA, :before_settle, fn _ ->
        send(proxy, {:blocked, self()})
        receive do: (:go -> {:continue, "never"})
      end)

      {session, proc, turn_id} = connect(core, "tools")
      {run, id} = background(proc, turn_id, run_gate, [%{"gate" => release_gate}])
      send(proc, {:finish, turn_id})
      collect_until(:turn_end)
      assert_receive {:blocked, _hook}
      ref = Process.monitor(run)

      abort = Task.async(fn -> Session.abort(session) end)
      assert_receive {:waiting, releaser}
      send(releaser, :go)
      assert :ok = Task.await(abort)

      assert_receive {:DOWN, ^ref, :process, ^run, _reason}
      assert {:ok, %{messages: messages}, _} = Session.subscribe(session)

      refute Enum.any?(
               messages,
               &match?(%Message{role: :user, origin: %{id: ^id}}, &1)
             )

      idle(session)
    end

    test "with the chain due and a cancel pending revokes the run after the cancel answers" do
      core = connected([Hook.SettleA])
      run_gate = gate()
      cancel_gate = gate()
      release_gate = gate()

      {session, proc, turn_id} = connect(core, "tools")
      {run, _id} = background(proc, turn_id, run_gate, [%{"gate" => release_gate}])
      release = slow_release(proc, turn_id, cancel_gate)

      send(proc, {:finish, turn_id})
      due_chain_behind_hands(session)
      ref = Process.monitor(run)
      abort = Task.async(fn -> Session.abort(session) end)

      wait_until(fn ->
        match?(%{phase: %{wait: %{settle: :revoke}}}, :sys.get_state(Session.pid(session)))
      end)

      # The revoke waits for the cancel that the release holds.
      assert Task.yield(abort, 0) == nil
      send(release, :go)
      assert_receive {:waiting, releaser}

      # The revoke waits for the release of the run's handle.
      assert Task.yield(abort, 0) == nil
      send(releaser, :go)

      assert_receive {:DOWN, ^ref, :process, ^run, _reason}
      assert :ok = Task.await(abort)
      idle(session)
    end

    test "without a chain keeps the run of the ended turn" do
      core = connected([])
      run_gate = gate()
      cancel_gate = gate()

      {session, proc, turn_id} = connect(core, "tools")
      {run, id} = background(proc, turn_id, run_gate, [])
      release = slow_release(proc, turn_id, cancel_gate)

      send(proc, {:finish, turn_id})
      wait_behind_hands(session)
      abort = Task.async(fn -> Session.abort(session) end)
      send(release, :go)
      assert :ok = Task.await(abort)
      collect_until(:turn_end)

      # The done turn's run is not revoked: its end waits for the next turn.
      assert Process.alive?(run)
      :ok = Session.set_model(session, "test/ok")
      send(run, :go)
      wait_until(fn -> held_ends(session) == 1 end)
      :ok = Session.prompt(session, "next")
      events = collect_until(:turn_end)

      assert Enum.any?(
               messages(events),
               &match?(%Message{role: :user, origin: %{kind: :background, id: ^id}}, &1)
             )

      idle(session)
    end

    test "a turn that fails revokes the run of its turn" do
      core = connected([])
      run_gate = gate()
      release_gate = gate()

      {session, proc, turn_id} = connect(core, "tools")
      {run, id} = background(proc, turn_id, run_gate, [%{"gate" => release_gate}])
      ref = Process.monitor(run)

      send(proc, {:fail, turn_id})
      assert [%{outcome: :error}] = of_type(collect_until(:turn_end), :turn_end)

      assert_receive {:waiting, releaser}
      send(releaser, :go)
      assert_receive {:DOWN, ^ref, :process, ^run, _reason}
      assert {:ok, %{messages: messages}, _} = Session.subscribe(session)

      refute Enum.any?(
               messages,
               &match?(%Message{role: :user, origin: %{id: ^id}}, &1)
             )

      idle(session)
    end

    test "an abort drops a due chain held behind a dying provider process" do
      core = connected([Hook.SettleA])
      proxy = Hook.test_name(core)
      release_gate = gate()

      Hook.script(core, Hook.SettleA, :before_settle, fn _ ->
        send(proxy, {:hook_called, self()})
        :settle
      end)

      {session, proc, turn_id} = connect(core, "stop")
      release = slow_release(proc, turn_id, release_gate)
      send(proc, {:finish, turn_id})
      due_chain_behind_hands(session)
      send(proc, :stop)

      wait_until(fn ->
        match?(
          %{phase: %{provider: %Helyx.Session.Server.Flow.Dying{}}},
          :sys.get_state(Session.pid(session))
        )
      end)

      abort = Task.async(fn -> Session.abort(session) end)
      send(release, :go)

      assert :ok = Task.await(abort)
      idle(session)
      refute_received {:hook_called, _hook}
    end
  end

  describe "with a connected provider" do
    @done {:done, %{stop_reason: :end_turn, usage: nil}}

    defp connected(core, model) do
      Process.register(self(), Helyx.Test.Connected.controller(core))
      {:ok, session} = Session.start(core, model: "conn/#{model}")
      {:ok, _snapshot, _ref} = Session.subscribe(session)
      :ok = Session.prompt(session, "one")
      collect_until(:turn_end)
      assert_receive {:conn, :init, proc, _}
      {session, proc}
    end

    test "a turn that the provider started by itself runs the chain" do
      core = core([Helyx.Test.Connected, Hook.SettleA])
      {session, proc} = connected(core, "echo")
      assert_receive {:hook, Hook.SettleA, :before_settle, _input}
      idle(session)

      send(proc, {:batch, [{:event, "p2", :turn_start}, {:event, "p2", @done}]})
      assert [%{origin: :provider}] = of_type(collect_until(:turn_end), :turn_start)
      assert_receive {:hook, Hook.SettleA, :before_settle, %{turn_id: "p2"}}
    end

    test "an abort while a continue waits for a switched provider's close drops it" do
      core = core([Helyx.Test.Connected, Hook.SettleA])
      proxy = Hook.test_name(core)

      Hook.script(core, Hook.SettleA, :before_settle, fn _ ->
        send(proxy, {:blocked, self()})
        receive do: (:go -> {:continue, "never"})
      end)

      {session, proc} = connected(core, "late_close")
      pid = Session.pid(session)
      assert_receive {:blocked, hook}
      :ok = Session.set_model(session, "test/ok")
      send(hook, :go)

      # The continue waits for the close of the old model's process.
      assert_receive {:conn, :close, ^proc, :close}
      assert_receive {:held, from}
      assert %Message{} = :sys.get_state(pid).queue.continue

      abort = Task.async(fn -> Session.abort(session) end)
      wait_until(fn -> :sys.get_state(pid).queue.continue == nil end)
      send(proc, {:answer, from, :ok})
      assert :ok = Task.await(abort)
      refute_receive {:helyx_event, %{type: :turn_start}}, @load_ms
    end
  end

  # The events that came so far.
  defp collect_until_quiet(acc \\ []) do
    receive do
      {:helyx_event, event} -> collect_until_quiet([event | acc])
    after
      @load_ms -> Enum.reverse(acc)
    end
  end
end
