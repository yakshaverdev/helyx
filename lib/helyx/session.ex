defmodule Helyx.Session do
  @moduledoc """
  One conversation with one agent.

  A session is a supervised process under Core. It owns the transcript and
  the current turn. Clients subscribe to its events and send prompts.

      {:ok, session} = Helyx.Session.start(core, model: "fake/echo")
      {:ok, snapshot} = Helyx.Session.subscribe(session)
      :ok = Helyx.Session.prompt(session, "hello")
      # receive {:helyx_event, %Helyx.Event{}}, drop each event of another
      # instance_id than the snapshot's, and each seq <= snapshot.seq ...
      # then {{:helyx_session_end, id}, _ref, :process, _pid, reason} when
      # the session ends; Helyx.Session.end_reason(reason) is :stopped or
      # :crashed

  Each turn runs the provider stream in a Task under Core's task supervisor,
  linked to the session: the session traps exits, so a Task crash stays a
  message, and a death of the session takes the Task, the hands, and every
  tool Task with it (ADR 0004). The Task sends each stream event to the
  session and returns the terminal stream event, `done` or `error`. The
  session builds the assistant message from the stream events and closes the
  provider call on the Task's reply. A stream that ends without a terminal
  event, or a Task that crashes, fails the turn.

  An assistant message with tool calls runs them on the session's hands
  (`Helyx.Session.Hands`) one at a time, in call order, so two calls never touch the
  working directory at once. Each result joins the transcript as it arrives,
  and the provider is called again after the last one. The turn ends on an
  assistant message with no tool calls.

  Messages sent during a turn queue instead of failing. A steer is delivered,
  with the other queued steers in order, as user messages before the next
  provider call inside the same turn. A follow-up starts a new turn after the
  current turn ends. Anything still queued when a turn ends normally starts a
  new turn; an aborted or failed turn drops its queues. Each queue holds at
  most 32 entries; past the cap the call returns `{:error, :queue_full}`.
  Queues live in the session process only and are not persisted. Every
  change emits a `:queue_update` event.

  A connected provider (one that exports `harness_init/3`, ADR 0002 and
  ADR 0007) runs the whole turn and its own tools in its program, and
  keeps one harness process for the session. The hands start it at
  the first connected turn, and again after it ends. Each turn builds its
  context in a prepare Task of the hands, then the session sends the turn
  to the harness process, which sends the events back. An abort of a turn
  that the harness got interrupts it there; the abort returns after the
  answer, or after the harness process stopped. The harness reports each
  completed assistant message and each tool result, which join the
  transcript as they arrive; a tool call with no result at the end of the
  turn gets an `aborted` error result. The id of each fresh harness
  session is written to the session file and goes out as a
  `:harness_session` event. A model or provider switch
  closes the harness process before the next turn, and so does the end of
  the session. A steer reaches the running connected turn at most once: the
  harness takes it at its next model call, and the user message joins the
  transcript there. A steer that arrives before the harness has the turn
  goes into the turn's prompt. A steer that the harness confirms it did
  not get waits for the next turn. A steer that Helyx cannot confirm is
  never sent again; a `:steer_unconfirmed` event carries its text.

  An abort does not block the session. The session ends the turn at once and
  asks the hands to release the turn's resources. This can take many
  seconds when a resource stays. Until the hands answer, the session
  answers every client call, but it starts no turn, because the hands
  cannot take a tool call during the release: a prompt, a steer, or a
  follow-up queues, and one turn starts with the queue when the hands have
  answered.
  """

  alias Helyx.ModelRef
  alias Helyx.Session.{Id, Server, Transcript}
  alias Helyx.Session.Server.State

  require Logger

  @enforce_keys [:id, :core]
  defstruct [:id, :core]

  # The timeout of each call of the contract but `abort/1`.
  @call_timeout_ms 5_000

  @type t :: %__MODULE__{id: String.t(), core: Helyx.Core.name()}

  @typedoc "An error that stops a model ref from resolving to a provider plugin."
  @type model_error ::
          {:invalid_model_ref, String.t()}
          | {:unknown_provider, String.t()}

  @typedoc """
  A start error as a client gets it (ADR 0006, section 2). See
  `client_start_error/1`.
  """
  @type client_start_error ::
          :invalid_cwd | :not_found | model_error() | {:start_failed, String.t()}

  # Public API

  @doc """
  Starts a session under Core. `:model` is required. `:cwd` defaults to the
  current directory. It must be a valid UTF-8 string with no NUL byte;
  otherwise the result is `{:error, :invalid_cwd}` and nothing is created.
  The tool specs (`Helyx.Tool.specs/1`) and the optional `check/0` of each
  tool (`Helyx.Tool.check_available/1`) run next, before any file or
  process is created. The model ref resolves as in `set_model/2`, with the
  same errors.
  With `:sessions_dir` the session is written to disk as it runs, as JSON
  lines under `<sessions_dir>/<project>/<session>.jsonl`; without it nothing
  is persisted. When a write fails, the session goes on in memory, writes
  nothing more, and sends one `:notice` event. A resume writes no entry
  (see `resume/2`), so every write comes after a client can subscribe.
  """
  @spec start(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, model_error() | term()}
  def start(core \\ Helyx.Core, opts) do
    id = Id.new()

    # The file is created only after the plugins resolve, which narrows the
    # window for an orphan file from a failed start. A supervisor failure
    # after this point still leaves one; the feature doc records that hole.
    with {:ok, cwd} <- fetch_cwd(opts),
         {:ok, tools} <- Helyx.Tool.specs(core),
         :ok <- Helyx.Tool.check_available(tools),
         {:ok, {ref, provider, turn_mode}} <- resolve_model(core, Keyword.fetch!(opts, :model)),
         {:ok, file} <- create_file(opts[:sessions_dir], id, cwd, ref) do
      start_child(
        %State{
          id: id,
          core: core,
          model: ref,
          provider: provider,
          turn_mode: turn_mode,
          cwd: cwd,
          file: file
        },
        tools
      )
    end
  end

  defp create_file(nil, _id, _cwd, _ref), do: {:ok, nil}

  defp create_file(dir, id, cwd, ref),
    do: Helyx.Session.File.create(dir, id, cwd, ModelRef.to_string(ref))

  @doc """
  Resumes the most recent session for the working directory from
  `:sessions_dir`, restoring the transcript and the current model. Every
  tool call without a result gets an `aborted` error result in the
  transcript read, right after its message and its results, so the next
  provider call sees complete call and result pairs. The resume writes no
  entry: every resume of the file inserts the same results. It only appends
  a newline that the last line lacks. `:cwd` is checked as in
  `start/2`, and the tool specs and the tool checks as in `start/2`, all
  before the sessions directory is read. The model ref of the file resolves
  as in `set_model/2`, with the same errors.
  """
  @spec resume(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, model_error() | term()}
  def resume(core \\ Helyx.Core, opts) do
    dir = Keyword.fetch!(opts, :sessions_dir)

    with {:ok, cwd} <- fetch_cwd(opts),
         {:ok, tools} <- Helyx.Tool.specs(core),
         :ok <- Helyx.Tool.check_available(tools),
         {:ok, resumed} <- Helyx.Session.File.resume(dir, cwd),
         {:ok, {ref, provider, turn_mode}} <- resolve_model(core, resumed.model) do
      # A crash can leave tool calls with no result. The session reads them
      # with `aborted` results and writes nothing (#269).
      {transcript, harness_sessions} =
        Transcript.abort_unanswered(resumed.messages, resumed.harness_sessions)

      start_child(
        %State{
          id: resumed.session_id,
          core: core,
          model: ref,
          provider: provider,
          turn_mode: turn_mode,
          cwd: cwd,
          file: resumed.file,
          transcript: transcript,
          harness_sessions: harness_sessions
        },
        tools
      )
    end
  end

  # The boundary for `cwd`. It goes into the session file as JSON, into the
  # system prompt, and to `Port.open`, which cuts a string at a NUL byte.
  defp fetch_cwd(opts), do: opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> check_cwd()

  defp check_cwd(cwd) when is_binary(cwd) do
    if String.valid?(cwd) and not String.contains?(cwd, <<0>>),
      do: {:ok, cwd},
      else: {:error, :invalid_cwd}
  end

  defp check_cwd(_cwd), do: {:error, :invalid_cwd}

  # A model ref string to its parsed ref, its provider plugin, and the turn
  # of that plugin, for start, resume, and a switch alike.
  defp resolve_model(core, string) do
    with {:ok, ref} <- ModelRef.parse(string),
         {:ok, provider} <- Helyx.Provider.find(core, ref.provider),
         do: {:ok, {ref, provider, Helyx.Provider.turn(provider)}}
  end

  defp start_child(%State{id: id, core: core} = state, tools) do
    # The plugin table of a Core does not change after start, so a plugin
    # resolved once here is the plugin a lookup per provider call would give.
    # Both interfaces are single-mode: one plugin or none (nil).
    state = %{
      state
      | model_context: List.first(Helyx.Core.plugins(core, Helyx.ModelContext)),
        compaction: List.first(Helyx.Core.plugins(core, Helyx.Compaction)),
        tools: Enum.map(tools, fn {_tool, spec} -> spec end),
        tool_modules: Map.new(tools, fn {tool, spec} -> {spec.name, tool} end)
    }

    with {:ok, _pid} <-
           DynamicSupervisor.start_child(Helyx.Core.session_supervisor(core), {Server, state}) do
      {:ok, %__MODULE__{id: id, core: core}}
    end
  end

  @doc """
  Subscribes the caller to the session's events, delivered as
  `{:helyx_event, event}`, and returns the session's state as a
  `Helyx.Session.Snapshot`. The session adds the caller and builds the
  snapshot in one step, so every event after the snapshot reaches it
  (`docs/features/session-subscribers.md`). The caller drops an event whose
  `instance_id` is not `snapshot.instance_id`: it is of an earlier instance
  with the same id, which a resume makes, or of a session with the same id
  in another Core. An event with a `seq` at or below `snapshot.seq` is
  already in the snapshot; the caller drops it too.

  After its last event, the subscription gives one end signal when the
  session ends, from a monitor of the session process that the caller holds:

      {{:helyx_session_end, id}, ref, :process, pid, reason}

  `end_reason/1` maps `reason` to `:stopped` or `:crashed`. The `ref` and
  the `pid` are not contract values: `subscribe/1` owns the monitor.

  A caller holds at most one subscription and one monitor for a session, so
  a second subscribe, a reconnect for example, gets a new snapshot and each
  event once. It removes the monitor of the first, and an end signal of the
  first that is still in the mailbox goes with it.

  A session that is not running returns `{:error, :session_not_found}`,
  with no subscription and no signal left for it. This includes a session
  whose Core has stopped. A snapshot call that exits on its timeout also
  leaves no subscription, and the exit then goes on to the caller. An event
  that the session sent before it ended can stay in the caller's mailbox; a
  client drops it by `instance_id` and `seq` once it has a snapshot. The
  other operations return `{:error, :session_not_found}` for such a session
  too.
  """
  @spec subscribe(t()) :: {:ok, Helyx.Session.Snapshot.t()} | {:error, :session_not_found}
  def subscribe(%__MODULE__{id: id, core: core} = session) do
    key = {__MODULE__, core, id}

    # The old monitor goes first, with its signal (S5 in
    # docs/features/session-subscribers.md).
    case Process.delete(key) do
      nil -> :ok
      {old, _pid} -> Process.demonitor(old, [:flush])
    end

    forget_ended()
    flush_end_signals(id)

    case pid(session) do
      nil -> {:error, :session_not_found}
      # The monitor comes before the call, so the real exit reason of the
      # pid of the snapshot is never lost.
      pid -> subscribe_pid(key, Process.monitor(pid, tag: {:helyx_session_end, id}), pid)
    end
  end

  # On a failure the unsubscribe follows the call from this process to the
  # same pid, so a live session handles it after the subscribe.
  defp subscribe_pid(key, ref, pid) do
    Process.put(key, {ref, pid})

    case call_pid(pid, {:subscribe, self()}, @call_timeout_ms) do
      %Helyx.Session.Snapshot{} = snapshot ->
        {:ok, snapshot}

      {:error, :session_not_found} ->
        unsubscribe(key, ref, pid)
        {:error, :session_not_found}
    end
  catch
    # `call_pid/3` lets only the timeout of a running session exit.
    :exit, reason ->
      unsubscribe(key, ref, pid)
      :erlang.raise(:exit, reason, __STACKTRACE__)
  end

  defp unsubscribe(key, ref, pid) do
    Process.delete(key)
    Process.demonitor(ref, [:flush])
    send(pid, {:unsubscribe, self()})
  end

  # The entries of ended sessions go, so the dictionary holds one entry for
  # each session that this process still monitors. A monitor leaves the list
  # of this process only when its end signal is in the mailbox, where it
  # stays for the client. A dead pid is not enough: a process is dead before
  # its `:DOWN` arrives.
  defp forget_ended do
    {:monitors, monitors} = Process.info(self(), :monitors)
    monitored = MapSet.new(monitors)

    for {{__MODULE__, _core, _id} = key, {_ref, pid}} <- Process.get(),
        not MapSet.member?(monitored, {:process, pid}),
        do: Process.delete(key)
  end

  # An end signal for the id whose entry `forget_ended/0` removed: it is of
  # an earlier process, a resume makes a new one.
  defp flush_end_signals(id) do
    receive do
      {{:helyx_session_end, ^id}, _ref, :process, _pid, _reason} -> flush_end_signals(id)
    after
      0 -> :ok
    end
  end

  @doc """
  The reason of an end signal as a client gets it: `:stopped` for an exit
  with `:normal`, `:shutdown`, or `{:shutdown, term}`, and `:crashed` for
  any other. The supervisor logs the full reason.
  """
  @spec end_reason(term()) :: :stopped | :crashed
  def end_reason(reason) when reason in [:normal, :shutdown], do: :stopped
  def end_reason({:shutdown, _}), do: :stopped
  def end_reason(_reason), do: :crashed

  @doc """
  Maps an error of `start/2` or `resume/2` to the start error that a client
  gets. A transport calls it, so all clients get the same errors.
  `:invalid_cwd`, `:not_found`, and the model errors pass unchanged. The ref
  of `{:invalid_model_ref, ref}` can come from a session file, so it passes
  only when `Helyx.ModelRef.bounded?/1` holds. Any other
  term becomes `{:start_failed, text}` with a fixed text for a person, and
  the full term goes to the log as a warning. The product calls `start/2` or
  `resume/2` itself and keeps the full term.
  """
  @spec client_start_error(term()) :: client_start_error()
  def client_start_error(reason) when reason in [:invalid_cwd, :not_found], do: reason

  # The id of a ref that parsed, so `Helyx.ModelRef` bounds it.
  def client_start_error({:unknown_provider, id} = reason) when is_binary(id), do: reason

  def client_start_error({:invalid_model_ref, ref} = reason) when is_binary(ref) do
    if ModelRef.bounded?(ref), do: reason, else: start_failed(reason)
  end

  def client_start_error(reason), do: start_failed(reason)

  defp start_failed(reason) do
    Logger.warning("session start failed: " <> inspect(reason))
    {:start_failed, "the session did not start; the server log has the reason"}
  end

  @doc "The pid behind a session handle, or nil when the session is not running."
  @spec pid(t()) :: pid() | nil
  def pid(%__MODULE__{id: id, core: core}) do
    GenServer.whereis(Server.via(core, id))
  rescue
    # The Registry is gone with its Core, and so is the session.
    ArgumentError -> nil
  end

  @doc """
  Sends a prompt. Starts a turn if none is running. The text must be valid
  UTF-8. While an abort waits for the hands, the prompt queues as a
  follow-up, and a full queue returns `{:error, :queue_full}`.
  """
  @spec prompt(t(), String.t()) ::
          :ok | {:error, :turn_running | :invalid_utf8 | :queue_full | :session_not_found}
  def prompt(%__MODULE__{} = session, text) when is_binary(text),
    do: send_text(session, :prompt, text)

  @doc """
  Steers the running turn. The text joins the queued steers and is delivered
  before the next provider call inside the turn. With no turn running it
  starts a turn, like a prompt. The text must be valid UTF-8. A full queue
  returns `{:error, :queue_full}`.
  """
  @spec steer(t(), String.t()) :: :ok | {:error, :invalid_utf8 | :queue_full | :session_not_found}
  def steer(%__MODULE__{} = session, text) when is_binary(text),
    do: send_text(session, :steer, text)

  @doc """
  Queues a follow-up prompt. It starts a new turn after the current turn ends
  normally. With no turn running it starts a turn at once. The text must be
  valid UTF-8. A full queue returns `{:error, :queue_full}`.
  """
  @spec follow_up(t(), String.t()) ::
          :ok | {:error, :invalid_utf8 | :queue_full | :session_not_found}
  def follow_up(%__MODULE__{} = session, text) when is_binary(text),
    do: send_text(session, :follow_up, text)

  defp send_text(session, op, text) do
    if String.valid?(text) do
      call(session, {op, text})
    else
      {:error, :invalid_utf8}
    end
  end

  @doc """
  Switches the session's model. The ref is parsed and its provider resolved
  like the `:model` of `start/2`. Each error is a `t:model_error/0`, and the
  model stays as it was. The switch is written to the session
  file as a `model_change` entry, so a resume restores it, and goes out as a
  `:model_change` event. A running turn keeps the model it started with; the
  next turn uses the new one.
  """
  @spec set_model(t(), String.t()) ::
          :ok | {:error, model_error() | :session_not_found}
  def set_model(%__MODULE__{core: core} = session, string) when is_binary(string) do
    with {:ok, {ref, provider, turn_mode}} <- resolve_model(core, string) do
      call(session, {:set_model, ref, provider, turn_mode})
    end
  rescue
    # The plugin table is gone with its Core, and so is the session.
    ArgumentError -> {:error, :session_not_found}
  end

  @doc """
  Aborts the running turn. Returns after the hands have killed every process
  the turn started, so a prompt sent next starts on a clean working
  directory. Each tool call without a result gets an `aborted` error result,
  so the transcript keeps complete call and result pairs. The events of the
  abort go out at once, before the hands are done; only this call waits. With
  no turn running and no abort in progress this is a no-op. When the hands
  cannot confirm that a resource of the turn was released, the call still
  returns `:ok`, and a `:notice` event with no turn id tells the clients.
  """
  @spec abort(t()) :: :ok | {:error, :session_not_found}
  def abort(%__MODULE__{} = session), do: call(session, :abort, :infinity)

  # A call of the contract. The session is not running when no process has
  # the id, or when the process is dead (the Registry drops its name
  # asynchronously) or dies during the call. A timeout of a running session
  # still exits. A session that stopped with the reason `:timeout` gives the
  # same exit, so the timeout clause checks that the process still lives.
  defp call(session, request, timeout \\ @call_timeout_ms) do
    case pid(session) do
      nil -> {:error, :session_not_found}
      pid -> call_pid(pid, request, timeout)
    end
  end

  defp call_pid(pid, request, timeout) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, {:timeout, _call} = reason ->
      if Process.alive?(pid),
        do: :erlang.raise(:exit, reason, __STACKTRACE__),
        else: {:error, :session_not_found}

    :exit, {_reason, _call} ->
      {:error, :session_not_found}
  end
end
