defmodule Helyx.Event do
  @moduledoc """
  A fact emitted by a session. Clients render from events and hold no other
  session state.

  Every event carries the session id, the id of the session instance, the
  turn id, and a sequence number that increases by one per event within an
  instance, so a client can detect gaps. Each start of the session process,
  a resume too, is a new instance: a resume keeps the session id and starts
  `seq` at 0 again, and two Cores can hold one session id. A client that
  reconnects drops every event whose `instance_id` is not the one of its
  snapshot (`Helyx.Session.Snapshot`, ADR 0006).

  Types and their `data`:

    * `:turn_start` – `%{}`, or `%{origin: :provider}` for a turn that the
      provider started by itself, with no user message, or `%{origin:
      :compaction}` for a compaction turn (`Helyx.Session.compact/2`); once
      per turn
    * `:message_start` – `%{message: Helyx.Message.t()}` (may be partial).
      The message has its id here; `:message_end`, the transcript, and the
      snapshot keep it (`docs/features/message-identity.md`)
    * `:message_update` – `%{text_delta: binary}`, `%{thinking_delta: binary}`,
      or `%{tool_call: Helyx.Message.ToolCall.t()}`
    * `:message_end` – `%{message: Helyx.Message.t()}`; on a failed or
      aborted turn a partial assistant message with text only has `:error`
      or `:aborted` as its stop reason, and `data.error` is
      `String.t() | :aborted`: the error text of the failed turn (as in
      `:turn_end`) or `:aborted`; one with a tool call closes with
      `:tool_use`, as at the other closes. Both join the transcript
    * `:tool_execution_end` – `%{message: Helyx.Message.t()}`, the tool
      result message; the calls of concurrent tools run together, each
      other call alone (`docs/features/concurrent-tool-calls.md`)
    * `:turn_end` – `%{outcome: :done | :aborted}`, or `%{outcome: :error,
      error: String.t()}`; once per turn, on every end path. The error text
      is for a person: Core writes it from the reason of the failure,
      with `:stacktrace` in place of each stacktrace in the reason (a
      crash shows as the message of its error), valid UTF-8 of at most
      4000 bytes, and logs the reason (ADR 0006 §2). A client shows it as
      it is. An aborted or failed turn ends after a `:tool_execution_end`
      with an `aborted` error result for each open tool call
    * `:queue_update` – `%{steers: non_neg_integer, follow_ups: non_neg_integer,
      running: non_neg_integer, held: non_neg_integer, waiting:
      non_neg_integer}`, emitted whenever one of the counts changes; the
      drain at a normal turn end goes out between turns, with a nil turn
      id. `running` counts the background runs from their start answer to
      their end; a resume starts it at 0. `held` counts the ends of
      background runs that wait for the next prompt and open no turn by
      themselves: after an abort, a failed turn, a resume, or an end that a
      turn gave back, until a turn that is not a compaction opens.
      `waiting` counts the other ends that no turn took yet: the ends that
      wait for a turn, and the ends that a turn sent and no `user_message`
      took or gave back (`docs/features/background-bash.md`)
    * `:queue_dropped` – `%{texts: [String.t()], messages:
      [Helyx.Message.t()]}`, the user messages with their ids and origins
      and their texts in the same order: an abort or a failed
      turn emptied the queues, and the queued texts go back to the client,
      the steers first, each queue in its order (a steer that the
      provider rejected joined the end of the steers). At most 32
      steers and 32 follow-ups, each as the client sent it, so each at
      most `Helyx.Session.max_text_bytes/0`. It goes out
      only when a text was queued; an abort while the session waits after
      a turn sends it with a nil turn id
    * `:model_change` – `%{model: String.t()}`, the new `provider/model` ref;
      the switch belongs to no turn, so the turn id is always nil
    * `:resume_id` – `%{provider: String.t(), resume_id: String.t(), lost:
      boolean, cut: non_neg_integer}`: in a turn, or in the wait after that
      turn, the provider started fresh with a new resume id. `lost` is true when the provider process
      was started to resume another resume id, which it no longer has, and
      this is its first new resume id since that start; `cut` is the
      number of transcript messages the provider left out of what it sent
      when it started fresh
    * `:steer_unconfirmed` – `%{text: String.t(), message:
      Helyx.Message.t()}`: a steer of a turn that Helyx cannot confirm the
      provider took, with its user message and its text. It
      goes out at the end of the turn, or after it when the answer comes
      late. Helyx does not send it again. The user can send it again.
    * `:compaction` – `%{trigger: :manual | :auto, tokens_before:
      non_neg_integer | nil, tokens_after: non_neg_integer | nil}`: the
      provider compacted the history that it keeps, `:manual` in a
      compaction turn, `:auto` in any other turn; a count is nil when the
      provider does not report it. The transcript does not change
    * `:notice` – `%{text: String.t()}`: a notice of the session (a failed
      abort cleanup or session-file write, a provider that keeps no history
      to compact) for the user, with a fixed text.
      It is not in the transcript, so the model never gets it
  """

  @enforce_keys [:type, :session_id, :instance_id, :turn_id, :seq, :data]
  defstruct [:type, :session_id, :instance_id, :turn_id, :seq, :data]

  @type type ::
          :turn_start
          | :turn_end
          | :message_start
          | :message_update
          | :message_end
          | :tool_execution_end
          | :queue_update
          | :queue_dropped
          | :model_change
          | :resume_id
          | :steer_unconfirmed
          | :compaction
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
