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
  # The state of one session process and the requests to its provider
  # process: `ask/4` sends a request under its bound of `provider_ms`, and
  # `provider_pid/1` names the current provider process
  # (docs/features/long-lived-harness.md).

  alias Helyx.Session.{ProviderRequest, Queues}
  alias Helyx.Session.Server.ProviderConn

  @enforce_keys [:id, :core, :model, :provider, :cwd]

  # The armed kill of a turn, interrupt, steer, tool result, tool start,
  # or context request: the loop writes one stdio line and replies, well
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
    queues: %Queues{},
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
      tool_start: @provider_reply_ms,
      close: @provider_close_ms,
      idle: 1_800_000
    },
    # The current idle timer (`:erlang.start_timer/3`, see `arm_idle/1` in
    # `Helyx.Session.Server`), or nil.
    idle: nil
  ]

  def provider_pid(%__MODULE__{conn: %ProviderConn{pid: pid}}), do: pid
  def provider_pid(_state), do: nil

  # Sends `request` to the provider process with the bound `key` of `provider_ms`.
  def ask(state, pid, req, key), do: ProviderRequest.ask(pid, req, state.provider_ms[key])
end
