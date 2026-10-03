# ProviderConn comes first: the State functions match its struct.
defmodule Helyx.Session.Server.ProviderConn do
  @moduledoc false
  # The provider process of the session: its pid, the model it
  # runs, and whether `init/3` returned (`{:provider_ready, pid}`).
  @enforce_keys [:pid, :model]
  defstruct [:pid, :model, ready: false]
end

defmodule Helyx.Session.Server.State do
  @moduledoc false
  # The state of one session process, the requests to its provider
  # process, and the connection of that process (`conn`, `idle`): its
  # start, its idle timer, and the start of the wait for its end
  # (docs/features/long-lived-harness.md).

  alias Helyx.Session.{Hands, ProviderProcess, ProviderRequest, Queue, Transcript, Turn, Wait}
  alias Helyx.Session.Server.ProviderConn

  @enforce_keys [:id, :core, :model, :provider, :cwd]

  # The armed kill of a turn, interrupt, steer, tool result, or context
  # request: the loop writes one stdio line and replies, well
  # under 10 ms.
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
    tools: [],
    tool_modules: %{},
    transcript: [],
    seq: 0,
    # Each subscriber pid and the session's monitor of it (session-subscribers.md).
    subscribers: %{},
    # `:idle`, the turn in progress (a `%Turn{}`), or the wait before
    # the next turn can start (a `%Wait{}`, see `Helyx.Session.Wait`).
    activity: :idle,
    # The steer state: the queues and the sent steers (`Helyx.Session.Queue`).
    queue: %Queue{},
    # The last resume id per provider id, with the transcript length then.
    resume_ids: %{},
    # The provider process (ADR 0007), a `%ProviderConn{}`, or nil.
    conn: nil,
    # The bounds of the requests to the provider process, in ms: the armed
    # kills (see `Helyx.Session.ProviderProcess`), and `idle`, the time with
    # no turn after which the session sends `:idle_close`. A test seam.
    provider_ms: %{
      turn: @provider_reply_ms,
      interrupt: @provider_reply_ms,
      steer: @provider_reply_ms,
      tool_result: @provider_reply_ms,
      context: @provider_reply_ms,
      close: @provider_close_ms,
      idle: 1_800_000
    },
    # The current idle timer (`:erlang.start_timer/3`, see `arm_idle/1`),
    # or nil.
    idle: nil
  ]

  def provider_pid(%__MODULE__{conn: %ProviderConn{pid: pid}}), do: pid
  def provider_pid(_state), do: nil

  # Sends `request` to the provider process with the bound `key` of `provider_ms`.
  def ask(state, pid, req, key), do: ProviderRequest.ask(pid, req, state.provider_ms[key])

  def base_opts(state), do: [core: state.core, session_id: state.id, cwd: state.cwd]

  # Starts the provider process of the turn under the hands, with the
  # resume id of the transcript. A provider process of another model was
  # closed before the turn (`close_switched/1`).
  def connect(
        %__MODULE__{conn: %ProviderConn{model: model}, activity: %Turn{model: model}} = state
      ),
      do: {:ok, state}

  def connect(%__MODULE__{conn: nil, activity: turn} = state) do
    resumed = Transcript.resumable(state.transcript, state.resume_ids, turn.model.provider)

    args = %{
      provider: turn.provider,
      model: turn.model.model,
      tools: state.tools,
      opts: [resume_id: resumed] ++ base_opts(state),
      session: self()
    }

    with {:ok, pid} <-
           Hands.start_provider(state.hands, turn.provider, ProviderProcess.run(args)) do
      conn = %ProviderConn{pid: pid, model: turn.model}
      {:ok, %{state | conn: conn, activity: %{turn | resumed: resumed}}}
    end
  end

  # Arms the idle timer when the session holds a ready provider process
  # with no turn and no wait. It cancels the earlier timer; a message of
  # it that is already in the mailbox has an old ref.
  def arm_idle(%__MODULE__{activity: :idle, conn: %ProviderConn{ready: true}} = state) do
    if state.idle, do: :erlang.cancel_timer(state.idle)
    %{state | idle: :erlang.start_timer(state.provider_ms.idle, self(), :idle_close)}
  end

  def arm_idle(state), do: state

  # A provider process of another model than the session's closes, and the
  # session waits for its end.
  def close_switched(
        %__MODULE__{model: model, conn: %ProviderConn{pid: pid, model: other}} = state
      )
      when other != model do
    ask(state, pid, :close, :close)
    %{state | conn: nil, activity: %Wait{provider: pid}}
  end

  def close_switched(state), do: state

  # The hands send `:provider_down` only after the release of the provider
  # process's handles, so a turn does not start on a provider process that
  # ended until then: the session waits for it. A provider process that
  # ends after this check ends during the turn, and its `:provider_down`
  # fails the turn (see `Hands.prepare/3`).
  def await_ended_provider(%__MODULE__{conn: %ProviderConn{pid: pid}} = state) do
    if Process.alive?(pid),
      do: state,
      else: %{state | conn: nil, activity: %Wait{provider: pid}}
  end

  def await_ended_provider(state), do: state
end
