defmodule Helyx.Session do
  @moduledoc """
  One conversation with one agent.

  A session is a supervised process under Core. It owns the transcript and
  the current turn. Clients subscribe to its events and send prompts.

      {:ok, session} = Helyx.Session.start(core, model: "fake/echo")
      {:ok, snapshot, ref} = Helyx.Session.subscribe(session)
      :ok = Helyx.Session.prompt(session, "hello")
      # receive {:helyx_event, %Helyx.Event{}} ... (a client that
      # reconnects drops each event of another instance_id than the
      # snapshot's, and each seq <= snapshot.seq)
      # then {:DOWN, ^ref, :process, _pid, reason} when the session
      # ends; Helyx.Session.end_reason(reason) is :stopped or :crashed

  Every provider runs the turn in its provider process (ADR 0002, ADR 0007).
  A model provider runs it with `Helyx.Provider.Loop`, whose tool calls run
  on the session's hands (`Helyx.Session.Hands`) one at a time, in call
  order; another provider can run the whole turn and its own tools. A tool
  call with no result at the turn end gets `aborted_result/0`. Steers and
  follow-ups wait in queues. An abort ends the turn at once (`abort/1`). A
  compaction is a turn too (`compact/2`). Every message has an id, and
  every user message an origin (`docs/features/message-identity.md`).

  `docs/features/session-lifecycle.md` has the turn, the queues, the
  abort, and the provider process. `docs/features/session-subscribers.md`
  has the subscription.
  """

  alias Helyx.{Message, ModelRef}
  alias Helyx.Session.{Id, Server, Snapshot, Transcript}
  alias Helyx.Session.Server.State

  @enforce_keys [:id, :core]
  defstruct [:id, :core]

  # The timeout of each call of the contract but `abort/1`.
  @call_timeout_ms 5_000

  @type t :: %__MODULE__{id: String.t(), core: Helyx.Core.name()}

  @typedoc "An error of `prompt/3`, `steer/3`, and `follow_up/3`."
  @type send_error :: :invalid_utf8 | :invalid_origin | :queue_full | :session_not_found

  @typedoc "An error that stops a model ref from resolving to a provider plugin."
  @type model_error ::
          {:invalid_model_ref, String.t()}
          | {:unknown_provider, String.t()}

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
  The writer lock of the file comes before its first write: a session that
  another OS process holds gives `{:error, {:session_locked, id}}`, and a lock
  that cannot be taken `{:error, {:lock_failed, text}}` (session-lock.md).
  """
  @spec start(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, model_error() | term()}
  def start(core \\ Helyx.Core, opts) do
    id = Id.new()

    # The file is created only after the plugins resolve, which narrows the
    # window for an orphan file from a failed start. A crash of the
    # session's init after the create still leaves one.
    with {:ok, cwd} <- fetch_cwd(opts),
         {:ok, tools} <- Helyx.Tool.specs(core),
         :ok <- Helyx.Tool.check_available(tools),
         {:ok, {ref, provider}} <- resolve_model(core, Keyword.fetch!(opts, :model)) do
      Server.start(
        %State{id: id, core: core, model: ref, provider: provider, cwd: cwd},
        tools,
        create_spec(opts[:sessions_dir], id, cwd, ref)
      )
    end
  end

  # The open of the file, which the session process runs in its init under
  # the lock of `path` (`Server.start/3`).
  defp create_spec(nil, _id, _cwd, _ref), do: nil

  defp create_spec(dir, id, cwd, ref) do
    {Helyx.Session.File.path(dir, cwd, id),
     fn state ->
       with {:ok, file} <- Helyx.Session.File.create(dir, id, cwd, ModelRef.to_string(ref)),
            do: {:ok, %{state | file: file}}
     end}
  end

  @doc """
  Resumes from `:sessions_dir` the session `Helyx.Session.File.pick/3` picks:
  the newest of the working directory, or with `:id` that session. It restores the
  transcript and the current model. A tool call without a result gets an error
  result in the transcript read that says it may have run
  (`docs/features/interrupted-calls.md`), after its message and its results, so
  the next provider call sees complete call and result pairs. A tool result that
  answers no open call at its place is left out of the transcript read. The resume
  writes no entry: every resume of the file only appends a newline that the last
  line lacks. `:cwd` is checked as in `start/2`, and the tool specs and the tool
  checks as in `start/2`, all before the sessions directory is read. The model ref
  of the file resolves as in `set_model/2`, with the same errors. The lock is
  taken as in `start/2`, before the load; a locked newest session is not skipped.
  """
  @spec resume(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, model_error() | term()}
  def resume(core \\ Helyx.Core, opts) do
    dir = Keyword.fetch!(opts, :sessions_dir)

    with {:ok, cwd} <- fetch_cwd(opts),
         {:ok, tools} <- Helyx.Tool.specs(core),
         :ok <- Helyx.Tool.check_available(tools),
         {:ok, path} <- Helyx.Session.File.pick(dir, cwd, Keyword.take(opts, [:id])) do
      Server.start(
        %State{
          id: Path.basename(path, ".jsonl"),
          core: core,
          model: nil,
          provider: nil,
          cwd: cwd
        },
        tools,
        {path, &load(&1, path)}
      )
    end
  end

  # The read of the locked file and its model ref, in the session's init.
  # A crash can leave tool calls with no result, and the disk can hold a
  # result with no open call. The session reads them with interrupted
  # results and without the stray results, and writes nothing (#269, #417, #584).
  defp load(state, path) do
    with {:ok, resumed} <- Helyx.Session.File.resume_picked(path, state.cwd),
         {:ok, {ref, provider}} <- resolve_model(state.core, resumed.model) do
      {:ok,
       %{
         state
         | model: ref,
           provider: provider,
           file: resumed.file,
           transcript: Transcript.repair(resumed.messages),
           resume_ids: resumed.resume_ids
       }}
    end
  end

  # The boundary for `cwd`. It goes into the session file as JSON, into the
  # system prompt, and to programs, which cut a string at a NUL byte.
  defp fetch_cwd(opts), do: opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> check_cwd()

  defp check_cwd(cwd) when is_binary(cwd) do
    if String.valid?(cwd) and not String.contains?(cwd, <<0>>),
      do: {:ok, cwd},
      else: {:error, :invalid_cwd}
  end

  defp check_cwd(_cwd), do: {:error, :invalid_cwd}

  # A model ref string to its parsed ref and its provider plugin, for start,
  # resume, and a switch alike.
  defp resolve_model(core, string) do
    with {:ok, ref} <- ModelRef.parse(string),
         {:ok, provider} <- Helyx.Provider.find(core, ref.provider),
         do: {:ok, {ref, provider}}
  end

  @doc """
  Subscribes the caller to the session's events, delivered as
  `{:helyx_event, event}`, and returns the session's state as a
  `Helyx.Session.Snapshot`. The session adds the caller and builds the
  snapshot in one step, so every event after the snapshot reaches it
  (`docs/features/session-subscribers.md`). A caller that reconnects drops
  an event whose `instance_id` is not `snapshot.instance_id`: it is of an
  earlier instance with the same id, which a resume makes, or of a session
  with the same id in another Core. An event with a `seq` at or below
  `snapshot.seq` is already in the snapshot; that caller drops it too. A
  caller that subscribes once gets no such event (ADR 0006, revision of
  2026-10-03).

  The caller gets `{:ok, snapshot, ref}`, where `ref` is its monitor of the
  session process, made before the subscribe call. After its last event, the
  session gives the caller one end signal when it ends:

      {:DOWN, ref, :process, pid, reason}

  `end_reason/1` maps `reason` to `:stopped` or `:crashed`. The caller owns
  the ref. The session holds one subscription for each caller pid, so a
  second subscribe, a reconnect for example, gets a new snapshot and each
  event once, and a second ref. The caller removes the ref it no longer
  wants with `Process.demonitor(ref, [:flush])`.

  A session that is not running returns `{:error, :session_not_found}`, with
  no subscription of the caller and no monitor left for it. This includes a
  session whose Core has stopped. A snapshot call that exits on its timeout
  also leaves no subscription and no monitor, and the exit then goes on to
  the caller. A failed subscribe also ends an earlier subscription of the
  caller: the ref of the earlier one stays with the caller and gives no more
  events, only the end signal. An event that the session sent before it
  ended can stay in the caller's mailbox; a client drops it by `instance_id`
  and `seq` once it has a snapshot. The other operations return
  `{:error, :session_not_found}` for such a session too.
  """
  @spec subscribe(t()) :: {:ok, Snapshot.t(), reference()} | {:error, :session_not_found}
  def subscribe(%__MODULE__{} = session) do
    case pid(session) do
      nil -> {:error, :session_not_found}
      # The monitor comes before the call, so the real exit reason of the
      # pid of the snapshot is never lost.
      pid -> subscribe_pid(pid, Process.monitor(pid))
    end
  end

  # On a failure the unsubscribe follows the call from this process to the
  # same pid, so a live session handles it after the subscribe.
  defp subscribe_pid(pid, ref) do
    case call_pid(pid, {:subscribe, self()}, @call_timeout_ms) do
      %Snapshot{} = snapshot ->
        {:ok, snapshot, ref}

      {:error, :session_not_found} ->
        unsubscribe(pid, ref)
        {:error, :session_not_found}
    end
  catch
    # `call_pid/3` lets only the timeout of a running session exit.
    :exit, reason ->
      unsubscribe(pid, ref)
      :erlang.raise(:exit, reason, __STACKTRACE__)
  end

  defp unsubscribe(pid, ref) do
    Process.demonitor(ref, [:flush])
    send(pid, {:unsubscribe, self()})
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
  The result of a tool call that the session ended without a result, such
  as at an abort. Clients match this value.
  """
  @spec aborted_result() :: {:error, String.t()}
  def aborted_result, do: {:error, "aborted"}

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

  Its message has the origin `:user`. Product code passes `origin: %{kind:
  :product, id: id}`, an id of 1 to 256 bytes of UTF-8, unique per call; any
  other option list is `{:error, :invalid_origin}`. `steer/3` and
  `follow_up/3` take it too (`docs/features/message-identity.md`).
  """
  @spec prompt(t(), String.t(), keyword()) :: :ok | {:error, :turn_running | send_error()}
  def prompt(%__MODULE__{} = session, text, opts \\ []) when is_binary(text) and is_list(opts),
    do: send_user(session, :prompt, text, opts)

  @doc """
  Steers the running turn. `:ok` means that the session accepted the
  steer. With no turn running it starts a turn, like a prompt. The text
  must be valid UTF-8. The queued steers and the sent steers that are
  still open count to 32. At that count the call returns
  `{:error, :queue_full}`. An abort or a failure of the turn gives every
  queued steer back to the client in a `:queue_dropped` event.

  The provider takes a steer at most once, and its user message joins the
  transcript where the provider takes it. A rejected steer waits for the
  next turn, unless the turn aborts or fails first. A steer that Helyx
  cannot confirm is never sent again; a `:steer_unconfirmed` event carries
  its message (`docs/features/session-lifecycle.md`, "Turn states", "Steer").
  """
  @spec steer(t(), String.t(), keyword()) :: :ok | {:error, send_error()}
  def steer(%__MODULE__{} = session, text, opts \\ []) when is_binary(text) and is_list(opts),
    do: send_user(session, :steer, text, opts)

  @doc """
  Queues a follow-up prompt. Each follow-up opens its own turn, in the
  order it was sent, after the current turn ends normally; steers that the
  turn did not take open one turn together before any follow-up. With no
  turn running it starts a turn at once. The text must be valid UTF-8. A
  full queue returns `{:error, :queue_full}`. An abort or a failure of the
  turn gives it back to the client in a `:queue_dropped` event.
  """
  @spec follow_up(t(), String.t(), keyword()) :: :ok | {:error, send_error()}
  def follow_up(%__MODULE__{} = session, text, opts \\ []) when is_binary(text) and is_list(opts),
    do: send_user(session, :follow_up, text, opts)

  @doc """
  Compacts the history that the provider keeps, as a turn with no user
  message (`docs/features/harness-compaction.md`). A running turn aborts
  first, as at `abort/1`, and is not retried. A second compaction before
  the first ends returns `{:error, :turn_running}`. A provider that keeps
  no history gives a `:notice` event. The text must be valid UTF-8.
  """
  @spec compact(t(), String.t()) ::
          :ok | {:error, :turn_running | :invalid_utf8 | :session_not_found}
  def compact(%__MODULE__{} = session, instructions \\ "") when is_binary(instructions),
    do: send_text(session, {:compact, instructions}, instructions)

  defp send_user(session, op, text, opts),
    do: with({:ok, origin} <- origin(opts), do: send_text(session, {op, text, origin}, text))

  # The boundary of the origin: product code may set only `:product`.
  defp origin([]), do: {:ok, %{kind: :user, id: nil}}

  defp origin(origin: %{kind: :product} = origin),
    do: if(Message.origin?(origin), do: {:ok, origin}, else: {:error, :invalid_origin})

  defp origin(_opts), do: {:error, :invalid_origin}

  defp send_text(session, request, text),
    do: if(String.valid?(text), do: call(session, request), else: {:error, :invalid_utf8})

  @doc """
  Switches the session's model. The ref is parsed and its provider resolved
  like the `:model` of `start/2`. Each error is a `t:model_error/0`, and the
  model stays as it was. The switch is written to the session
  file as a `model_change` entry, so a resume restores it, and goes out as a
  `:model_change` event. A running turn keeps the model it started with; the
  next turn uses the new one.
  """
  @spec set_model(t(), String.t()) :: :ok | {:error, model_error() | :session_not_found}
  def set_model(%__MODULE__{core: core} = session, string) when is_binary(string) do
    with {:ok, {ref, provider}} <- resolve_model(core, string) do
      call(session, {:set_model, ref, provider})
    end
  rescue
    # The plugin table is gone with its Core, and so is the session.
    ArgumentError -> {:error, :session_not_found}
  end

  @doc """
  Aborts (`docs/features/session-lifecycle.md`, "Turn end", "The wait"):

    * A turn runs: the turn ends at once as `:aborted`. Each tool call
      without a result gets an `aborted` error result, so the transcript
      keeps complete call and result pairs. If texts are queued, one
      `:queue_dropped` event with the turn id gives them back before
      `:turn_end`, which waits for the hands' cleanup while a Helyx tool
      call runs. This call waits until the end of the wait after the turn.
    * The session waits after a turn, a failed one too, or for a provider
      process that ends: if texts are queued, one `:queue_dropped` event
      with a nil turn id gives them back; the call returns at the end.
    * Neither: the call returns at once, and the queues are empty. A
      steer of an ended turn that still waits for its answer gets its
      `:steer_unconfirmed` event now.

  When the hands cannot confirm that a resource of the turn was released,
  the call still returns `:ok`, and a `:notice` event with no turn id
  tells the clients.
  """
  @spec abort(t()) :: :ok | {:error, :session_not_found}
  def abort(%__MODULE__{} = session), do: call(session, :abort, :infinity)

  # A call of the contract. The session is not running when no process has
  # the id, or when the process is dead (the Registry drops its name
  # asynchronously) or dies during the call. A timeout still exits, also
  # for a session that stopped with the reason `:timeout` (ADR 0006).
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
      :erlang.raise(:exit, reason, __STACKTRACE__)

    :exit, {_reason, _call} ->
      {:error, :session_not_found}
  end
end
