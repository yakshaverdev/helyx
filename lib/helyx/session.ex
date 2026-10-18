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

  Every provider runs the turn in its provider process (ADR 0002, ADR 0007). A
  model provider runs it with `Helyx.Provider.Loop`, whose tool calls run on the
  session's hands (`Helyx.Session.Hands`), concurrent tools together and each
  other call alone; another provider can run the whole turn and its own tools. A
  tool call with no result at the turn end gets `aborted_result/0`. Steers and
  follow-ups wait in queues. An abort ends the turn at once (`abort/1`). A
  compaction is a turn too (`compact/2`). Every message has an id, and every
  user message an origin (`docs/features/message-identity.md`).

  `docs/features/session-lifecycle.md` has the turn, the queues, the
  abort, the provider process, and the late calls: a call that the session
  takes at or past the deadline of its caller does not act.
  `docs/features/session-subscribers.md` has the subscription.
  """

  alias Helyx.ModelRef
  alias Helyx.Session.{Call, History, Id, Input, Server, Snapshot}
  alias Helyx.Session.Server.State

  @enforce_keys [:id, :core]
  defstruct [:id, :core]

  # The timeout of each call of the contract but `abort/1`.
  @call_timeout_ms 5_000

  @type t :: %__MODULE__{id: String.t(), core: Helyx.Core.name()}

  @typedoc "An error of `prompt/3`, `steer/3`, and `follow_up/3`."
  @type send_error ::
          :text_too_large | :invalid_utf8 | :invalid_origin | :queue_full | :session_not_found

  @doc "The most bytes of a text to `prompt/3`, `steer/3`, `follow_up/3`, and `compact/2`: 4 MiB."
  @spec max_text_bytes() :: pos_integer()
  defdelegate max_text_bytes, to: Input

  @typedoc "An error that stops a model ref from resolving to a provider plugin."
  @type model_error ::
          {:invalid_model_ref, String.t()}
          | {:unknown_provider, String.t()}

  @doc """
  Starts a session under Core. `:model` is required. `:cwd` defaults to the current directory.
  It must be a valid UTF-8 string with no NUL byte; otherwise the result is
  `{:error, :invalid_cwd}` and nothing is created. The tool specs (`Helyx.Tool.specs/2`) and the
  optional `check/0` of each tool (`Helyx.Tool.check_available/1`) run next, before any file or
  process is created. The model ref resolves as in `set_model/2`, with the same errors. With
  `:sessions_dir` the session is written to disk as it runs, as JSON lines under
  `Helyx.Session.File.path/4`; without it nothing is persisted. A new sessions folder gets
  mode 0700, or the start fails with `{:error, {:create_failed, reason}}` (`File.mkdir/3`). When a write fails, the session goes on in memory, writes
  nothing more, and sends one `:notice` event. A resume writes no entry (see `resume/2`), so
  every write comes after a client can subscribe. The writer lock of the file comes before its
  first write: a session that another OS process holds gives `{:error, {:session_locked, id}}`,
  a lock that cannot be taken `{:error, {:lock_failed, text}}`, an open past 25,000 ms
  `{:error, :open_timeout}` (session-lock.md), and a start over the 64 sessions of a Core
  `{:error, :too_many_sessions}`. `:tools` names the tools that the session gets, all if nil;
  `:parent` links it to a tool call, out of the session list (`docs/features/agent-tool.md`).
  """
  @spec start(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, model_error() | term()}
  def start(core \\ Helyx.Core, opts) do
    # The file is created only after the plugins resolve, which narrows the
    # window for an orphan file from a failed start. A crash of the
    # session's open after the create still leaves one.
    with {:ok, cwd} <- fetch_cwd(opts),
         {:ok, parent, only} <- Input.child(opts),
         id = if(parent, do: Id.child(parent.session_id, parent.call_id), else: Id.new()),
         {:ok, tools} <- Helyx.Tool.specs(core, only),
         :ok <- Helyx.Tool.check_available(tools),
         concurrent = Helyx.Tool.concurrent(tools),
         {:ok, {ref, provider}} <- Input.model(core, Keyword.fetch!(opts, :model)),
         # The folders come before the lock, whose file is in them.
         :ok <- mkdir(opts[:sessions_dir], cwd, parent) do
      Server.create(
        %State{id: id, core: core, model: ref, provider: provider, cwd: cwd},
        {tools, concurrent},
        create_spec(opts[:sessions_dir], id, cwd, ModelRef.to_string(ref), parent)
      )
    end
  end

  defp mkdir(nil, _cwd, _parent), do: :ok
  defp mkdir(dir, cwd, parent), do: Helyx.Session.File.mkdir(dir, cwd, parent)

  # The open of the file, which the session process runs at its start under
  # the lock of `path` (`Server.create/3`).
  defp create_spec(nil, _id, _cwd, _model, _parent), do: nil

  defp create_spec(dir, id, cwd, model, parent) do
    {Helyx.Session.File.path(dir, cwd, id, parent),
     fn state ->
       with {:ok, file} <- Helyx.Session.File.create(dir, id, cwd, model, parent),
            do: {:ok, %{state | file: file}}
     end}
  end

  @doc """
  Resumes from `:sessions_dir` the session `Helyx.Session.File.pick/3` picks: the newest of the working
  directory, or with `:id` that session, in the folder of its header when no `:cwd` is given. It restores
  the transcript and the current model. A tool call without a result gets an error result in the
  transcript read that says it may have run (`docs/features/interrupted-calls.md`), after its message and
  its results, so the next provider call sees complete call and result pairs. A tool result that answers
  no open call at its place is left out of the transcript read. The resume writes no entry, only a newline
  that the last line lacks. A `:cwd` and the tool checks are as in `start/2`, before the sessions
  directory is read (`docs/features/server-management.md`, "Order of the checks"). The model ref of the
  file resolves as in `set_model/2`, with the same errors. The lock, its deadline, and the cap are as in
  `start/2`, before the load; a locked newest session is not skipped. A session that runs in this Core is
  attached: the call returns it, and concurrent resumes of one id get one result.
  """
  @spec resume(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, model_error() | term()}
  def resume(core \\ Helyx.Core, opts) do
    dir = Keyword.fetch!(opts, :sessions_dir)
    header? = Keyword.has_key?(opts, :id) and not Keyword.has_key?(opts, :cwd)

    with {:ok, cwd} <- if(header?, do: {:ok, nil}, else: fetch_cwd(opts)),
         {:ok, tools} <- Helyx.Tool.specs(core),
         :ok <- Helyx.Tool.check_available(tools),
         concurrent = Helyx.Tool.concurrent(tools),
         {:ok, path, cwd} <- Helyx.Session.File.pick(dir, cwd, Keyword.take(opts, [:id])) do
      id = Path.basename(path, ".jsonl")
      state = %State{id: id, core: core, model: nil, provider: nil, cwd: cwd}
      Server.start(state, {tools, concurrent}, {path, &Server.Open.load(&1, path)})
    end
  end

  defp fetch_cwd(opts), do: opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Input.cwd()

  @doc """
  Subscribes the caller to the session's events, delivered as
  `{:helyx_event, event}`, and returns the session's state as a
  `Helyx.Session.Snapshot`. With `answers: true` the caller can answer the
  asks of tool calls (`answer/3`): a tool that asks gets `{:error,
  :no_client}` when no subscriber gave it. The session adds the caller and builds the
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

  `end_reason/1` maps `reason` to `:stopped` or `:crashed`. A caller that
  does not ack (`ack/2`) gets `{:helyx_end, ref, :slow}` in place of its
  16,385th unacked event, and no event after it. The caller owns the ref.
  The session holds one subscription for each caller pid, so a second
  subscribe, a reconnect for example, gets a new reply and each live event
  once, and a second ref; its replay can repeat events that the caller has. The caller removes the ref it no longer wants with
  `Process.demonitor(ref, [:flush])`.

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

  With `tail: n`, `n` from 1 to 1,000, the snapshot holds the newest messages
  only, cut before a user or an assistant message, and `history/4` gives the
  older ones (`docs/features/session-snapshot.md`, "Tail"). With `after:
  {instance_id, seq}` of the last event that the caller applied, the result
  is `{:ok, {:replay, events}, ref}` when the replay ring holds every event
  after `seq`: those, oldest first, then the live ones. Another instance, a
  `seq` above the session's, or an interval out of the ring gives the
  snapshot of `tail` (`docs/features/replay-ring.md`). A bad `after` is
  `{:error, :invalid_after}`, any other bad option list `{:error, :invalid_limit}`.
  """
  @spec subscribe(t(), keyword()) ::
          {:ok, Snapshot.t() | {:replay, [Helyx.Event.t()]}, reference()}
          | {:error, :session_not_found | :invalid_limit | :invalid_after}
  def subscribe(%__MODULE__{} = session, opts \\ []) do
    case {History.subscribe(opts), pid(session)} do
      {{:error, _} = error, _pid} -> error
      {_opts, nil} -> {:error, :session_not_found}
      {{:ok, opts}, pid} -> Call.subscribe(pid, opts, @call_timeout_ms)
    end
  end

  @doc """
  Acks every event of the caller's subscription up to `seq`: past 16,384
  unacked events the session ends the subscription with `{:helyx_end, ref,
  :slow}`, and the caller demonitors `ref`. An ack is a message and never
  waits; one above the session's `seq` acks nothing. With an event in place
  of `seq` it acks only each 1,024th `seq`: a client in the node passes each
  event that it applies (`docs/features/replay-ring.md`).
  """
  @spec ack(t(), non_neg_integer() | Helyx.Event.t()) :: :ok
  def ack(session, %Helyx.Event{seq: seq}),
    do: if(rem(seq, 1_024) == 0, do: ack(session, seq), else: :ok)

  def ack(%__MODULE__{} = session, seq) when is_integer(seq) and seq >= 0 do
    with pid when is_pid(pid) <- pid(session), do: send(pid, {:ack, self(), seq})
    :ok
  end

  @doc """
  A page of the live transcript, unsaved messages and the results of a
  resume too: the messages before the message with id `before`, oldest
  first, with the cut of `subscribe/2` and `limit: n` (1 to 1,000, default
  200) in place of `tail`. `next` is the id to pass for the page before it,
  nil when `more` is false. A page changes no state of the session.
  """
  @spec history(t(), String.t(), String.t(), keyword()) ::
          {:ok, History.history_page()}
          | {:error, :session_not_found | :instance_changed | :unknown_message | :invalid_limit}
  def history(%__MODULE__{} = session, instance_id, before, opts \\ [])
      when is_binary(instance_id) and is_binary(before) do
    with {:ok, limit} <- History.limit(opts),
         do: call(session, {:history, instance_id, before, limit})
  end

  @max_answer_bytes 16_384

  @doc "The most bytes of the JSON of an answer (`answer/3`)."
  @spec max_answer_bytes() :: pos_integer()
  def max_answer_bytes, do: @max_answer_bytes

  @doc """
  Gives an answer that passes `check_answer/1` to the open ask `ask_id`; the
  session emits `:ask_end`. Any other id, as of an answered ask or one whose
  call or turn ended, gets `{:error, :not_waiting}` (`docs/features/question-tool.md`).
  """
  @spec answer(t(), String.t(), map()) ::
          :ok | {:error, :invalid_answer | :not_waiting | :session_not_found}
  def answer(%__MODULE__{} = session, ask_id, answer) when is_binary(ask_id) do
    with :ok <- check_answer(answer), do: call(session, {:answer, ask_id, answer})
  end

  @doc """
  Checks an answer with no session: a JSON object of valid UTF-8 whose JSON
  is at most #{@max_answer_bytes} bytes. The check stops past the bound, so
  a transport runs it before a worker holds the answer.
  """
  @spec check_answer(term()) :: :ok | {:error, :invalid_answer}
  def check_answer(answer) do
    case Input.json_object(answer, @max_answer_bytes) do
      :ok -> :ok
      :error -> {:error, :invalid_answer}
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
  Sends a prompt. Starts a turn if none is running. A text over
  `max_text_bytes/0` is `{:error, :text_too_large}`, and one that is not
  valid UTF-8 `{:error, :invalid_utf8}`. While an abort waits for the
  hands, the prompt queues as a follow-up, and a full queue returns
  `{:error, :queue_full}`.

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
  takes the checks of `prompt/3`. The queued steers and the sent steers
  that are still open count to 32. At that count the call returns
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
  turn running it starts a turn at once. The text takes the checks of
  `prompt/3`. A full queue returns `{:error, :queue_full}`. An abort or a
  failure of the turn gives it back to the client in a `:queue_dropped` event.
  """
  @spec follow_up(t(), String.t(), keyword()) :: :ok | {:error, send_error()}
  def follow_up(%__MODULE__{} = session, text, opts \\ []) when is_binary(text) and is_list(opts),
    do: send_user(session, :follow_up, text, opts)

  @doc """
  Compacts the context as a turn with no user message: the provider compacts its own history, or
  the Compaction plugin summarizes the transcript (`summary-compaction.md`), or a `:notice` says
  neither did; an error fails the turn. A running turn aborts first, as at `abort/1`, with no
  retry. A second compaction before the end returns `{:error, :turn_running}`. The text takes the
  text checks of `prompt/3`.
  """
  @spec compact(t(), String.t()) ::
          :ok | {:error, :turn_running | :text_too_large | :invalid_utf8 | :session_not_found}
  def compact(%__MODULE__{} = session, instructions \\ "") when is_binary(instructions),
    do: send_text(session, {:compact, instructions}, instructions)

  defp send_user(session, op, text, opts),
    do:
      with({:ok, origin} <- Input.origin(opts), do: send_text(session, {op, text, origin}, text))

  defp send_text(session, request, text),
    do: with(:ok <- Input.text(text), do: call(session, request))

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
    with {:ok, {ref, provider}} <- Input.model(core, string) do
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

  defp call(session, request, timeout \\ @call_timeout_ms),
    do: Call.call(session, request, timeout)
end
