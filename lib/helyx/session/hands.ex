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
  a handle that is not released give a fixed text. The log gets the kind
  of the term, and the term of a handle that is not released.

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
  alias Helyx.Session.Hands.{Release, Run, State}

  @doc """
  Starts the hands for a session. Takes `core:`, `cwd:`,
  `background_dir:`, the folder of the background output files,
  `session:`, and `tools:`, the tool module by name, from the specs the
  session checked with `Helyx.Tool.specs/2`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, struct!(State, opts))

  @doc """
  Starts a tool call. `context` has the session id and the model of
  `Helyx.Tool.context/0`; the hands add the Core, the tool names, the
  name of the called tool, and the call id. The result is sent to the
  session. A cast: a turn runs Helyx tools while the hands can release its
  provider process.
  """
  @spec run(pid(), String.t(), ToolCall.t(), map()) :: :ok
  def run(hands, turn_id, %ToolCall{} = call, context),
    do: GenServer.cast(hands, {:run, turn_id, call, context})

  @doc """
  Starts the provider process: `fun` gets the ref of the armed connect kill
  and runs in a Task of the hands with no turn. A cast, as `run/4`: the
  hands can be busy with a release, and the caller stays free (#677).
  Returns a ref; the answer goes to the session as `{:provider_start, ref,
  {:ok, pid}}`, or with an error text once a handle is unconfirmed. It comes
  before the `provider_down` of the process.
  """
  @spec start_provider(pid(), module(), (:timer.tref() -> term())) :: reference()
  def start_provider(hands, provider, fun) when is_function(fun, 1) do
    ref = make_ref()
    GenServer.cast(hands, {:start_provider, ref, provider, fun})
    ref
  end

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
  `run/4`, and in its order: the next call sees the place free.
  """
  @spec taken(pid(), String.t()) :: :ok
  def taken(hands, id), do: GenServer.cast(hands, {:taken, id})

  # Every callback but `init/1` runs in `Helyx.Reason.no_args/1`, and a
  # crash report shows no state and no message
  # (docs/features/session-lifecycle.md, "Log and crash reports").
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

  # A handle from a Task that was already killed is dropped: the tool frees
  # the resource when its Task dies (see `Helyx.Tool.hold/1`). A tool with
  # no `release/3` gets `:no_release`, and `Helyx.Tool.hold/1` raises in its
  # Task.
  defp call({:hold, handle}, {pid, _tag}, state) do
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
  defp call({:unhold, handles}, {pid, _tag}, state),
    do: {:reply, :ok, %{state | held: Map.replace_lazy(state.held, pid, &(&1 -- handles))}}

  # A place among the background runs, for a tool call Task. The live
  # runs are the other Tasks with a place: a second call of the Task keeps
  # its own place, so the limit does not count it.
  defp call(:background, {pid, _tag}, state) do
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
  defp call({:started, text}, {pid, _tag}, state) do
    case tool_call(state, pid) do
      {ref, {task, turn_id, call_id, tool, id}} when id != nil ->
        send(state.session, outcome(turn_id, call_id, {:started, Background.start(id, text)}))
        tasks = Map.put(state.tasks, ref, {task, nil, {:background, id}, tool, id})
        {:reply, :ok, %{state | tasks: tasks}}

      _no_place ->
        {:reply, :no_place, state}
    end
  end

  defp call({:cancel, turn_id}, _from, state) do
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
    state = %{state | tasks: kept, held: held, unconfirmed?: state.unconfirmed? or left != %{}}

    {:reply, Release.error(left) || :ok, state}
  end

  defp cast({:run, turn_id, call, context}, state) do
    state =
      if state.unconfirmed?,
        do: answer(state, turn_id, call.id, refusal()),
        else: start(state, turn_id, call, context)

    {:noreply, state}
  end

  defp cast({:start_provider, ref, provider, fun}, state) do
    {result, state} =
      if state.unconfirmed? do
        {{:error, refusal()}, state}
      else
        # The kill is armed at the OTP timer server as the Task's first act;
        # `fun` gets the timer ref, before any plugin code runs.
        ms = state.connect_ms

        body = fn ->
          {:ok, tref} = :timer.kill_after(ms)
          fun.(tref)
        end

        {pid, state} =
          spawn_task(state, nil, :provider, provider, fn ->
            Helyx.Reason.task("provider process crashed", body)
          end)

        {{:ok, pid}, state}
      end

    send(state.session, {:provider_start, ref, result})
    {:noreply, state}
  end

  defp cast({:taken, id}, state),
    do: {:noreply, %{state | background: Background.taken(state.background, id)}}

  defp info({ref, result}, %State{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, deliver(ref, result, state)}
  end

  defp info({:DOWN, ref, :process, _pid, reason}, %State{tasks: tasks} = state)
       when is_map_key(tasks, ref) do
    {:noreply, deliver(ref, {:exit, reason}, state)}
  end

  # A Task's exit signal (its reply or :DOWN carries the outcome), or a
  # reply or :DOWN for a Task that was already delivered. The session's exit
  # never lands here: it is the parent, and a trapped parent exit stops the
  # GenServer before handle_info.
  defp info(_message, state), do: {:noreply, state}

  # The hands stop only for a trapped reason; on an untrappable kill the
  # links do the same work. Each tool frees its resources when its Task dies
  # (see `Helyx.Tool.hold/1`).
  @impl true
  def terminate(_reason, state) do
    Helyx.Reason.no_args(fn ->
      for {_ref, {task, _, _, _, _}} <- state.tasks, do: Task.shutdown(task, :brutal_kill)
      :ok
    end)
  end

  # No resource survives its Task: the handles are released when the result
  # delivers, however the Task ended, and the result waits until the
  # release returns, so a call that runs alone cannot overlap a dying one. A handle
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
        unconfirmed?: state.unconfirmed? or left != %{}
    }
  end

  defp outcome(_turn_id, :provider, pid, result), do: {:provider_down, pid, down_reason(result)}

  defp outcome(nil, {:background, id}, _pid, result),
    do: {:background_end, Background.end_message(id, checked(result))}

  defp outcome(turn_id, id, _pid, result), do: outcome(turn_id, id, result)

  # The reason of a provider process's end. `Helyx.Reason` caps its
  # integers when it makes the text. A kill is the armed
  # kill of a request that got no answer in time. The loop ends with
  # `{:shutdown, reason}` (L1). An unconfirmed handle sets `unconfirmed?`,
  # which refuses the next start.
  defp down_reason({:exit, :killed}), do: :provider_timeout
  defp down_reason({:exit, {:shutdown, reason}}), do: reason
  defp down_reason({:exit, reason}), do: {:task_exit, reason}
  defp down_reason({:error, _text} = error), do: error

  defp outcome(turn_id, call_id, result), do: {:tool_result, turn_id, call_id, checked(result)}

  # A crash of the Task: the log gets the kind of its reason, the result its text.
  defp checked({:exit, reason}) do
    Helyx.Reason.log("tool crashed", reason)
    checked({:error, "tool crashed: " <> Helyx.Reason.text(reason)})
  end

  # Every result and background end leaves the hands through here, so text
  # is made valid and cut to the limit once, for the ok, error, crash,
  # refusal, and catch paths alike.
  defp checked({status, text}), do: {status, Helyx.Message.cut_result(text)}

  # A fixed error needs no Task: it is answered at once, as a refusal is.
  defp start(state, turn_id, %ToolCall{} = call, context) do
    cwd = state.cwd

    context =
      Map.merge(context, %{
        core: state.core,
        tools: Map.keys(state.tools),
        tool: call.name,
        call_id: call.id
      })

    case Map.fetch(state.tools, call.name) do
      :error ->
        answer(state, turn_id, call.id, "unknown tool: #{call.name}")

      {:ok, tool} ->
        {_pid, state} =
          spawn_task(state, turn_id, call.id, tool, fn ->
            Process.put(:helyx_call, context)
            Run.tool(tool, call, cwd)
          end)

        state
    end
  end

  # `id` is the call id or `:provider`; `module` is the tool or
  # the provider whose `release/3` gets the Task's handles.
  defp spawn_task(state, turn_id, id, module, fun) do
    hands = self()
    session = state.session

    task =
      Task.Supervisor.async(Helyx.Core.task_supervisor(state.core), fn ->
        Process.put(:helyx_hands, hands)
        # For `Helyx.Tool.transcript/0`.
        Process.put(:helyx_session, session)
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
