defmodule Helyx.Session.Hands do
  # The time a cancelled stream Task gets to end by itself.
  @stream_stop_ms 2_000

  @moduledoc """
  Runs tool calls for one session in one working directory. See ADR 0003
  and ADR 0004.

  The session starts the hands and addresses it by pid. Each tool call runs
  in a Task under Core's task supervisor, linked to the hands: the hands
  trap exits, so a Task crash is a message, and a death of the hands, even
  an untrappable kill, takes every running Task with it. The result goes
  back to the session as `{:tool_result, turn_id, call_id, {:ok, text} |
  {:error, text}}`. A Task that dies without a result gives an error result,
  and so does a working directory that is gone when the call starts. Tool
  calls and results are plain terms. Result text is valid UTF-8 when it
  leaves the hands: each invalid sequence is replaced with U+FFFD, so a
  later encoder never sees invalid stored text.

  A tool that creates an OS resource holds it with `Helyx.Tool.hold/1`. The
  hands then keep an opaque handle outside the Task. When the call
  delivers, however the Task ended, the hands call the tool's `release/3`
  with the Task's handles. The result goes to the session only after the
  release returns. The OS work lives in the tool, never here.

  The release runs in its own Task with a deadline. A handle is
  unconfirmed when the release returns it. All the handles of a release are
  unconfirmed when the release times out, raises, exits, or returns a bad
  value. An unconfirmed handle makes the result an error. The tool gets
  `:retry` for it at the start of each later tool call. While a handle is
  unconfirmed, the hands refuse tool calls with an error result. Chat,
  abort, and quit are not blocked.

  `stream/4` runs the stream of a harness provider call the same way, as
  a Task of the hands with the provider module in the place of the tool,
  because the harness program is the turn's tool runner (ADR 0004). Its
  terminal goes to the session as `{:stream_end, turn_id, terminal}` after
  the release. A crash gives `{:error, {:task_exit, reason}}`, and an
  unconfirmed handle an error terminal. While a handle is unconfirmed the
  stream is refused with an error terminal, like a tool call.

  A cancel request (`request_cancel/2`) aborts a turn: the hands kill the
  turn's tool and stream Tasks and call `release/3` with `:cancel` for
  their handles, one release Task per tool, in parallel, with one deadline.
  The answer arrives only when every release has returned or timed out. An
  unconfirmed handle is reported as an error. A tool Task is killed at
  once. A stream Task gets a `:shutdown` exit signal and #{@stream_stop_ms} ms
  before the kill: a provider whose Task traps exits can use them to ask
  its program to stop the turn.

  `connect/3` starts the harness process of a connected provider (ADR
  0007), and `prepare/3` the prepare Task of a connected turn. Both get a
  kill armed at the OTP timer server when they start (`:timer.kill_after/2`):
  30,000 ms for the connect and 10,000 ms for the prepare. Their Core
  code cancels it, so no timer of the hands enforces the bound. The harness
  process has no turn: a cancel request leaves it. When it ends, the hands
  release its handles and send `{:harness_down, pid, reason}`: `:closed`
  after a close, `:harness_timeout` after an armed kill, `{:task_exit,
  reason}` after a crash, and the loop's reason after a stop. A prepare Task
  that dies gives `{:prepare_failed, turn_id, reason}`.
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
    # deadline of a delivery or a cancel, and `connect_ms` and `prepare_ms`
    # the armed kills of a harness process and a prepare Task: seams for
    # tests.
    @enforce_keys [:core, :cwd, :session, :tools]
    defstruct [
      :core,
      :cwd,
      :session,
      :tools,
      tasks: %{},
      held: %{},
      unconfirmed: %{},
      release_ms: 20_000,
      connect_ms: 30_000,
      prepare_ms: 10_000
    ]
  end

  @doc """
  Starts the hands for a session. Takes `core:`, `cwd:`, `session:`, and
  `tools:`, the tool module by name, from the specs the session checked
  with `Helyx.Tool.specs/1`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, struct!(State, opts))

  @doc "Starts a tool call. The result is sent to the session."
  @spec run(pid(), String.t(), ToolCall.t()) :: :ok
  def run(hands, turn_id, %ToolCall{} = call),
    do: GenServer.call(hands, {:start, turn_id, call})

  @doc """
  Starts the stream of a harness provider call: `fun` runs in a Task of the
  hands and returns the terminal stream event, which is sent to the session
  as `{:stream_end, turn_id, terminal}` after the release of the provider's
  handles.
  """
  @spec stream(pid(), String.t(), module(), (-> term())) :: :ok
  def stream(hands, turn_id, provider, fun) when is_function(fun, 0),
    do: GenServer.call(hands, {:start, turn_id, {provider, fun}})

  @doc """
  Starts the harness process of a connected provider: `fun` gets the ref of
  the armed connect kill and runs in a Task of the hands with no turn.
  Returns its pid, or an error text while a handle is unconfirmed.
  """
  @spec connect(pid(), module(), (:timer.tref() -> term())) :: {:ok, pid()} | {:error, String.t()}
  def connect(hands, provider, fun) when is_function(fun, 1),
    do: GenServer.call(hands, {:connect, provider, fun})

  @doc """
  Starts the prepare Task of a connected turn: `fun` gets the ref of the
  armed kill. It holds no resource.

  A cast, not a call: a harness process can end at any time, and the hands
  release its handles in their own loop for up to the release deadline.
  The session must not wait for that. The hands start the Task when they
  take the message, after any earlier message of the session, so a later
  `request_cancel/2` finds it. The other calls of the session, `connect/3`,
  `stream/4`, and `run/3`, come only when it holds no harness process: a
  local or external turn has none (a switch closes it and waits for its
  `:harness_down`), and a connect follows the `:harness_down` of the last
  one.
  """
  @spec prepare(pid(), String.t(), (:timer.tref() -> term())) :: :ok
  def prepare(hands, turn_id, fun) when is_function(fun, 1),
    do: GenServer.cast(hands, {:prepare, turn_id, fun})

  @doc """
  Asks the hands to cancel the turn's tool and stream Tasks and release
  their handles. Sends the request and returns at once, so the caller stays
  free during the release. Read the answer with
  `:gen_server.check_response/2` or `:gen_server.receive_response/2`: `:ok`
  when every release has returned, or an error naming the unconfirmed
  handles.
  """
  @spec request_cancel(pid(), String.t()) :: :gen_server.request_id()
  def request_cancel(hands, turn_id), do: :gen_server.send_request(hands, {:cancel, turn_id})

  @impl true
  def init(%State{} = state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  # A tool call or a harness stream.
  def handle_call({:start, turn_id, job}, _from, state) do
    state = retry(state)

    if state.unconfirmed == %{} do
      {:reply, :ok, start(state, turn_id, job)}
    else
      {:reply, :ok, refuse(state, turn_id, job_id(job))}
    end
  end

  def handle_call({:connect, provider, fun}, _from, state) do
    state = retry(state)

    if state.unconfirmed == %{} do
      {pid, state} = spawn_armed(state, nil, :harness, provider, state.connect_ms, fun)
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

    Enum.each(cancelled, fn {task, _turn, call_id, _tool} ->
      Task.shutdown(task, shutdown_mode(call_id))
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
  def handle_cast({:prepare, turn_id, fun}, state) do
    {_pid, state} = spawn_armed(state, turn_id, :prepare, nil, state.prepare_ms, fun)
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

    with message when message != nil <-
           outcome(turn_id, call_id, task.pid, unconfirmed_error(left) || result),
         do: send(state.session, message)

    %{state | tasks: tasks, held: held, unconfirmed: add_handles(state.unconfirmed, left)}
  end

  # Of the terminals of an external turn, the crash reason is the one that
  # `Helyx.Session.Stream.run/1` did not cap, so the hands cap it where they
  # make it (see `Helyx.Message.cap_integers/1`). The session caps the crash
  # reason of a local turn in its `:DOWN` clause.
  defp outcome(_turn_id, :harness, pid, result), do: {:harness_down, pid, harness_reason(result)}

  defp outcome(turn_id, :prepare, _pid, {:exit, reason}),
    do: {:prepare_failed, turn_id, Helyx.Message.cap_integers(reason)}

  # The prepare Task sent its context itself.
  defp outcome(_turn_id, :prepare, _pid, _result), do: nil
  defp outcome(turn_id, id, _pid, result), do: outcome(turn_id, id, result)

  # The reason of a harness process's end, capped like a crash reason. A
  # kill is the armed kill of a request: the harness did not answer in
  # time. An unconfirmed handle stays in `unconfirmed` and refuses the next
  # connect.
  defp harness_reason({:exit, :killed}), do: :harness_timeout
  defp harness_reason({:exit, reason}), do: {:task_exit, Helyx.Message.cap_integers(reason)}
  defp harness_reason({:error, _unconfirmed} = error), do: error
  defp harness_reason({:stop, reason}), do: Helyx.Message.cap_integers(reason)
  defp harness_reason(:closed), do: :closed

  defp outcome(turn_id, :stream, {:exit, reason}),
    do: {:stream_end, turn_id, {:error, {:task_exit, Helyx.Message.cap_integers(reason)}}}

  defp outcome(turn_id, :stream, terminal), do: {:stream_end, turn_id, terminal}

  defp outcome(turn_id, call_id, {:exit, reason}),
    do: outcome(turn_id, call_id, {:error, "tool crashed: #{inspect(reason)}"})

  defp outcome(turn_id, call_id, result), do: {:tool_result, turn_id, call_id, scrub(result)}

  defp start(state, turn_id, %ToolCall{} = call) do
    tool = if File.dir?(state.cwd), do: Map.get(state.tools, call.name, :unknown), else: :no_cwd
    cwd = state.cwd
    {_pid, state} = spawn_task(state, turn_id, call.id, tool, fn -> run_tool(tool, call, cwd) end)
    state
  end

  defp start(state, turn_id, {provider, fun}) do
    {_pid, state} = spawn_task(state, turn_id, :stream, provider, fun)
    state
  end

  defp job_id(%ToolCall{id: id}), do: id
  defp job_id({_provider, _fun}), do: :stream

  # `id` is the call id, or `:stream` for a provider stream; `module` is the
  # tool or the provider whose `release/3` gets the Task's handles.
  defp spawn_task(state, turn_id, id, module, fun) do
    hands = self()

    task =
      Task.Supervisor.async(Helyx.Core.task_supervisor(state.core), fn ->
        Process.put(:helyx_hands, hands)
        fun.()
      end)

    {task.pid, %{state | tasks: Map.put(state.tasks, task.ref, {task, turn_id, id, module})}}
  end

  # A Task whose kill is armed at the OTP timer server as it starts. `fun`
  # gets the timer ref first, before any plugin code runs.
  defp spawn_armed(state, turn_id, id, module, ms, fun) do
    {pid, state} =
      spawn_task(state, turn_id, id, module, fn ->
        receive do
          {:helyx_kill, tref} -> fun.(tref)
        end
      end)

    {:ok, tref} = :timer.kill_after(ms, pid)
    send(pid, {:helyx_kill, tref})
    {pid, state}
  end

  defp refuse(state, turn_id, id) do
    send(state.session, outcome(turn_id, id, {:error, refusal(state)}))
    state
  end

  defp refusal(state) do
    "a resource from an earlier call could not be released " <>
      "(#{handles_text(state.unconfirmed)}); the call was not run"
  end

  defp shutdown_mode(:stream), do: @stream_stop_ms
  defp shutdown_mode(_call_id), do: :brutal_kill

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

  # Every result leaves the hands through here, so text is made valid once,
  # for the ok, error, crash, and catch paths alike. Valid text, the common
  # case, is passed through without a copy.
  defp scrub({status, text}) do
    if String.valid?(text), do: {status, text}, else: {status, String.replace_invalid(text)}
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
