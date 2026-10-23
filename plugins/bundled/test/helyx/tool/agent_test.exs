defmodule Helyx.Tool.AgentTest do
  # The agent tool: a child session per call, its result, its link to the
  # parent, its depth, and the four ends of a child: an abort of the parent
  # turn, a stop of the parent session, a Core stop, and a child that ends
  # by itself (docs/features/agent-tool.md).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Helyx.Test.Events, only: [collect_until: 1]

  alias Helyx.{Message, Session}
  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Session.File.Scan

  @moduletag :tmp_dir

  defmodule Report do
    @moduledoc false
    # The scripts of `Fake`; a provider option `report: pid` sends each
    # `init/3` options to `pid` with the session id.
    @behaviour Helyx.Provider
    @behaviour Helyx.Provider.Loop

    @impl true
    def id, do: "report"

    @impl Helyx.Provider
    def init(model, _tools, opts) do
      if pid = opts[:report], do: send(pid, {:init, opts[:session_id], opts})
      {:ok, Helyx.Provider.Loop.new(__MODULE__, model, opts)}
    end

    @impl Helyx.Provider
    defdelegate request(request, from, state), to: Helyx.Provider.Loop

    @impl Helyx.Provider
    defdelegate info(message, state), to: Helyx.Provider.Loop

    @impl Helyx.Provider.Loop
    defdelegate stream(model, context, opts), to: Fake
  end

  defmodule Kept do
    @moduledoc false
    # Holds `:kept`, which its release keeps, then blocks as the block tool
    # does: the stop of a child that runs it leaves a handle held.
    @behaviour Helyx.Tool

    @impl true
    def name, do: "kept"
    @impl true
    def description, do: "Holds a handle that its release keeps."
    @impl true
    def parameters, do: %{"type" => "object"}

    @dialyzer {:nowarn_function, run: 2}
    @impl true
    def run(args, cwd) do
      :ok = Helyx.Tool.hold(:kept)
      Helyx.Test.Tool.Block.run(args, cwd)
    end

    @impl true
    def release(handles, _mode, _deadline), do: handles
  end

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core,
       name: core,
       plugins: [
         Fake,
         Report,
         Helyx.Tool.Agent,
         Helyx.Tool.Question,
         Helyx.Tool.Read,
         Helyx.Test.Tool.Block,
         Kept
       ],
       sessions_dir: dir},
      id: core
    )

    %{core: core}
  end

  defp agent(id, prompt \\ "the task"),
    do: %ToolCall{
      id: id,
      name: "agent",
      arguments: %{"description" => "a task", "prompt" => prompt}
    }

  # The parent and its children share the model of the parent: its script
  # gives one response per call, in the order the calls come.
  defp parent(core, dir, responses, opts \\ []) do
    model = "agent_#{System.unique_integer([:positive])}"
    :ok = Fake.script(core, model, responses)
    {provider, opts} = Keyword.pop(opts, :provider, "fake")
    {:ok, session} = Helyx.Sessions.start(core, [model: "#{provider}/#{model}", cwd: dir] ++ opts)
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    session
  end

  # A response that blocks the child in the block tool; the test gets
  # `{:blocked, child_id}`.
  defp block,
    do: [%ToolCall{id: "b1", name: "block", arguments: %{"to" => Helyx.Test.Gate.open()}}]

  defp results(events),
    do: for(%{message: m} <- Helyx.Test.Events.of_type(events, :tool_execution_end), do: m)

  defp messages(events), do: Helyx.Test.Events.messages(events)

  defp child_id(session, call_id), do: Helyx.Sessions.child_id(session.id, call_id)

  defp child_pid(core, id), do: Session.pid(%Session{id: id, core: core})

  test "the result is the child's final text, and the child is linked and stopped", %{
    core: core,
    tmp_dir: dir
  } do
    session = parent(core, dir, [[agent("c1")], ["child ", "answer"], ["Done."]])
    events = collect_until(:turn_end)

    assert [result] = results(events)
    refute result.is_error
    id = child_id(session, "c1")
    assert Message.text(result) == "child answer"
    assert child_pid(core, id) == nil

    assert {:ok, _path, header} = Scan.find(dir, id)
    assert header["parent"] == %{"session_id" => session.id, "call_id" => "c1"}

    assert header["model"] ==
             :sys.get_state(Session.pid(session)).model |> Helyx.ModelRef.to_string()

    assert header["cwd"] == dir
    assert Enum.map(Scan.list(dir, :all), & &1.id) == [session.id]
  end

  test "a child has no agent tool, so it cannot start a child", %{core: core, tmp_dir: dir} do
    session = parent(core, dir, [[agent("c1")], [agent("c2")], ["no agent"], ["Done."]])
    [result] = results(collect_until(:turn_end))
    assert Message.text(result) == "no agent"

    {:ok, path, _header} = Scan.find(dir, child_id(session, "c1"))
    assert File.read!(path) =~ "unknown tool: agent"
  end

  test "a child has no question tool: no user watches it", %{core: core, tmp_dir: dir} do
    question = %ToolCall{id: "q1", name: "question", arguments: %{"questions" => []}}
    session = parent(core, dir, [[agent("c1")], [question], ["no question"], ["Done."]])
    [result] = results(collect_until(:turn_end))
    assert Message.text(result) == "no question"

    {:ok, path, _header} = Scan.find(dir, child_id(session, "c1"))
    assert File.read!(path) =~ "unknown tool: question"
  end

  # #797: the `init/3` of a child gets the provider options of the parent
  # process, those of its start, then those of its resume.
  test "a child starts with the provider options of its parent", %{core: core, tmp_dir: dir} do
    provider_opts = [persist: false, report: self()]
    script = [[agent("c1")], ["child"], ["Done."], [agent("c2")], ["again"], ["Done."]]
    session = parent(core, dir, script, provider: "report", provider_opts: provider_opts)

    [result] = results(collect_until(:turn_end))
    assert Message.text(result) == "child"
    child = child_id(session, "c1")
    assert_receive {:init, ^child, opts}
    assert Keyword.take(opts, [:persist, :report]) == provider_opts

    :ok = Helyx.Sessions.stop(session)
    {:ok, resumed} = Helyx.Sessions.resume(core, id: session.id, provider_opts: [report: self()])
    {:ok, _snapshot, _ref} = Session.subscribe(resumed)
    :ok = Session.prompt(resumed, "more")

    [result] = results(collect_until(:turn_end))
    assert Message.text(result) == "again"
    child = child_id(session, "c2")
    assert_receive {:init, ^child, opts}
    assert Keyword.take(opts, [:persist, :report]) == [report: self()]
  end

  test "a child gets no tool that the parent lacks", %{core: core, tmp_dir: dir} do
    read = %ToolCall{id: "r1", name: "read", arguments: %{"path" => "x"}}

    session =
      parent(core, dir, [[agent("c1")], [read], ["no read"], ["Done."]], tools: ["agent"])

    [result] = results(collect_until(:turn_end))
    assert Message.text(result) == "no read"

    {:ok, path, _header} = Scan.find(dir, child_id(session, "c1"))
    assert File.read!(path) =~ "unknown tool: read"
  end

  test "a second call with the call id of an earlier child gets an error result", %{
    core: core,
    tmp_dir: dir
  } do
    session = parent(core, dir, [[agent("c1")], ["first"], ["Done."], [agent("c1")], ["Done."]])
    [first] = results(collect_until(:turn_end))
    assert Message.text(first) == "first"

    :ok = Session.prompt(session, "again")
    [second] = results(collect_until(:turn_end))
    assert second.is_error
    assert Message.text(second) =~ "eexist"

    {:ok, path, _header} = Scan.find(dir, child_id(session, "c1"))
    assert File.read!(path) =~ "first"
  end

  test "a failed child turn gives an error result with the reason", %{core: core, tmp_dir: dir} do
    _session = parent(core, dir, [[agent("c1")]])
    [result] = results(collect_until(:turn_end))
    assert result.is_error
    assert Message.text(result) =~ ~r/\Athe turn failed: .*no_script/
  end

  test "calls run together, and an abort of the parent turn ends each child", %{
    core: core,
    tmp_dir: dir
  } do
    blocked = block()
    session = parent(core, dir, [[agent("c1"), agent("c2")], blocked, blocked])

    assert_receive {:blocked, one}
    assert_receive {:blocked, two}
    # The ids come from the calls, so the user finds an aborted child.
    assert Enum.sort([one, two]) == Enum.sort([child_id(session, "c1"), child_id(session, "c2")])
    pids = [child_pid(core, one), child_pid(core, two)]
    refs = Enum.map(pids, &Process.monitor/1)

    :ok = Session.abort(session)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _pid, _reason})

    results = results(collect_until(:turn_end))

    assert Enum.map(results, &{&1.is_error, Message.text(&1)}) == [
             {true, "aborted"},
             {true, "aborted"}
           ]

    for id <- [one, two], do: assert({:ok, _path, %{"parent" => _}} = Scan.find(dir, id))
  end

  test "a stop of the parent session ends the child", %{core: core, tmp_dir: dir} do
    session = parent(core, dir, [[agent("c1")], block()])
    assert_receive {:blocked, id}
    pid = child_pid(core, id)
    ref = Process.monitor(pid)

    :ok = Helyx.Sessions.stop(session)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  # The child's stop leaves `:kept` held, so its owner's report is not
  # `:ok`, and the release keeps the child held in the parent (#752).
  test "a stop of the parent reports a child whose stop left a handle held", %{
    core: core,
    tmp_dir: dir
  } do
    kept = [%ToolCall{id: "k1", name: "kept", arguments: %{"to" => Helyx.Test.Gate.open()}}]
    session = parent(core, dir, [[agent("c1")], kept])
    assert_receive {:blocked, id}
    pid = child_pid(core, id)
    ref = Process.monitor(pid)

    {result, log} = with_log(fn -> Helyx.Sessions.stop(session) end)
    assert {:error, {:not_released, [{%Session{id: ^id}, _owner}]}} = result
    assert log =~ ":kept"
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  test "a Core stop ends the child", %{core: core, tmp_dir: dir} do
    _session = parent(core, dir, [[agent("c1")], block()])
    assert_receive {:blocked, id}
    pid = child_pid(core, id)
    ref = Process.monitor(pid)

    :ok = stop_supervised(core)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  test "a child that ends by itself gives an error result", %{core: core, tmp_dir: dir} do
    _session = parent(core, dir, [[agent("c1")], block(), ["Done."]])
    assert_receive {:blocked, id}

    Process.exit(child_pid(core, id), :kill)
    [result] = results(collect_until(:turn_end))
    assert result.is_error
    # A killed child has no stop report, so the child stays held (#752).
    assert Message.text(result) == "a resource of the call could not be released"
  end

  test "the cleanup of a call stops only its child, not a later instance of the id", %{
    core: core,
    tmp_dir: dir
  } do
    blocked = block()
    _session = parent(core, dir, [[agent("c1")], blocked, blocked, ["Done."]])
    assert_receive {:blocked, id}
    pid = child_pid(core, id)
    ref = Process.monitor(pid)

    # The owner holds its cleanup while the child ends and a resume starts
    # a new instance of the id with work of its own.
    [owner] =
      for task <- Task.Supervisor.children(Helyx.Core.task_supervisor(core)),
          {:dictionary, dict} <- [Process.info(task, :dictionary)],
          match?({Helyx.Tool.Agent, _, _}, dict[:"$initial_call"]),
          do: task

    true = :erlang.suspend_process(owner)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    {:ok, replacement} = Helyx.Sessions.resume(core, id: id)
    :ok = Session.prompt(replacement, "more")
    assert_receive {:blocked, ^id}
    new_pid = Session.pid(replacement)

    true = :erlang.resume_process(owner)
    [result] = results(collect_until(:turn_end))
    # The killed child has no stop report, so it stays held (#752).
    assert Message.text(result) == "a resource of the call could not be released"
    # The parent's result comes after the cleanup of the owner, so a stop of
    # the new instance would have ended it by now.
    assert Process.alive?(new_pid)
    assert [%{status: :running}] = for(i <- Helyx.Sessions.list_live(core), i.id == id, do: i)
  end

  test "a parent that crashes takes no release, and the owner stops the child", %{
    core: core,
    tmp_dir: dir
  } do
    session = parent(core, dir, [[agent("c1")], block()])
    assert_receive {:blocked, id}
    pid = child_pid(core, id)
    ref = Process.monitor(pid)

    Process.exit(Session.pid(session), :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  test "a child that the Core cap refuses gives an error result, and the parent goes on", %{
    core: core,
    tmp_dir: dir
  } do
    for _ <- 1..63, do: {:ok, _} = Helyx.Sessions.start(core, model: "fake/echo", cwd: dir)
    _session = parent(core, dir, [[agent("c1")], ["Done."]])
    events = collect_until(:turn_end)

    assert [result] = results(events)
    assert result.is_error
    assert Message.text(result) =~ "do this task yourself"
    assert Message.text(List.last(messages(events))) == "Done."
  end

  test "a call id over 256 bytes gives an error result and starts no session", %{
    core: core,
    tmp_dir: dir
  } do
    session = parent(core, dir, [[agent(String.duplicate("a", 257))], ["Done."]])
    [result] = results(collect_until(:turn_end))

    assert result.is_error
    assert Message.text(result) == "agent: the session did not start: :invalid_parent"
    assert Helyx.Sessions.list_live(core) |> Enum.map(& &1.id) == [session.id]
  end

  test "bad arguments give an error result and start no session", %{core: core, tmp_dir: dir} do
    call = %ToolCall{id: "c1", name: "agent", arguments: %{"description" => "x", "prompt" => 1}}
    session = parent(core, dir, [[call], ["Done."]])
    [result] = results(collect_until(:turn_end))

    assert result.is_error
    assert Message.text(result) == "agent needs a description and a prompt, both strings"
    assert Helyx.Sessions.list_live(core) |> Enum.map(& &1.id) == [session.id]
  end
end
