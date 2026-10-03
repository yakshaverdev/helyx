defmodule Helyx.Event do
  @moduledoc """
  A fact emitted by a session. Clients render from events and hold no other
  session state.

  Every event carries the session id, the id of the session instance, the
  turn id, and a sequence number that increases by one per event within an
  instance, so a client can detect gaps. Each start of the session process,
  a resume too, is a new instance: a resume keeps the session id and starts
  `seq` at 0 again, and two Cores can hold one session id. A client drops
  every event whose `instance_id` is not the one of its snapshot
  (`Helyx.Session.Snapshot`).

  Types and their `data`:

    * `:agent_start` – `%{}`
    * `:turn_start` – `%{}`, or `%{origin: :provider}` for a turn that the
      provider started by itself, with no user message
    * `:message_start` – `%{message: Helyx.Message.t()}` (may be partial)
    * `:message_update` – `%{text_delta: binary}`, `%{thinking_delta: binary}`,
      or `%{tool_call: Helyx.Message.ToolCall.t()}`
    * `:message_end` – `%{message: Helyx.Message.t()}`; on a failed or
      aborted turn the partial assistant message has `:error` or `:aborted`
      as its stop reason and `data.error` holds the reason
    * `:tool_execution_start` – `%{tool_call: Helyx.Message.ToolCall.t()}`
    * `:tool_execution_end` – `%{message: Helyx.Message.t()}`, the tool
      result message; calls run one at a time, in call order
    * `:turn_end` – `%{message: Helyx.Message.t()}`
    * `:agent_end` – `%{stop_reason: atom}`, plus `error: term` on failure;
      an aborted turn ends with `stop_reason: :aborted` after a
      `:tool_execution_end` with an `aborted` error result for each open
      tool call
    * `:queue_update` – `%{steers: non_neg_integer, follow_ups: non_neg_integer}`,
      emitted whenever the session's message queues change; the drain at a
      normal turn end goes out between turns, with a nil turn id
    * `:model_change` – `%{model: String.t()}`, the new `provider/model` ref;
      the switch belongs to no turn, so the turn id is always nil
    * `:provider_session` – `%{provider: String.t(), resume_id:
      String.t(), lost: boolean, cut: non_neg_integer}`: a turn
      started a fresh program session. `lost` is true when the turn asked
      to resume another one that the provider no longer has; `cut` is the
      number of transcript messages the provider left out of what it sent
      to the fresh session
    * `:steer_unconfirmed` – `%{text: String.t()}`: a steer of a turn
      that Helyx cannot confirm the provider took, with its text. It
      goes out at the end of the turn, or after it when the answer comes
      late. Helyx does not send it again. The user can send it again.
    * `:notice` – `%{text: String.t()}`: a notice of the session (a failed
      abort cleanup or session-file write) for the user, with a fixed text.
      It is not in the transcript, so the model never gets it
  """

  @enforce_keys [:type, :session_id, :instance_id, :turn_id, :seq, :data]
  defstruct [:type, :session_id, :instance_id, :turn_id, :seq, :data]

  @type type ::
          :agent_start
          | :agent_end
          | :turn_start
          | :turn_end
          | :message_start
          | :message_update
          | :message_end
          | :tool_execution_start
          | :tool_execution_end
          | :queue_update
          | :model_change
          | :provider_session
          | :steer_unconfirmed
          | :notice

  @type t :: %__MODULE__{
          type: type(),
          session_id: String.t(),
          instance_id: String.t(),
          turn_id: String.t() | nil,
          seq: pos_integer(),
          data: map()
        }
end
