defmodule Helyx.Session.Server.ProviderConn do
  @moduledoc false
  # The provider process of the session: its pid, the model it runs, the
  # id of the turn that started it, and its `status`: `:starting` until
  # `{:provider_ready, pid}`, then `:ready`, and `:ending` from the events
  # that end it until its `provider_down` (docs/features/session-lifecycle.md,
  # "Provider death"). `resumed` is the resume id that its start passed,
  # until its first resume id event (`Records.resume_id/4`), or nil.
  # `start` is the ref of the start request; `pid` is nil until the answer
  # of the hands.
  @enforce_keys [:start, :model, :turn]
  defstruct [:pid, :start, :model, :turn, :resumed, status: :starting]

  @type t :: %__MODULE__{
          pid: pid() | nil,
          start: reference(),
          model: Helyx.ModelRef.t(),
          turn: String.t(),
          resumed: String.t() | nil,
          status: :starting | :ready | :ending
        }
end

defmodule Helyx.Session.Server.State do
  @moduledoc false
  # The state of one session process, and the requests to its provider
  # process. `Helyx.Session.Server.TurnLoop` makes the transitions of
  # `activity` and `conn`, with the turn cleanup in
  # `Helyx.Session.Server.Wait` (docs/features/session-lifecycle.md).

  alias Helyx.Session.{ProviderRequest, Queue, Turn}
  alias Helyx.Session.Server.{ProviderConn, Wait}

  @enforce_keys [:id, :core, :model, :provider, :cwd]

  # The armed kill of a turn, interrupt, steer, tool result, or context
  # request: a reply takes well under 10 ms, so 2 s is the margin.
  @provider_reply_ms 2_000
  # The armed kill of the prepare Task, in ms; recall counts in it
  # (`Helyx.Session.Recall`).
  @prepare_ms 10_000
  def prepare_ms, do: @prepare_ms
  # The armed kill of a close: end of input, then the exit.
  @provider_close_ms 5_000
  def provider_close_ms, do: @provider_close_ms

  defstruct [
    :id,
    # A new id for each start of the process, a resume too (`Helyx.Event`).
    :instance_id,
    :core,
    :model,
    :provider,
    :cwd,
    :hands,
    # The folder of the background output files (`Helyx.Session.Hands`).
    :background_dir,
    :file,
    # The port of the session file's writer lock, or nil with no file or
    # after the lock is lost (`Helyx.Session.Lock`).
    :lock,
    # The registered ModelContext, Compaction, and Memory plugins, or nil
    # for none.
    :model_context,
    :compaction,
    :memory,
    # The sync worker of the instance (`Helyx.Session.Sync`), or nil with
    # no Memory plugin. Before `Sync.open/1`, nil or `{:replay, messages}`,
    # the messages that a resume decoded (docs/features/memory.md).
    :sync,
    # The index of the first transcript message that the file does not
    # hold after a failed write (`Records.stop_saving/3`), else nil: every
    # message is saved, or none when the session has no file.
    :unsaved_from,
    # The checked tool specs of `Helyx.Tool.specs/1` at session start,
    # which every provider call uses, and by name each tool module, for the
    # hands, with its flag of `Helyx.Tool.concurrent/1`, for the tool queue.
    tool_specs: [],
    tools: %{},
    transcript: [],
    # Each subscriber pid with the session's monitor of it, the ref of its
    # last subscribe, and the seq up to which it acked (replay-ring.md).
    subscribers: %{},
    # The seq of the newest event, and the newest events of the session
    # (`Helyx.Session.Ring`).
    ring: %Helyx.Session.Ring{},
    # `:idle`, the turn in progress (a `%Turn{}`), or the wait before
    # the next turn can start (a `%Wait{}`).
    activity: :idle,
    # The steer state: the queues and the sent steers (`Helyx.Session.Queue`).
    queue: %Queue{},
    # The last resume id per provider id, with the number of assistant
    # messages then.
    resume_ids: %{},
    # The provider process (ADR 0007), a `%ProviderConn{}`, or nil.
    conn: nil,
    # The bounds of the requests to the provider process, in ms: the armed
    # kills `reply` and `close` (see `Helyx.Session.ProviderProcess`), and
    # `idle`, the time with no turn after which the session sends
    # `:idle_close`. A test seam.
    provider_ms: %{
      reply: @provider_reply_ms,
      close: @provider_close_ms,
      idle: 1_800_000
    },
    # The deadlines of the session's own steps, in ms: `prepare`, the armed
    # kill of the prepare Task (`TurnLoop`), and `open`, the deadline of the
    # open, under the 30 s that #656 plans for a wire client of a start, and
    # under `Stop.shutdown_ms/0` (session-lock.md, #665). A test seam.
    deadline_ms: %{prepare: @prepare_ms, open: 25_000},
    # The current idle timer (`:erlang.start_timer/3`, see
    # `TurnLoop.arm_idle/1`), or nil.
    idle: nil,
    # The instructions of a compaction that waits for the end of the wait,
    # or nil (docs/features/harness-compaction.md).
    pending_compact: nil,
    # The stored summary, and the summary call that runs or ends, or nil
    # (docs/features/summary-compaction.md).
    summary: nil,
    summary_call: nil,
    # The last compaction: the id of the last transcript message before it
    # and its `tokens_after`, or nil (`Helyx.Session.Totals.of/2`).
    compacted: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          instance_id: String.t() | nil,
          core: Helyx.Core.name(),
          model: Helyx.ModelRef.t(),
          provider: module(),
          cwd: Path.t(),
          hands: pid() | nil,
          background_dir: Path.t() | nil,
          file: Helyx.Session.File.t() | nil,
          lock: port() | nil,
          model_context: module() | nil,
          compaction: module() | nil,
          memory: module() | nil,
          sync: pid() | {:replay, [Helyx.Message.t()]} | nil,
          unsaved_from: non_neg_integer() | nil,
          tool_specs: [Helyx.Tool.spec()],
          tools: %{String.t() => {module(), boolean()}},
          transcript: [Helyx.Message.t()],
          subscribers: %{pid() => {reference(), reference(), non_neg_integer()}},
          ring: Helyx.Session.Ring.t(),
          activity: :idle | Turn.t() | Wait.t(),
          queue: Queue.t(),
          resume_ids: %{String.t() => Helyx.Session.Transcript.label()},
          conn: ProviderConn.t() | nil,
          provider_ms: %{reply: pos_integer(), close: pos_integer(), idle: pos_integer()},
          deadline_ms: %{prepare: pos_integer(), open: pos_integer()},
          idle: reference() | nil,
          pending_compact: String.t() | nil,
          summary: Helyx.Summary.t() | nil,
          summary_call: Helyx.Session.Server.Summary.t() | nil,
          compacted: Helyx.Session.Totals.compaction() | nil
        }

  # Sends `request` to the provider process with the bound `key` of `provider_ms`.
  def ask(state, pid, req, key), do: ProviderRequest.ask(pid, req, state.provider_ms[key])

  # The options of every plugin call of the session.
  def base_opts(state), do: [core: state.core, session_id: state.id, cwd: state.cwd]
end
