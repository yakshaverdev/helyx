defmodule Helyx.Session.Hands do
  @moduledoc """
  Runs tool calls for one session in one working directory, as Tasks
  linked to the hands (ADR 0003, ADR 0004). The session starts the hands
  and addresses it by pid.

  The result of a call goes to the session as `{:tool_result, turn_id,
  call_id, {:ok, text} | {:error, text}}`. A Task that dies without a
  result gives an error result, unless a cancel request killed it. An
  unknown tool gives an error result and starts no Task. The hands do not
  check the working directory: a tool fails at its own use of a missing
  path (`docs/features/tool-text-out-of-core.md`, item 4). Result text
  leaves the hands through `Helyx.Message.cut_result/1`: valid UTF-8 and
  at most `Helyx.Message.max_result_bytes/0` bytes, notice included. The
  text of a tool that crashes, raises, throws, or exits is
  `Helyx.Reason.text/1` of its reason; a return outside the contract and
  a handle that is not released give a fixed text. The log gets the term.

  A tool holds each OS resource that it creates with `Helyx.Tool.hold/1`,
  and drops a handle whose resource it released itself with
  `Helyx.Tool.unhold/1`.
  When a call ends, however its Task ended, the hands call the tool's
  `release/3` with the handles of the Task, if it holds any. The result
  goes to the session after the release. An unconfirmed handle gets no
  second release: from then on, the hands refuse tool calls with an error
  result, and provider starts with an error.
  `request_cancel/2` kills the Tasks of a turn and releases their handles.
  Its answer is a fixed error text when a handle stays unconfirmed, and
  the log names the handles. The rules and the
  deadlines are in `docs/features/tool-resource-release.md`.

  A tool call can go on in the background (`Helyx.Tool.background/0`,
  `Helyx.Tool.started/1`): its start answer is a `{:started, text}` result, and
  its Task leaves its turn, out of reach of `request_cancel/2`.
  Its end follows its release as `{:background_end, message}`, and its place
  stays taken until `taken/2` (`docs/features/background-bash.md`).

  `start_provider/3` starts the provider process (ADR 0007) with an armed
  kill. When the provider process ends, the hands release its handles and
  send `{:provider_down, pid, reason}`. The deadlines and the reasons are in
  `docs/features/session-lifecycle.md`, sections "Deadlines", "Bounds",
  and "Provider death".
  """

  use GenServer

  alias Helyx.Message.ToolCall
  alias Helyx.Session.Background
  alias Helyx.Session.Hands.{Release, Run}

  defmodule State do
    @moduledoc false
    # `tools` is the tool module by name. `tasks` holds each running Task,
    # its turn, its call id, its tool module, and its place, by monitor
    # ref: a background Task has no turn and `{:background, id}` for its
    # call id. The place is the id of the run from `background/0` to the end
    # of the Task, else nil. `background` holds the ends that no turn took
    # (`Helyx.Session.Background`); `background_dir` is the background
    # folder. `held` holds the handles per Task pid.
    # `unconfirmed` holds the handles that no release confirmed, per tool
    # module. `release_ms` is
    # the release deadline of a delivery or a cancel, and `connect_ms` the
    # armed kill of a provider process: seams for tests.
    @enforce_keys [:core, :cwd, :background_dir, :session, :tools]

    # The default release deadline, the one source (`Helyx.Session.Server.Stop`
    # derives its stop bounds from it).
    @release_ms 20_000
    def release_ms, do: @release_ms

    defstruct [
      :core,
      :cwd,
      :background_dir,
      :session,
      :tools,
      tasks: %{},
      background: %Background{},
      held: %{},
      unconfirmed: %{},
      release_ms: @release_ms,
      connect_ms: 30_000
    ]
  end

  @doc """
  Starts the hands for a session. Takes `core:`, `cwd:`,
  `background_dir:`, the folder of the background output files,
  `session:`, and `tools:`, the tool module by name, from the specs the
  session checked with `Helyx.Tool.specs/1`.
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
  text once a handle is unconfirmed.
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
  when every release has returned, or an error with a fixed text when a
  handle stays unconfirmed; the log names the handles.
  """
  @spec request_cancel(pid(), String.t()) :: :gen_server.request_id()
  def request_cancel(hands, turn_id), do: :gen_server.send_request(hands, {:cancel, turn_id})

  @doc """
  Frees the place of the background run `id`, whose end a turn took. An id
  with no place, such as one of a lost run, changes nothing. A cast, as
  `run/3`, and in its order: the next call sees the place free.
  """
  @spec taken(pid(), String.t()) :: :ok
  def taken(hands, id), do: GenServer.cast(hands, {:taken, id})

  @impl true
  def init(%State{} = state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call({:start_provider, provider, fun}, _from, state) do
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
      {:reply, {:error, refusal()}, state}
    end
  end

  # A handle from a Task that was already killed is dropped: the tool frees
  # the resource when its Task dies (see `Helyx.Tool.hold/1`). A tool with
  # no `release/3` gets `:no_release`, and `Helyx.Tool.hold/1` raises in its
  # Task.
  def handle_call({:hold, handle}, {pid, _tag}, state) do
    case Enum.find_value(state.tasks, fn {_ref, {task, _, _, tool, _}} ->
           task.pid == pid && tool
         end) do
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

  # The caller released these handles itself (`Helyx.Tool.unhold/1`).
  def handle_call({:unhold, handles}, {pid, _tag}, state),
    do: {:reply, :ok, %{state | held: Map.replace_lazy(state.held, pid, &(&1 -- handles))}}

  # A place among the background runs, for a tool call Task. The live
  # runs are the other Tasks with a place: a second call of the Task keeps
  # its own place, so the limit does not count it.
  def handle_call(:background, {pid, _tag}, state) do
    with {ref, entry} <- tool_call(state, pid),
         live = Enum.count(state.tasks, fn {r, e} -> r != ref and elem(e, 4) != nil end),
         {:ok, id} <- Background.reserve(state.background, live, state.background_dir) do
      tasks = Map.put(state.tasks, ref, put_elem(entry, 4, id))
      {:reply, {:ok, %{id: id, dir: state.background_dir}}, %{state | tasks: tasks}}
    else
      nil -> {:reply, {:error, "only a tool call can run in the background"}, state}
      error -> {:reply, error, state}
    end
  end

  # The start answer of a background run: the result of its call, and its
  # Task leaves the turn. Any other caller gets `:no_place`; a Task that a
  # cancel killed gets no reply.
  def handle_call({:started, text}, {pid, _tag}, state) do
    case tool_call(state, pid) do
      {ref, {task, turn_id, call_id, tool, id}} when id != nil ->
        send(state.session, outcome(turn_id, call_id, {:started, Background.start(id, text)}))
        tasks = Map.put(state.tasks, ref, {task, nil, {:background, id}, tool, id})
        {:reply, :ok, %{state | tasks: tasks}}

      _no_place ->
        {:reply, :no_place, state}
    end
  end

  def handle_call({:cancel, turn_id}, _from, state) do
    {cancelled, kept} =
      Map.split_with(state.tasks, fn {_ref, {_task, id, _call_id, _tool, _place}} ->
        id == turn_id
      end)

    cancelled = Map.values(cancelled)
    pids = Enum.map(cancelled, fn {task, _, _, _, _} -> task.pid end)

    Enum.each(cancelled, fn {task, _turn, _call_id, _tool, _place} ->
      Task.shutdown(task, :brutal_kill)
    end)

    {taken, held} = Map.split(state.held, pids)

    by_tool =
      Enum.reduce(cancelled, %{}, fn {task, _, _, tool, _}, acc ->
        Release.add(acc, %{tool => Map.get(taken, task.pid, [])})
      end)

    left = Release.run(by_tool, :cancel, state.release_ms, state.core)

    # A Task killed here never delivers; its place leaves with its entry.
    state = %{state | tasks: kept, held: held, unconfirmed: Release.add(state.unconfirmed, left)}

    {:reply, Release.error(left) || :ok, state}
  end

  @impl true
  def handle_cast({:run, turn_id, call}, state) do
    state =
      if state.unconfirmed == %{},
        do: start(state, turn_id, call),
        else: answer(state, turn_id, call.id, refusal())

    {:noreply, state}
  end

  def handle_cast({:taken, id}, state),
    do: {:noreply, %{state | background: Background.taken(state.background, id)}}

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
    for {_ref, {task, _, _, _, _}} <- state.tasks, do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  # No resource survives its Task: the handles are released when the result
  # delivers, however the Task ended, and the result waits until the
  # release returns, so the next call cannot overlap a dying one. A handle
  # the release does not confirm makes the result an error.
  defp deliver(ref, result, state) do
    {{task, turn_id, call_id, tool, _place}, tasks} = Map.pop!(state.tasks, ref)
    {handles, held} = Map.pop(state.held, task.pid, [])
    left = Release.run(%{tool => handles}, :deliver, state.release_ms, state.core)

    send(state.session, outcome(turn_id, call_id, task.pid, Release.error(left) || result))

    %{
      state
      | tasks: tasks,
        held: held,
        background: Background.ended(state.background, call_id),
        unconfirmed: Release.add(state.unconfirmed, left)
    }
  end

  defp outcome(_turn_id, :provider, pid, result), do: {:provider_down, pid, down_reason(result)}

  defp outcome(nil, {:background, id}, _pid, result),
    do: {:background_end, Background.end_message(id, checked(result))}

  defp outcome(turn_id, id, _pid, result), do: outcome(turn_id, id, result)

  # The reason of a provider process's end. `Helyx.Reason` caps its
  # integers when it makes the text and the log line. A kill is the armed
  # kill of a request that got no answer in time. The loop ends with
  # `{:shutdown, reason}` (L1). An unconfirmed handle stays in
  # `unconfirmed` and refuses the next start.
  defp down_reason({:exit, :killed}), do: :provider_timeout
  defp down_reason({:exit, {:shutdown, reason}}), do: reason
  defp down_reason({:exit, reason}), do: {:task_exit, reason}
  defp down_reason({:error, _text} = error), do: error

  defp outcome(turn_id, call_id, result), do: {:tool_result, turn_id, call_id, checked(result)}

  # A crash of the Task: the log gets its reason, the result its text.
  defp checked({:exit, reason}) do
    Helyx.Reason.log("tool crashed", reason)
    checked({:error, "tool crashed: " <> Helyx.Reason.text(reason)})
  end

  # Every result and background end leaves the hands through here, so text
  # is made valid and cut to the limit once, for the ok, error, crash,
  # refusal, and catch paths alike.
  defp checked({status, text}), do: {status, Helyx.Message.cut_result(text)}

  # A fixed error needs no Task: it is answered at once, as a refusal is.
  defp start(state, turn_id, %ToolCall{} = call) do
    cwd = state.cwd

    case Map.fetch(state.tools, call.name) do
      :error ->
        answer(state, turn_id, call.id, "unknown tool: #{call.name}")

      {:ok, tool} ->
        {_pid, state} =
          spawn_task(state, turn_id, call.id, tool, fn -> Run.tool(tool, call, cwd) end)

        state
    end
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

    {task.pid, %{state | tasks: Map.put(state.tasks, task.ref, {task, turn_id, id, module, nil})}}
  end

  defp answer(state, turn_id, id, text) do
    send(state.session, outcome(turn_id, id, {:error, text}))
    state
  end

  # The entry of the turn Task `pid` of a tool call, or nil.
  defp tool_call(state, pid) do
    Enum.find(state.tasks, fn {_ref, {task, turn_id, _id, _tool, _place}} ->
      task.pid == pid and turn_id != nil
    end)
  end

  # The handles went to the log when they became unconfirmed.
  defp refusal, do: "a resource from an earlier call could not be released; the call was not run"
end
