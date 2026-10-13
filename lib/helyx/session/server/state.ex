defmodule Helyx.Session.Server.ProviderConn do
  @moduledoc false
  # The provider process of the session: its pid, the model it runs, the
  # id of the turn that started it, and its `status`: `:starting` until
  # `{:provider_ready, pid}`, then `:ready`, and `:ending` from the events
  # that end it until its `provider_down` (docs/features/session-lifecycle.md,
  # "Provider death"). `resumed` is the resume id that its start passed,
  # until its first resume id event (`Records.resume_id/4`), or nil.
  @enforce_keys [:pid, :model, :turn]
  defstruct [:pid, :model, :turn, :resumed, status: :starting]

  @type t :: %__MODULE__{
          pid: pid(),
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
    :file,
    # The registered ModelContext and Compaction plugins, or nil for none.
    :model_context,
    :compaction,
    # The checked tool specs of `Helyx.Tool.specs/1` at session start,
    # which every provider call uses, and the tool module by name for the
    # hands.
    tool_specs: [],
    tool_modules: %{},
    transcript: [],
    seq: 0,
    # Each subscriber pid and the session's monitor of it (session-subscribers.md).
    subscribers: %{},
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
    # The armed kill of the prepare Task (`TurnLoop`), in ms. A test seam.
    prepare_ms: 10_000,
    # The current idle timer (`:erlang.start_timer/3`, see
    # `TurnLoop.arm_idle/1`), or nil.
    idle: nil,
    # The instructions of a compaction that waits for the end of the wait,
    # or nil (docs/features/harness-compaction.md).
    pending_compact: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          instance_id: String.t() | nil,
          core: Helyx.Core.name(),
          model: Helyx.ModelRef.t(),
          provider: module(),
          cwd: Path.t(),
          hands: pid() | nil,
          file: Helyx.Session.File.t() | nil,
          model_context: module() | nil,
          compaction: module() | nil,
          tool_specs: [Helyx.Tool.spec()],
          tool_modules: %{String.t() => module()},
          transcript: [Helyx.Message.t()],
          seq: non_neg_integer(),
          subscribers: %{pid() => reference()},
          activity: :idle | Turn.t() | Wait.t(),
          queue: Queue.t(),
          resume_ids: %{String.t() => {String.t(), non_neg_integer()}},
          conn: ProviderConn.t() | nil,
          provider_ms: %{reply: pos_integer(), close: pos_integer(), idle: pos_integer()},
          prepare_ms: pos_integer(),
          idle: reference() | nil,
          pending_compact: String.t() | nil
        }

  # Sends `request` to the provider process with the bound `key` of `provider_ms`.
  def ask(state, pid, req, key), do: ProviderRequest.ask(pid, req, state.provider_ms[key])
end
