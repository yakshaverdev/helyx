defmodule Helyx.Session.ApprovalsTest do
  # Harness approvals through the `before_tool` chain (ADR 0013 §4,
  # docs/features/hooks.md, "Harness approvals"): a provider asks for a
  # decision on a call of its own tools with `{:approval, approval_id,
  # call_id}`, and the session answers with `{:approval, turn_id,
  # approval_id, decision}`.
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [collect_until: 1, of_type: 2, snapshot: 1, wait_until: 1]
  import Helyx.Test.SessionCase, only: [start_core: 1]

  alias Helyx.Message.ToolCall
  alias Helyx.Session
  alias Helyx.Test.Hook

  # The margin of a wait for a message that must not come: a hook that ran
  # would report within this time even on a loaded machine.
  @load_ms 300

  @call %ToolCall{id: "i1", name: "fileChange", arguments: %{"changes" => ["a.txt"]}}

  # The controller of `Helyx.Test.Connected` and the test name of the
  # hooks are two names, so two proxies forward to the test process.
  defp core(hooks, tools \\ []) do
    core = start_core([Helyx.Test.Connected | tools ++ hooks])
    test = self()
    Process.register(spawn_link(fn -> forward(test) end), Hook.test_name(core))
    Process.register(spawn_link(fn -> forward(test) end), Helyx.Test.Connected.controller(core))
    core
  end

  defp forward(pid) do
    receive do
      message -> send(pid, message)
    end

    forward(pid)
  end

  # A session of the model "hang" in its first turn: the session, the
  # provider process, and the turn id.
  defp turn(core, opts \\ []) do
    {:ok, session} = Session.start(core, [model: "conn/hang"] ++ opts)
    {:ok, _snapshot, _ref} = Session.subscribe(session, answers: true)
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, pid, {:turn, turn_id, _context}}
    {session, pid, turn_id}
  end

  defp events(pid, turn_id, events),
    do: send(pid, {:batch, Enum.map(events, &{:event, turn_id, &1})})

  @upcase %ToolCall{id: "c1", name: "upcase", arguments: %{"text" => "hi"}}

  # The first request of `kinds` that the provider process `pid` reported.
  defp next_request(pid, kinds) do
    kinds = Map.from_keys(kinds, true)

    receive do
      {:conn, kind, ^pid, request} when is_map_key(kinds, kind) -> request
    after
      5_000 -> flunk("no request of #{inspect(Map.keys(kinds))}")
    end
  end

  defp in_mailbox?(pid, fun) do
    {:messages, messages} = Process.info(pid, :messages)
    Enum.any?(messages, fun)
  end

  # A hook that reports the call it decides and blocks.
  defp blocking(core, test) do
    Hook.script(core, Hook.A, :before_tool, fn %{tool: tool} ->
      send(test, {:deciding, tool})
      Process.sleep(:infinity)
    end)
  end

  defp hook_entries(dir) do
    [path] = Path.wildcard(Path.join([dir, "*", "*.jsonl"]))

    for line <- String.split(File.read!(path), "\n", trim: true),
        %{"type" => "hook"} = entry <- [JSON.decode!(line)],
        do: Map.drop(entry, ["id", "parent_id", "ts"])
  end

  test "with no before_tool hook a request is denied at once" do
    {_session, pid, turn_id} = turn(core([]))
    events(pid, turn_id, [{:tool_call, @call}, {:approval, "0", "i1"}])
    assert_receive {:conn, :approval, ^pid, {:approval, ^turn_id, "0", {:deny, reason}}}
    assert reason =~ "no before_tool hook"
  end

  @tag :tmp_dir
  test "every hook allows: the request is allowed, with the call and the provider id, and each answer is an entry",
       %{tmp_dir: dir} do
    core = core([Hook.A, Hook.B])
    Hook.script(core, Hook.B, :before_tool, fn _ -> {:allow, "fine"} end)
    {_session, pid, turn_id} = turn(core, sessions_dir: dir)
    events(pid, turn_id, [{:tool_call, @call}, {:approval, "0", "i1"}])

    assert_receive {:conn, :approval, ^pid, {:approval, ^turn_id, "0", :allow}}
    assert_received {:hook, Hook.A, :before_tool, input}
    assert_received {:hook, Hook.B, :before_tool, _input}

    assert %{
             tool: "fileChange",
             arguments: %{"changes" => ["a.txt"]},
             call_id: "i1",
             turn_id: ^turn_id,
             provider: "conn"
           } = input

    assert [
             %{"hook" => "Helyx.Test.Hook.A", "answer" => "allow", "tool" => "fileChange"} = first,
             %{"hook" => "Helyx.Test.Hook.B", "answer" => "allow", "reason" => "fine"} = second
           ] = hook_entries(dir)

    assert first["arguments"] == ~s({"changes":["a.txt"]}) and first["call_id"] == "i1"
    refute Map.has_key?(second, "tool")
  end

  test "a deny wins, and a failed hook denies" do
    core = core([Hook.A, Hook.B])
    Hook.script(core, Hook.A, :before_tool, fn %{call_id: id} -> {:deny, "no #{id}"} end)
    {_session, pid, turn_id} = turn(core)
    events(pid, turn_id, [{:tool_call, @call}, {:approval, "0", "i1"}])

    assert_receive {:conn, :approval, ^pid, {:approval, ^turn_id, "0", {:deny, reason}}}
    assert reason == "the hook Helyx.Test.Hook.A denied the call: no i1"
    refute_received {:hook, Hook.B, :before_tool, _}

    Hook.script(core, Hook.A, :before_tool, fn _ -> raise "boom" end)
    events(pid, turn_id, [{:approval, "1", "i1"}])
    assert_receive {:conn, :approval, ^pid, {:approval, ^turn_id, "1", {:deny, reason}}}
    assert reason =~ "the hook Helyx.Test.Hook.A failed:"
  end

  test "a request whose call id names no open call is denied at once, and no hook runs" do
    {_session, pid, turn_id} = turn(core([Hook.A]))
    events(pid, turn_id, [{:approval, "0", "nope"}])
    assert_receive {:conn, :approval, ^pid, {:approval, ^turn_id, "0", {:deny, reason}}}
    assert reason =~ "no open call"
    refute_receive {:hook, Hook.A, :before_tool, _}, @load_ms
  end

  test "a second request for a call with a pending one is denied; a pending approval id fails the turn" do
    core = core([Hook.A])
    test = self()

    Hook.script(core, Hook.A, :before_tool, fn _ ->
      send(test, :deciding)
      Process.sleep(:infinity)
    end)

    {_session, pid, turn_id} = turn(core)
    events(pid, turn_id, [{:tool_call, @call}, {:approval, "0", "i1"}])
    assert_receive :deciding
    events(pid, turn_id, [{:approval, "1", "i1"}])
    assert_receive {:conn, :approval, ^pid, {:approval, ^turn_id, "1", {:deny, reason}}}
    assert reason =~ "pending approval request"

    events(pid, turn_id, [{:approval, "0", "i1"}])
    assert %{data: %{outcome: :error, error: error}} = List.last(collect_until(:turn_end))
    assert error =~ "approval"
  end

  test "at an abort the session denies the pending request, then sends the interrupt" do
    core = core([Hook.A])
    test = self()

    Hook.script(core, Hook.A, :before_tool, fn _ ->
      send(test, :deciding)
      Process.sleep(:infinity)
    end)

    {session, pid, turn_id} = turn(core)
    events(pid, turn_id, [{:tool_call, @call}, {:approval, "0", "i1"}])
    assert_receive :deciding
    :ok = Session.abort(session)

    assert_receive {:conn, kind, ^pid, request} when kind in [:approval, :interrupt]
    assert {:approval, ^turn_id, "0", {:deny, _reason}} = request
    assert_receive {:conn, :interrupt, ^pid, {:interrupt, ^turn_id}}
    assert %{data: %{outcome: :aborted}} = List.last(collect_until(:turn_end))
    # The chain was killed: no second answer.
    refute_receive {:conn, :approval, ^pid, _}, @load_ms
  end

  test "a hook of an approval chain asks the clients, and the answer decides" do
    core = core([Hook.A])

    Hook.script(core, Hook.A, :before_tool, fn _ ->
      {:ok, %{"ok" => ok}} = Helyx.Hook.ask(%{"allow?" => true})
      if ok, do: {:allow, "the user said yes"}, else: {:deny, "the user said no"}
    end)

    {session, pid, turn_id} = turn(core)
    events(pid, turn_id, [{:tool_call, @call}, {:approval, "0", "i1"}])

    [%{ask_id: id, call_id: "i1", tool: "fileChange"}] = of_type(collect_until(:ask), :ask)
    assert Session.answer(session, id, %{"ok" => true}) == :ok
    assert_receive {:conn, :approval, ^pid, {:approval, ^turn_id, "0", :allow}}
  end

  test "a hook Task that calls Helyx.Tool.ask/1 in an approval chain gets not_running" do
    # A hook Task of the chain may ask; the chain Task itself has no record.
    core = core([Hook.A])
    test = self()

    Hook.script(core, Hook.A, :before_tool, fn _ ->
      send(test, {:tool_ask, Helyx.Tool.ask(%{"q" => 1})})
      :allow
    end)

    {_session, pid, turn_id} = turn(core)
    events(pid, turn_id, [{:tool_call, @call}, {:approval, "0", "i1"}])
    assert_receive {:tool_ask, {:error, :not_running}}
    assert_receive {:conn, :approval, ^pid, {:approval, ^turn_id, "0", :allow}}
  end

  test "a request of a turn that is not current is denied" do
    {session, pid, turn_id} = turn(core([Hook.A]))
    send(pid, {:finish, turn_id})
    collect_until(:turn_end)
    events(pid, turn_id, [{:approval, "0", "i1"}])
    assert_receive {:conn, :approval, ^pid, {:approval, ^turn_id, "0", {:deny, _reason}}}
    refute_receive {:hook, Hook.A, :before_tool, _}, @load_ms
    assert %{} = snapshot(session)
  end

  test "at a done the pending request is denied, and the hands end its running chain" do
    core = core([Hook.A])
    test = self()

    Hook.script(core, Hook.A, :before_tool, fn _ ->
      :ok = Helyx.Tool.hold({test, :handle})
      send(test, {:deciding, "fileChange"})
      Process.sleep(:infinity)
    end)

    {_session, pid, turn_id} = turn(core)
    events(pid, turn_id, [{:tool_call, @call}, {:approval, "0", "i1"}])
    assert_receive {:deciding, "fileChange"}
    send(pid, {:finish, turn_id})

    assert {:approval, ^turn_id, "0", {:deny, reason}} = next_request(pid, [:approval])
    assert reason =~ "the turn ended"
    assert_receive {:released, Hook.A, [{_test, :handle}], :cancel}
    assert %{data: %{outcome: :done}} = List.last(collect_until(:turn_end))
    refute_receive {:conn, :approval, ^pid, _}, @load_ms
  end

  test "a deny reason over the result bound is cut as a result" do
    core = core([Hook.A])
    Hook.script(core, Hook.A, :before_tool, fn _ -> {:deny, String.duplicate("é", 40_000)} end)
    {_session, pid, turn_id} = turn(core)
    events(pid, turn_id, [{:tool_call, @call}, {:approval, "0", "i1"}])

    assert {:approval, ^turn_id, "0", {:deny, reason}} = next_request(pid, [:approval])
    assert byte_size(reason) <= Helyx.Message.max_result_bytes() and String.valid?(reason)
    assert reason =~ "the hook Helyx.Test.Hook.A denied the call: é"
  end

  @tag :capture_log
  test "a crash of the chain Task is a deny" do
    core = core([Hook.A])
    test = self()

    Hook.script(core, Hook.A, :before_tool, fn _ ->
      send(test, {:hands, Process.get(:helyx_hands)})
      Process.sleep(:infinity)
    end)

    {_session, pid, turn_id} = turn(core)
    events(pid, turn_id, [{:tool_call, @call}, {:approval, "0", "i1"}])
    assert_receive {:hands, hands}

    [chain] =
      for {_ref, {task, _turn, {:approval, "i1"}, _module, _place}} <- :sys.get_state(hands).tasks,
          do: task.pid

    Process.exit(chain, :crash)
    assert {:approval, ^turn_id, "0", {:deny, reason}} = next_request(pid, [:approval])
    assert reason =~ "the approval chain crashed"
  end

  test "a call of a closed message of the turn with no result is open: its chain runs" do
    core = core([Hook.A])
    {_session, pid, turn_id} = turn(core)

    events(pid, turn_id, [
      {:tool_call, @call},
      {:message_end, :tool_use, nil},
      {:approval, "0", "i1"}
    ])

    assert {:approval, ^turn_id, "0", :allow} = next_request(pid, [:approval])
    assert_received {:hook, Hook.A, :before_tool, %{call_id: "i1", provider: "conn"}}
  end

  test "a call that is open in the tool queue is no call of the provider's own tools: denied" do
    core = core([Hook.A], [Helyx.Test.Tool.Upcase])
    blocking(core, self())
    {_session, pid, turn_id} = turn(core)

    events(pid, turn_id, [
      {:tool_call, @upcase},
      {:tool_request, "c1", "upcase", %{"text" => "hi"}}
    ])

    assert_receive {:deciding, "upcase"}
    events(pid, turn_id, [{:approval, "0", "c1"}])
    assert {:approval, ^turn_id, "0", {:deny, reason}} = next_request(pid, [:approval])
    assert reason =~ "no open call"
    refute_receive {:deciding, _tool}, @load_ms
  end

  test "at an abort: the deny of each pending request, then the aborted tool results, then the interrupt" do
    core = core([Hook.A], [Helyx.Test.Tool.Upcase])
    blocking(core, self())
    {session, pid, turn_id} = turn(core)

    events(pid, turn_id, [
      {:tool_call, @upcase},
      {:tool_request, "c1", "upcase", %{"text" => "hi"}},
      {:tool_call, @call},
      {:approval, "0", "i1"}
    ])

    assert_receive {:deciding, "upcase"}
    assert_receive {:deciding, "fileChange"}
    :ok = Session.abort(session)

    kinds = [:approval, :tool_result, :interrupt]
    assert {:approval, ^turn_id, "0", {:deny, _reason}} = next_request(pid, kinds)
    assert {:tool_result, ^turn_id, "c1", {:error, "aborted"}} = next_request(pid, kinds)
    assert {:interrupt, ^turn_id} = next_request(pid, kinds)
  end

  test "a decision that comes after its turn ended is dropped: the request has one answer" do
    core = core([Hook.A])
    test = self()

    Hook.script(core, Hook.A, :before_tool, fn _ ->
      send(test, {:deciding, self()})
      receive do: (:go -> :allow)
    end)

    {session, pid, turn_id} = turn(core)
    events(pid, turn_id, [{:tool_call, @call}, {:approval, "0", "i1"}])
    assert_receive {:deciding, hook}

    # The session takes the end of the turn before the decision.
    spid = Session.pid(session)
    :ok = :sys.suspend(spid)
    send(pid, {:finish, turn_id})
    wait_until(fn -> in_mailbox?(spid, &match?({:stream_end, ^turn_id, _}, &1)) end)
    send(hook, :go)

    wait_until(fn ->
      in_mailbox?(spid, &match?({:approval_result, ^turn_id, "i1", :allow}, &1))
    end)

    :ok = :sys.resume(spid)

    assert {:approval, ^turn_id, "0", {:deny, _reason}} = next_request(pid, [:approval])
    refute_receive {:conn, :approval, ^pid, _}, @load_ms
  end

  # A call with a pending approval request is one that the provider runs
  # itself: a tool request for it breaks the contract, and one call id
  # never has two chains in the hands.
  test "a tool request for a call with a pending approval request stops the provider, and the turn fails" do
    core = core([Hook.A], [Helyx.Test.Tool.Upcase])
    blocking(core, self())
    {_session, pid, turn_id} = turn(core)
    ref = Process.monitor(pid)
    events(pid, turn_id, [{:tool_call, @upcase}, {:approval, "0", "c1"}])
    assert_receive {:deciding, "upcase"}

    events(pid, turn_id, [{:tool_request, "c1", "upcase", %{"text" => "hi"}}])
    assert %{data: %{outcome: :error, error: error}} = List.last(collect_until(:turn_end))
    assert error =~ "tool_request"
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    refute_receive {:deciding, _tool}, @load_ms
  end

  # docs/features/hooks.md, "The owner of a call id".
  describe "the owner of a call id" do
    test "an approval for a Helyx call that Core answered, before the provider's result, is denied" do
      core = core([Hook.A], [Helyx.Test.Tool.Upcase])
      {_session, pid, turn_id} = turn(core)

      events(pid, turn_id, [
        {:tool_call, @upcase},
        {:tool_request, "c1", "upcase", %{"text" => "hi"}}
      ])

      assert {:tool_result, ^turn_id, "c1", {:ok, "HI"}} = next_request(pid, [:tool_result])
      assert_receive {:hook, Hook.A, :before_tool, %{call_id: "c1", provider: nil}}

      events(pid, turn_id, [{:approval, "0", "c1"}])
      assert {:approval, ^turn_id, "0", {:deny, reason}} = next_request(pid, [:approval])
      assert reason =~ "no open call"
      refute_receive {:hook, Hook.A, :before_tool, %{provider: "conn"}}, @load_ms
    end

    test "a call that opens after its tool request is the Helyx call's at the answer" do
      core = core([Hook.A], [Helyx.Test.Tool.Upcase])
      {_session, pid, turn_id} = turn(core)

      events(pid, turn_id, [
        {:tool_request, "c1", "upcase", %{"text" => "hi"}},
        {:tool_call, @upcase}
      ])

      assert {:tool_result, ^turn_id, "c1", {:ok, "HI"}} = next_request(pid, [:tool_result])

      events(pid, turn_id, [{:approval, "0", "c1"}])
      assert {:approval, ^turn_id, "0", {:deny, _reason}} = next_request(pid, [:approval])
      refute_receive {:hook, Hook.A, :before_tool, %{provider: "conn"}}, @load_ms
    end

    test "a tool request for a call whose approval Core answered stops the provider, and the turn fails" do
      core = core([Hook.A])
      {_session, pid, turn_id} = turn(core)
      ref = Process.monitor(pid)
      events(pid, turn_id, [{:tool_call, @call}, {:approval, "0", "i1"}])
      assert {:approval, ^turn_id, "0", :allow} = next_request(pid, [:approval])

      events(pid, turn_id, [{:tool_request, "i1", "fileChange", %{}}])
      assert %{data: %{outcome: :error, error: error}} = List.last(collect_until(:turn_end))
      assert error =~ "tool_request"
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    test "a tool request for a call whose approval chain waits stops the provider" do
      core = core([Hook.A])
      blocking(core, self())
      {_session, pid, turn_id} = turn(core)
      ref = Process.monitor(pid)
      calls = for n <- 1..9, do: %{@call | id: "i#{n}"}
      approvals = for n <- 1..9, do: {:approval, "#{n}", "i#{n}"}
      events(pid, turn_id, Enum.map(calls, &{:tool_call, &1}) ++ approvals)
      for _ <- 1..8, do: assert_receive({:deciding, "fileChange"})

      events(pid, turn_id, [{:tool_request, "i9", "fileChange", %{}}])
      assert %{data: %{outcome: :error}} = List.last(collect_until(:turn_end))
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    test "an approval for a call that waits in the tool queue is denied, and no chain runs" do
      core = core([Hook.A], [Helyx.Test.Tool.Upcase])
      blocking(core, self())
      {_session, pid, turn_id} = turn(core)
      c2 = %{@upcase | id: "c2"}

      events(pid, turn_id, [
        {:tool_call, @upcase},
        {:tool_call, c2},
        {:tool_request, "c1", "upcase", %{"text" => "hi"}},
        {:tool_request, "c2", "upcase", %{"text" => "hi"}}
      ])

      assert_receive {:deciding, "upcase"}
      events(pid, turn_id, [{:approval, "0", "c2"}])
      assert {:approval, ^turn_id, "0", {:deny, reason}} = next_request(pid, [:approval])
      assert reason =~ "no open call"
      refute_receive {:deciding, _tool}, @load_ms
    end

    test "after its result a call id is an ended id: a tool request for it is not checked (#369)" do
      core = core([Hook.A], [Helyx.Test.Tool.Upcase])
      {_session, pid, turn_id} = turn(core)
      events(pid, turn_id, [{:tool_call, %{@call | name: "upcase"}}, {:approval, "0", "i1"}])
      assert {:approval, ^turn_id, "0", :allow} = next_request(pid, [:approval])

      events(pid, turn_id, [
        {:tool_result, "i1", {:ok, "done"}},
        {:tool_request, "i1", "upcase", %{"text" => "hi"}}
      ])

      assert {:tool_result, ^turn_id, "i1", {:ok, "HI"}} = next_request(pid, [:tool_result])
    end
  end
end
