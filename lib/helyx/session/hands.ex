defmodule Helyx.Session.Hands do
  @moduledoc """
  Runs tool calls for one session in one working directory, as Tasks linked
  to the hands (ADR 0003, ADR 0004).

  A result goes to the session as `{:tool_result, turn_id, call_id,
  {status, text}}`, or `{status, text, ui_blocks}` with the UI blocks of the
  tool (docs/features/ui-blocks.md); an unknown tool gives an error result
  and starts no Task. The hands call the tool's `release/3` with the handles
  of a Task when the call ends, however it ended
  (docs/features/tool-resource-release.md).

  A provider start answers as `{:provider_start, ref, {:ok, pid} | {:error,
  text}}` and its process end as `{:provider_down, pid, reason}` (ADR 0007).
  """

  use GenServer

  alias Helyx.Message.ToolCall
  alias Helyx.Session.Ask
  alias Helyx.Session.Background

  alias Helyx.Session.Hands.{
    Approval,
    Chain,
    End,
    Entry,
    Hooks,
    Outcome,
    Release,
    Settle,
    Sources,
    State
  }

  @doc """
  Starts the hands for a session, with `core:`, `cwd:`, `background_dir:`,
  `session:`, `tools:`, and `hooks:`, the hook modules and their limits of each
  point (`Helyx.Core.hooks/1`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, struct!(State, opts))

  @doc """
  Starts a tool call with the map of `Helyx.Tool.context/0`; the hands add the
  Core, the tool names, the called tool, its source, and the call id. A cast.
  """
  @spec run(pid(), String.t(), ToolCall.t(), map()) :: :ok
  def run(hands, turn_id, %ToolCall{} = call, context),
    do: GenServer.cast(hands, {:run, turn_id, call, context})

  @doc """
  Starts the provider process: `fun` gets the ref of the armed connect kill and
  runs in a Task of the hands. The answer comes as
  `{:provider_start, ref, {:ok, pid}}`, or with an error text once a handle is
  unconfirmed.
  """
  @spec start_provider(pid(), module(), (:timer.tref() -> term())) :: reference()
  def start_provider(hands, provider, fun) when is_function(fun, 1) do
    ref = make_ref()
    GenServer.cast(hands, {:start_provider, ref, provider, fun})
    ref
  end

  @doc """
  Asks the hands to cancel the turn's call Tasks and release their handles; a
  background run of the turn stays (docs/features/background-bash.md). Read the
  answer with `:gen_server.check_response/2` or
  `:gen_server.receive_response/2`: `:ok`, or an error with a fixed text when
  a handle stays unconfirmed.
  """
  @spec request_cancel(pid(), String.t()) :: :gen_server.request_id()
  def request_cancel(hands, turn_id), do: :gen_server.send_request(hands, {:cancel, turn_id})

  @doc """
  Asks the hands to revoke the turn: cancel its call Tasks and its background
  runs, and release their handles. The answer is `{:revoked, ids, error}`
  (ADR 0014, invariant 4).
  """
  @spec request_revoke(pid(), String.t()) :: :gen_server.request_id()
  def request_revoke(hands, turn_id), do: :gen_server.send_request(hands, {:revoke, turn_id})

  @doc """
  Stops the hands with `:shutdown`: every Task ends, and its handles get a
  release with `:cancel` by `deadline` (monotonic ms). The answer is every
  handle that a release left unconfirmed
  (docs/features/tool-resource-release.md).
  """
  @spec stop(pid(), integer(), timeout()) :: [term()]
  def stop(hands, deadline, timeout), do: GenServer.call(hands, {:stop, deadline}, timeout)

  @doc """
  Frees the place of the background run `id`, whose end a turn took. An id with
  no place changes nothing. A cast, as `run/4`
  (docs/features/background-bash.md).
  """
  @spec taken(pid(), String.t()) :: :ok
  def taken(hands, id), do: GenServer.cast(hands, {:taken, id})

  # Every callback but `init/1` runs in `Helyx.Reason.no_args/1`, so a crash
  # report shows no state and no message
  # (docs/features/session-lifecycle.md).
  @impl true
  def init(%State{} = state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call(request, from, state),
    do: Helyx.Reason.no_args(fn -> call(request, from, state) end)

  @impl true
  def handle_cast(request, state), do: Helyx.Reason.no_args(fn -> cast(request, state) end)

  @impl true
  def handle_info(message, state), do: Helyx.Reason.no_args(fn -> info(message, state) end)

  @impl true
  def format_status(status), do: Helyx.Reason.crash_status(status)

  # A handle from a Task that was already killed is dropped: the tool frees the
  # resource when its Task dies (`Helyx.Tool.hold/1`). A tool with no
  # `release/3` gets `:no_release`, and `Helyx.Tool.hold/1` raises in its Task.
  defp call({:hold, handle}, {pid, _tag}, state) do
    case State.holding(state, pid) do
      nil ->
        {:reply, :ok, state}

      {ref, entry} ->
        if function_exported?(entry.tool, :release, 3) do
          {:reply, :ok, State.put(state, ref, %{entry | handles: [handle | entry.handles]})}
        else
          {:reply, :no_release, state}
        end
    end
  end

  # The caller released these handles itself (`Helyx.Tool.unhold/1`).
  defp call({:unhold, handles}, {pid, _tag}, state) do
    case State.task(state, pid) do
      nil ->
        {:reply, :ok, state}

      {ref, entry} ->
        {:reply, :ok, State.put(state, ref, %{entry | handles: entry.handles -- handles})}
    end
  end

  # The live runs are the other Tasks with a place: a second call of the Task
  # keeps its own place, so the limit does not count it.
  defp call(:background, {pid, _tag}, state) do
    with {ref, %Entry{kind: kind} = entry} <- State.tool_call(state, pid),
         {:ok, id} <-
           Background.reserve(state.background, State.live_runs(state, ref), state.background_dir) do
      {:reply, {:ok, %{id: id, dir: state.background_dir}},
       State.put(state, ref, %{entry | kind: placed(kind, id)})}
    else
      nil -> {:reply, {:error, "only a tool call can run in the background"}, state}
      error -> {:reply, error, state}
    end
  end

  # The start answer of a background run: the result of its call. The Task
  # leaves its turn but keeps its id, so the abort or the failure of the turn
  # can revoke the run. A Task that a cancel killed gets no reply.
  defp call({:started, {status, text}}, {pid, _tag}, state) do
    case State.tool_call(state, pid) do
      {ref, %Entry{kind: {:placed, _call_id, id}} = entry} ->
        result = {:started, {status, Background.start(id, text)}, pid}
        send(state.session, Outcome.of(entry, result))
        {:reply, :ok, State.put(state, ref, %{entry | kind: {:run, id}})}

      _no_place ->
        {:reply, :no_place, state}
    end
  end

  # A hook of the chain of the calling call or chain Task (`Hooks`); the answer
  # comes after the release of the hook's handles.
  defp call({:hook, request}, {pid, _tag} = from, state),
    do: {:noreply, Hooks.start(state, from, pid, request)}

  # The background runs of the turn keep their lease for a revoke.
  defp call({:cancel, turn_id}, _from, state) do
    refs =
      for {ref, %Entry{turn_id: ^turn_id, kind: kind}} <- state.tasks,
          not match?({:run, _id}, kind),
          do: ref

    {left, state} = End.finish(state, refs, :cancel, state.release_ms, true)
    {:reply, Release.error(left) || :ok, state}
  end

  # The abort or the failure of the turn revokes the lease of its background
  # runs: each Task ends, its handles get a release with `:cancel`, and its end
  # never arrives, so no later turn takes it (ADR 0014, invariant 4). The ids
  # are the runs that gave their start answer, the ones the session counts; a
  # Task that a release left unconfirmed is still answered.
  defp call({:revoke, turn_id}, _from, state) do
    refs = for {ref, %Entry{turn_id: ^turn_id}} <- state.tasks, do: ref
    ids = for {_ref, %Entry{turn_id: ^turn_id, kind: {:run, id}}} <- state.tasks, do: id
    {left, state} = End.finish(state, refs, :cancel, state.release_ms, true)
    {:reply, {:revoked, ids, Release.error(left)}, state}
  end

  # The stop of the session: no Task outlives the hands unreleased.
  defp call({:stop, deadline}, _from, state) do
    ms = max(deadline - System.monotonic_time(:millisecond), 0)
    {left, state} = End.finish(state, Map.keys(state.tasks), :cancel, ms, true)
    # The log gets each handle that stays held; the stop answers them.
    Release.error(left)
    {:stop, :shutdown, state.unconfirmed, state}
  end

  # The kind of a call Task that took its place from `background/0`.
  defp placed({:call, call_id}, id), do: {:placed, call_id, id}
  defp placed({:placed, call_id, _place}, id), do: {:placed, call_id, id}

  defp cast({:run, turn_id, call, context}, state) do
    state =
      if state.unconfirmed != [],
        do: answer(state, turn_id, call.id, Outcome.refusal()),
        else: start(state, turn_id, call, context)

    {:noreply, state}
  end

  defp cast({:start_provider, ref, provider, fun}, state) do
    {result, state} =
      if state.unconfirmed != [] do
        {{:error, Outcome.refusal()}, state}
      else
        # The kill is armed at the OTP timer server as the Task's first act;
        # `fun` gets the timer ref, before any plugin code runs.
        ms = state.connect_ms

        body = fn ->
          {:ok, tref} = :timer.kill_after(ms)
          fun.(tref)
        end

        {task, state} =
          spawn_task(state, :provider, nil, provider, fn ->
            Helyx.Reason.task("provider process crashed", body)
          end)

        {{:ok, task.pid}, state}
      end

    send(state.session, {:provider_start, ref, result})
    {:noreply, state}
  end

  defp cast({:settle, _ref, _turn_id, _input, _context} = request, state),
    do: {:noreply, Settle.start(state, request)}

  defp cast({:approve, _turn_id, _call, _context, _provider} = request, state),
    do: {:noreply, Approval.start(state, request)}

  defp cast({:source, request}, state), do: {:noreply, Sources.handle(request, state)}

  defp cast({:taken, id}, state),
    do: {:noreply, %{state | background: Background.taken(state.background, id)}}

  defp info({ref, result}, %State{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, End.deliver(ref, result, state)}
  end

  defp info({:DOWN, ref, :process, _pid, reason}, %State{tasks: tasks} = state)
       when is_map_key(tasks, ref) do
    {:noreply, End.deliver(ref, {:exit, reason}, state)}
  end

  # A Task's exit signal (its reply or :DOWN carries the outcome), or a reply or
  # :DOWN for a Task that was already delivered. The session's exit never lands
  # here: it is the parent, and a trapped parent exit stops the GenServer
  # before handle_info.
  defp info(_message, state), do: {:noreply, state}

  # Kills a provider Task that `Helyx.Reason.task/2` left trapping exits in its
  # crash log; the links end every other Task
  # (docs/features/tool-resource-release.md, rule 10).
  @impl true
  def terminate(_reason, state) do
    Helyx.Reason.no_args(fn ->
      for {_ref, %Entry{task: task}} <- state.tasks, do: Task.shutdown(task, :brutal_kill)
      :ok
    end)
  end

  # A fixed error needs no Task: it is answered at once, as a refusal is.
  defp start(state, turn_id, %ToolCall{} = call, context) do
    cwd = state.cwd
    hooks = state.hooks

    case Sources.lookup(state, call.name) do
      :error ->
        answer(state, turn_id, call.id, "unknown tool: #{call.name}")

      {:ok, tool} ->
        context =
          Map.merge(context, %{
            core: state.core,
            tools: Sources.names(state),
            source: Sources.pid(state, tool),
            tool: call.name,
            call_id: call.id
          })

        {_task, state} =
          spawn_task(state, {:call, call.id}, turn_id, tool, fn ->
            Process.put(:helyx_call, context)
            Ask.await_go()
            Chain.run(tool, call, cwd, turn_id, hooks)
          end)

        state
    end
  end

  @doc false
  # Spawns the Task of `kind` (`Helyx.Session.Hands.Entry`) for the turn
  # `turn_id`, which is nil for the three Tasks that no turn owns, and the
  # plugin `tool` whose `release/3` gets its handles, which is nil for a chain
  # Task.
  def spawn_task(state, kind, turn_id, tool, fun) do
    hands = self()
    session = state.session

    task =
      Task.Supervisor.async(Helyx.Core.task_supervisor(state.core), fn ->
        Process.put(:helyx_hands, hands)
        # For `Helyx.Tool.transcript/0`.
        Process.put(:helyx_session, session)
        fun.()
      end)

    # A call or hook Task waits for the session's go, which the session sends
    # once it handled this record (`Helyx.Session.Ask.await_go/0`).
    if asker = Ask.asker(kind), do: send(session, {:asker, turn_id, task.pid, asker})

    entry = %Entry{task: task, kind: kind, turn_id: turn_id, tool: tool}
    {task, State.put(state, task.ref, entry)}
  end

  defp answer(state, turn_id, id, text) do
    send(state.session, Outcome.tool_result(turn_id, id, {:error, text}))
    state
  end
end
