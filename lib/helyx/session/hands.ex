defmodule Helyx.Session.Hands do
  @moduledoc """
  Runs tool calls for one session in one working directory, as Tasks
  linked to the hands (ADR 0003, ADR 0004). The session starts the hands
  and addresses it by pid.

  The result of a call goes to the session as `{:tool_result, turn_id,
  call_id, {:ok, text} | {:error, text}}`. A Task that dies without a
  result gives an error result, unless a cancel request killed it. A
  working directory that is gone when the call starts also gives an error
  result. Result text is valid UTF-8 when it leaves the hands: each
  invalid sequence is replaced with U+FFFD.

  A tool holds each OS resource that it creates with `Helyx.Tool.hold/1`.
  When a call ends, however its Task ended, the hands call the tool's
  `release/3` with the handles of the Task, if it holds any. The result
  goes to the session after the release. While a handle is unconfirmed,
  the hands refuse tool calls with an error result.
  `request_cancel/2` kills the Tasks of a turn and releases their handles.
  Its answer names the handles that stay unconfirmed. The rules and the
  deadlines are in `docs/features/tool-resource-release.md`.

  `start_provider/3` starts the provider process (ADR 0007) with an armed
  kill. When the provider process ends, the hands release its handles and
  send `{:provider_down, pid, reason}`. The deadlines and the reasons are in
  `docs/features/long-lived-harness.md`, sections "Deadlines", "Bounds",
  and "Built in #199", with the old names of
  `docs/features/one-provider-path.md`, section "Renames".
  """

  use GenServer

  # The release deadline of a retry, for all tools together.
  @retry_ms 1_000

  alias Helyx.Message.ToolCall

  defmodule State do
    @moduledoc false
    # `tools` is the tool module by name. `tasks` holds each running Task,
    # its turn, its call id, and its tool module, by monitor ref. `held`
    # holds the handles per Task pid. `unconfirmed` holds the handles that
    # no release confirmed, per tool module. `release_ms` is the release
    # deadline of a delivery or a cancel, and `connect_ms` the armed kill of
    # a provider process: seams for tests.
    @enforce_keys [:core, :cwd, :session, :tools]

    # The default release deadline, the one source (`Helyx.Session.Server.Stop`
    # derives its stop bounds from it).
    @release_ms 20_000
    def release_ms, do: @release_ms

    defstruct [
      :core,
      :cwd,
      :session,
      :tools,
      tasks: %{},
      held: %{},
      unconfirmed: %{},
      release_ms: @release_ms,
      connect_ms: 30_000
    ]
  end

  @doc """
  Starts the hands for a session. Takes `core:`, `cwd:`, `session:`, and
  `tools:`, the tool module by name, from the specs the session checked
  with `Helyx.Tool.specs/1`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, struct!(State, opts))

  @doc """
  Starts a tool call. The result is sent to the session. A cast: a turn
  runs Helyx tools while the hands can release its provider process.
  """
  @spec run(pid(), String.t(), ToolCall.t()) :: :ok
  def run(hands, turn_id, %ToolCall{} = call), do: GenServer.cast(hands, {:run, turn_id, call})

  @doc """
  Starts the provider process: `fun` gets the ref of the armed connect kill
  and runs in a Task of the hands with no turn. Returns its pid, or an error
  text while a handle is unconfirmed.
  """
  @spec start_provider(pid(), module(), (:timer.tref() -> term())) ::
          {:ok, pid()} | {:error, String.t()}
  def start_provider(hands, provider, fun) when is_function(fun, 1),
    do: GenServer.call(hands, {:start_provider, provider, fun})

  @doc """
  Asks the hands to cancel the turn's Tasks and release
  their handles. Sends the request and returns at once, so the caller stays
  free during the release. Read the answer with
  `:gen_server.check_response/2` or `:gen_server.receive_response/2`: `:ok`
  when every release has returned, or an error naming the unconfirmed
  handles.
  """
  @spec request_cancel(pid(), String.t()) :: :gen_server.request_id()
  def request_cancel(hands, turn_id), do: :gen_server.send_request(hands, {:cancel, turn_id})

  @doc """
  Kills the running tool Task of one call, when there is one. Its
  delivery runs as for any Task that dies: the release, then an error
  result to the session. A cast, as `run/3`: the session does not wait
  for a release.
  """
  @spec kill(pid(), String.t(), String.t()) :: :ok
  def kill(hands, turn_id, call_id), do: GenServer.cast(hands, {:kill, turn_id, call_id})

  @impl true
  def init(%State{} = state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call({:start_provider, provider, fun}, _from, state) do
    state = retry(state)

    if state.unconfirmed == %{} do
      # The kill is armed at the OTP timer server as the Task's first act;
      # `fun` gets the timer ref, before any plugin code runs.
      ms = state.connect_ms

      {pid, state} =
        spawn_task(state, nil, :provider, provider, fn ->
          {:ok, tref} = :timer.kill_after(ms)
          fun.(tref)
        end)

      {:reply, {:ok, pid}, state}
    else
      {:reply, {:error, refusal(state)}, state}
    end
  end

  # A handle from a Task that was already killed is dropped: the tool frees
  # the resource when its Task dies (see `Helyx.Tool.hold/1`). A tool with
  # no `release/3` gets `:no_release`, and `Helyx.Tool.hold/1` raises in its
  # Task.
  def handle_call({:hold, handle}, {pid, _tag}, state) do
    case Enum.find_value(state.tasks, fn {_ref, {task, _, _, tool}} -> task.pid == pid && tool end) do
      nil ->
        {:reply, :ok, state}

      tool ->
        if function_exported?(tool, :release, 3) do
          held = Map.update(state.held, pid, [handle], &[handle | &1])
          {:reply, :ok, %{state | held: held}}
        else
          {:reply, :no_release, state}
        end
    end
  end

  def handle_call({:cancel, turn_id}, _from, state) do
    {cancelled, kept} =
      Map.split_with(state.tasks, fn {_ref, {_task, id, _call_id, _tool}} -> id == turn_id end)

    cancelled = Map.values(cancelled)

    Enum.each(cancelled, fn {task, _turn, _call_id, _tool} ->
      Task.shutdown(task, :brutal_kill)
    end)

    {taken, held} = Map.split(state.held, Enum.map(cancelled, fn {task, _, _, _} -> task.pid end))

    by_tool =
      Enum.reduce(cancelled, %{}, fn {task, _, _, tool}, acc ->
        add_handles(acc, %{tool => Map.get(taken, task.pid, [])})
      end)

    left = release(by_tool, :cancel, state.release_ms, state.core)
    state = %{state | tasks: kept, held: held, unconfirmed: add_handles(state.unconfirmed, left)}

    {:reply, unconfirmed_error(left) || :ok, state}
  end

  @impl true
  def handle_cast({:run, turn_id, call}, state) do
    state = retry(state)

    state =
      if state.unconfirmed == %{},
        do: start(state, turn_id, call),
        else: refuse(state, turn_id, call.id)

    {:noreply, state}
  end

  def handle_cast({:kill, turn_id, call_id}, state) do
    for {_ref, {task, ^turn_id, ^call_id, _tool}} <- state.tasks,
        do: Process.exit(task.pid, :kill)

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, %State{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, deliver(ref, result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {:noreply, deliver(ref, {:exit, reason}, state)}
  end

  # A Task's exit signal (its reply or :DOWN carries the outcome), or a
  # reply or :DOWN for a Task that was already delivered. The session's exit
  # never lands here: it is the parent, and a trapped parent exit stops the
  # GenServer before handle_info.
  def handle_info(_message, state), do: {:noreply, state}

  # The hands stop only for a trapped reason; on an untrappable kill the
  # links do the same work. Each tool frees its resources when its Task dies
  # (see `Helyx.Tool.hold/1`).
  @impl true
  def terminate(_reason, state) do
    for {_ref, {task, _turn, _call, _tool}} <- state.tasks, do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  # No resource survives its call: the handles are released when the result
  # delivers, however the Task ended, and the result waits until the
  # release returns, so the next call cannot overlap a dying one. A handle
  # the release does not confirm makes the result an error.
  defp deliver(ref, result, state) do
    {{task, turn_id, call_id, tool}, tasks} = Map.pop!(state.tasks, ref)
    {handles, held} = Map.pop(state.held, task.pid, [])
    left = release(%{tool => handles}, :deliver, state.release_ms, state.core)

    send(state.session, outcome(turn_id, call_id, task.pid, unconfirmed_error(left) || result))

    %{state | tasks: tasks, held: held, unconfirmed: add_handles(state.unconfirmed, left)}
  end

  defp outcome(_turn_id, :provider, pid, result), do: {:provider_down, pid, down_reason(result)}
  defp outcome(turn_id, id, _pid, result), do: outcome(turn_id, id, result)

  # The reason of a provider process's end, capped like a crash reason. A
  # kill is the armed kill of a request that got no answer in time. The
  # loop ends with `{:shutdown, reason}` (L1). An unconfirmed handle stays
  # in `unconfirmed` and refuses the next start.
  defp down_reason({:exit, :killed}), do: :provider_timeout
  defp down_reason({:exit, {:shutdown, reason}}), do: Helyx.Message.cap_integers(reason)
  defp down_reason({:exit, reason}), do: {:task_exit, Helyx.Message.cap_integers(reason)}
  defp down_reason({:error, _unconfirmed} = error), do: error

  defp outcome(turn_id, call_id, {:exit, reason}),
    do: outcome(turn_id, call_id, {:error, "tool crashed: #{inspect(reason)}"})

  # Every result leaves the hands through here, so text is made valid once,
  # for the ok, error, crash, and catch paths alike.
  defp outcome(turn_id, call_id, result),
    do: {:tool_result, turn_id, call_id, Helyx.Message.scrub(result)}

  defp start(state, turn_id, %ToolCall{} = call) do
    tool = if File.dir?(state.cwd), do: Map.get(state.tools, call.name, :unknown), else: :no_cwd
    cwd = state.cwd
    {_pid, state} = spawn_task(state, turn_id, call.id, tool, fn -> run_tool(tool, call, cwd) end)
    state
  end

  # `id` is the call id or `:provider`; `module` is the tool or
  # the provider whose `release/3` gets the Task's handles.
  defp spawn_task(state, turn_id, id, module, fun) do
    hands = self()

    task =
      Task.Supervisor.async(Helyx.Core.task_supervisor(state.core), fn ->
        Process.put(:helyx_hands, hands)
        fun.()
      end)

    {task.pid, %{state | tasks: Map.put(state.tasks, task.ref, {task, turn_id, id, module})}}
  end

  defp refuse(state, turn_id, id) do
    send(state.session, outcome(turn_id, id, {:error, refusal(state)}))
    state
  end

  defp refusal(state) do
    "a resource from an earlier call could not be released " <>
      "(#{handles_text(state.unconfirmed)}); the call was not run"
  end

  # Gives every unconfirmed handle to its tool again, with one short
  # deadline for all tools, and keeps the ones still held.
  defp retry(state),
    do: %{state | unconfirmed: release(state.unconfirmed, :retry, @retry_ms, state.core)}

  # Calls `release/3` of each tool with its handles, one Task per tool, in
  # parallel, with one deadline. A Task that is still running at the
  # deadline is killed, and the wait returns only when it is gone. Returns
  # the handles still held, per tool. A reply that arrives before the kill
  # counts, because the release did return. A release that raises, exits, times
  # out, or returns anything but a proper list of given handles confirms
  # none of them. A tool with no handles gets no call.
  defp release(by_tool, mode, ms, core) do
    deadline = System.monotonic_time(:millisecond) + ms
    supervisor = Helyx.Core.task_supervisor(core)

    tasks =
      for {tool, handles} <- by_tool, handles != [] do
        {tool, handles,
         Task.Supervisor.async(supervisor, tool, :release, [handles, mode, deadline])}
      end

    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    results =
      Task.yield_many(Enum.map(tasks, &elem(&1, 2)), timeout: timeout, on_timeout: :kill_task)

    for {{tool, handles, _task}, {_task2, result}} <- Enum.zip(tasks, results),
        left = still_held(result, handles),
        left != [],
        into: %{},
        do: {tool, left}
  end

  defp still_held({:ok, left}, handles) when is_list(left) do
    if List.improper?(left) or left -- handles != [], do: handles, else: left
  end

  defp still_held(_failed, handles), do: handles

  defp add_handles(a, b), do: Map.merge(a, b, fn _tool, x, y -> x ++ y end)

  defp unconfirmed_error(left) when left == %{}, do: nil

  defp unconfirmed_error(left),
    do: {:error, "a resource of the call could not be released (#{handles_text(left)})"}

  defp handles_text(by_tool) do
    by_tool
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.map(&inspect/1)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp run_tool(:unknown, call, _cwd), do: {:error, "unknown tool: #{call.name}"}
  defp run_tool(:no_cwd, _call, cwd), do: {:error, "working directory does not exist: #{cwd}"}

  defp run_tool(tool, call, cwd) do
    case tool.run(call.arguments, cwd) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:error, text} when is_binary(text) -> {:error, text}
      other -> {:error, "tool #{call.name} returned #{inspect(other)}"}
    end
  catch
    kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end
end
