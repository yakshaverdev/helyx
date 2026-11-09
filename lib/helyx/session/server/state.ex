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
    # The sync worker of the instance (`Helyx.Session.Sync`), or nil with
    # no Memory plugin. Before `Sync.open/1`, nil or `{:replay, messages}`,
    # the messages that a resume decoded (docs/features/memory.md).
    :sync,
    # The index of the first transcript message that the file does not
    # hold after a failed write (`Records.stop_saving/3`), else nil: every
    # message is saved, or none when the session has no file.
    :unsaved_from,
    # The registered ModelContext, Compaction, and Memory plugins by
    # interface, each nil for none.
    plugins: %{model_context: nil, compaction: nil, memory: nil},
    # The tools and the tool sources of the session
    # (`Helyx.Session.ToolRegistry`), and the source process of each
    # source that runs, by pid (`Helyx.Session.Server.Sources`).
    registry: %Helyx.Session.ToolRegistry{},
    sources: %{},
    # The checked options of the start or the resume for each `init/3`
    # (`init_opts/3`): `provider_opts`, and `max_output_tokens`, the limit
    # of the start or nil (docs/features/output-limit.md).
    init: %{provider_opts: [], max_output_tokens: nil},
    transcript: [],
    # Each subscriber pid with the session's monitor of it, the ref of its
    # last subscribe, the seq up to which it acked (replay-ring.md), and
    # whether it can answer an ask.
    subscribers: %{},
    # The seq of the newest event, and the newest events of the session
    # (`Helyx.Session.Ring`).
    ring: %Helyx.Session.Ring{},
    # `:idle`, the turn in progress (a `%Turn{}`), or the wait before
    # the next turn can start (a `%Wait{}`).
    activity: :idle,
    # The steer state: the queues and the sent steers, and a hook's
    # continue with the count of turns in a row (`Helyx.Session.Queue`).
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
    # lock take and the base of the deadline of the load, which grows with
    # the file (session-lock.md, row "wait of the caller", #665, #834). A
    # test seam.
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
    compacted: nil,
    # The caller of `Helyx.Sessions.stop/1`, which `terminate/2` answers
    # with the stop report, or nil.
    stopper: nil
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
          plugins: %{
            model_context: module() | nil,
            compaction: module() | nil,
            memory: module() | nil
          },
          sync: pid() | {:replay, [Helyx.Message.t()]} | nil,
          unsaved_from: non_neg_integer() | nil,
          registry: Helyx.Session.ToolRegistry.t(),
          sources: %{pid() => module()},
          init: %{provider_opts: keyword(), max_output_tokens: pos_integer() | nil},
          transcript: [Helyx.Message.t()],
          subscribers: %{pid() => {reference(), reference(), non_neg_integer(), boolean()}},
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
          compacted: Helyx.Session.Totals.compaction() | nil,
          stopper: GenServer.from() | nil
        }

  # Sends `request` to the provider process with the bound `key` of `provider_ms`.
  def ask(state, pid, req, key), do: ProviderRequest.ask(pid, req, state.provider_ms[key])

  # The options of every plugin call of the session.
  def base_opts(state), do: [core: state.core, session_id: state.id, cwd: state.cwd]

  # The context of a call or an approval chain (`Helyx.Tool.context/0`):
  # the model is the one of its turn, not of a later switch.
  def tool_context(state, model) do
    %{
      session_id: state.id,
      model: Helyx.ModelRef.to_string(model),
      provider_opts: state.init.provider_opts,
      model_context: state.plugins.model_context
    }
  end

  # The options of a provider's `init/3`: those of Core first, so a
  # provider option of the same name does not change one.
  def init_opts(state, resume_id, resume_usage) do
    %{provider_opts: provider_opts, max_output_tokens: limit} = state.init

    [resume_id: resume_id, resume_usage: resume_usage, max_output_tokens: limit] ++
      base_opts(state) ++ provider_opts
  end
end
