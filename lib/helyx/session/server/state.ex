defmodule Helyx.Session.Server.State do
  @moduledoc false
  # The state of one session process, and the requests to its provider
  # process. `Helyx.Session.Server.TurnLoop` makes the transitions of `phase`
  # (`Helyx.Session.Server.Flow`), with the turn cleanup in
  # `Helyx.Session.Server.Wait` (docs/features/session-lifecycle.md).

  alias Helyx.Session.{ProviderRequest, Queue}
  alias Helyx.Session.Server.Flow

  @enforce_keys [:id, :core, :model, :provider, :cwd]

  # A reply takes well under 10 ms, so 2 s is the margin.
  @provider_reply_ms 2_000
  # The armed kill of the prepare Task, in ms; recall counts in it
  # (`Helyx.Session.Recall`).
  @prepare_ms 10_000
  def prepare_ms, do: @prepare_ms
  @deadline_ms %{prepare: @prepare_ms, open: 25_000, idle_stop: nil}
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
    :background_dir,
    # The session file: `:never` before the session has a file; `{:saving,
    # file}` while each append goes to disk; `{:stopped, unsaved_from}` after
    # a failed write (`Records`).
    {:save, :never},
    # The sync worker of the instance (`Helyx.Session.Sync`), or nil with no
    # Memory plugin. Before `Sync.open/1`, nil or `{:replay, messages}`.
    :sync,
    plugins: %{model_context: nil, compaction: nil, memory: nil},
    registry: %Helyx.Session.ToolRegistry{},
    sources: %{},
    # The checked options of the start or the resume for each `init/3`
    # (`init_opts/3`) (docs/features/output-limit.md).
    init: %{provider_opts: [], max_output_tokens: nil},
    transcript: [],
    # Each subscriber pid with the session's monitor of it, the ref of its
    # last subscribe, the seq up to which it acked
    # (docs/features/replay-ring.md), and whether it can answer an ask.
    subscribers: %{},
    ring: %Helyx.Session.Ring{},
    phase: %Flow.Idle{},
    queue: %Queue{},
    # The last resume id per provider id, with the number of assistant
    # messages then.
    resume_ids: %{},
    # The bounds of the requests to the provider process, in ms: the armed
    # kills `reply` and `close` (`Helyx.Session.ProviderProcess`), and
    # `idle`, the time with no turn after which the session sends
    # `:idle_close`. A test seam.
    provider_ms: %{
      reply: @provider_reply_ms,
      close: @provider_close_ms,
      idle: 1_800_000
    },
    # The deadlines of the session's own steps, in ms: `prepare`, the armed
    # kill of the prepare Task (`TurnLoop`), and `open`, the base of the
    # deadline of the load, which grows with the file
    # (docs/features/session-lock.md). `idle_stop` is the Core option of the
    # idle stop, or nil (docs/features/idle-unload.md). A test seam.
    deadline_ms: @deadline_ms,
    # The current idle timer (`:erlang.start_timer/3`, see
    # `Connect.arm_idle/1`), or nil.
    idle: nil,
    # The timer of the idle stop (docs/features/idle-unload.md), of the
    # pattern of `idle`. Its time is `deadline_ms.idle_stop`.
    idle_stop: nil,
    # The instructions of a compaction that waits for the end of the wait, or
    # nil (docs/features/harness-compaction.md).
    pending_compact: nil,
    # The stored summary, and the summary call that runs or ends, or nil
    # (docs/features/summary-compaction.md).
    summary: nil,
    summary_call: nil,
    # The last compaction: the id of the last transcript message before it
    # and its `tokens_after`, or nil (`Helyx.Session.Totals.of/2`).
    compacted: nil,
    # The caller of `Helyx.Sessions.stop/1`, which `terminate/2` answers with
    # the stop report, or nil.
    stopper: nil,
    # The key of the last Live that the session feed sent, or nil
    # (`Helyx.Session.Server.Feed`).
    fed: nil
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
          save:
            :never
            | {:saving, Helyx.Session.File.t()}
            | {:stopped, non_neg_integer()},
          plugins: %{
            model_context: module() | nil,
            compaction: module() | nil,
            memory: module() | nil
          },
          sync: pid() | {:replay, [Helyx.Message.t()]} | nil,
          registry: Helyx.Session.ToolRegistry.t(),
          sources: %{pid() => module()},
          init: %{provider_opts: keyword(), max_output_tokens: pos_integer() | nil},
          transcript: [Helyx.Message.t()],
          subscribers: %{pid() => {reference(), reference(), non_neg_integer(), boolean()}},
          ring: Helyx.Session.Ring.t(),
          phase: Flow.t(),
          queue: Queue.t(),
          resume_ids: %{String.t() => Helyx.Session.Transcript.label()},
          provider_ms: %{reply: pos_integer(), close: pos_integer(), idle: pos_integer()},
          deadline_ms: %{
            prepare: pos_integer(),
            open: pos_integer(),
            idle_stop: pos_integer() | nil
          },
          idle: reference() | nil,
          idle_stop: reference() | nil,
          pending_compact: String.t() | nil,
          summary: Helyx.Summary.t() | nil,
          summary_call: Helyx.Session.Server.Summary.t() | nil,
          compacted: Helyx.Session.Totals.compaction() | nil,
          stopper: GenServer.from() | nil,
          fed: {String.t(), boolean(), Helyx.ModelRef.t()} | nil
        }

  # The deadlines of a new session of `core`: the defaults, with the idle
  # stop of the Core option.
  @spec deadline_ms(Helyx.Core.name()) :: map()
  def deadline_ms(core) do
    %{@deadline_ms | idle_stop: Helyx.Core.config(core, :idle_stop_ms)}
  end

  def ask(state, pid, req, key), do: ProviderRequest.ask(pid, req, state.provider_ms[key])

  # The options of every plugin call of the session.
  def base_opts(state), do: [core: state.core, session_id: state.id, cwd: state.cwd]

  # The model is the one of its turn, not of a later switch.
  def tool_context(state, model) do
    %{
      session_id: state.id,
      model: Helyx.ModelRef.to_string(model),
      provider_opts: state.init.provider_opts,
      model_context: state.plugins.model_context
    }
  end

  # Those of Core come first, so a provider option of the same name does not
  # change one.
  def init_opts(state, resume_id, resume_usage) do
    %{provider_opts: provider_opts, max_output_tokens: limit} = state.init

    [resume_id: resume_id, resume_usage: resume_usage, max_output_tokens: limit] ++
      base_opts(state) ++ provider_opts
  end
end
