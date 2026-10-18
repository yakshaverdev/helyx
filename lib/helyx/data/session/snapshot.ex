defmodule Helyx.Session.Snapshot do
  @moduledoc """
  The state of a session at one event, as `Helyx.Session.subscribe/2`
  returns it (`docs/features/session-snapshot.md`).

    * `instance_id` – the id of the session instance. A client that
      reconnects drops each event with another `instance_id`: a resume keeps
      the session id and starts `seq` at 0 again, and two Cores can hold one
      session id.
    * `seq` – the seq of the last event sent before the snapshot, 0 if none.
      A client that reconnects drops each later event with a `seq` at or
      below it.
    * `messages` – the transcript, oldest first, or with `tail` its
      newest messages, cut before a user or an assistant message.
    * `more` – true when older messages are not in `messages`; their
      pages come from `Helyx.Session.history/4`, the first with the id of
      the first message of `messages`.
    * `turn` – nil, or the running turn: its `id`, the assistant message
      so far as `partial` (nil before the first stream event), and
      `elapsed_ms`, the milliseconds since the turn started, by the clock
      of the session. A turn whose `:turn_end` waits for the cleanup of the
      hands still runs, with `partial` nil.
    * `model` – the session's `provider/model` ref.
    * `queue` – the counts of the queued steers and follow-ups, the
      running background runs, and the held and waiting background ends, as
      in `queue_update` (`Helyx.Event`).
    * `persisting` – true while the session appends to its file. It is
      false for a session with no file, and after a write failure or the
      loss of the writer lock stopped the saving. So `false` alone does not
      say why. A client that tells the user shows
      `Helyx.Reason.text(:not_saved)`; then a stop before its subscribe
      reaches it too (`docs/features/session-lock.md`).
    * `usage` and `context` – the totals and the context state of every
      message of the transcript, also of those that a tail leaves out
      (`Helyx.Session.Totals`).
    * `asks` – the open asks of tool calls of the turn, oldest first, each
      as the data of its `:ask` event (`Helyx.Event`); a client that can
      answer shows them (`docs/features/question-tool.md`).

  A client works with one Helyx version and is a tolerant reader within it:
  it ignores an unknown event type and an unknown field (ADR 0006, revision
  of 2026-10-03, `docs/adr/0006-client-contract.md`).
  """

  @enforce_keys [
    :instance_id,
    :seq,
    :messages,
    :more,
    :turn,
    :model,
    :queue,
    :persisting,
    :usage,
    :context
  ]
  defstruct @enforce_keys ++ [asks: []]

  @type ask :: %{call_id: String.t(), tool: String.t(), request: map()}

  @type turn :: %{
          id: String.t(),
          partial: Helyx.Message.t() | nil,
          elapsed_ms: non_neg_integer()
        }

  @type t :: %__MODULE__{
          instance_id: String.t(),
          seq: non_neg_integer(),
          messages: [Helyx.Message.t()],
          more: boolean(),
          turn: turn() | nil,
          model: String.t(),
          queue: %{
            steers: non_neg_integer(),
            follow_ups: non_neg_integer(),
            running: non_neg_integer(),
            held: non_neg_integer(),
            waiting: non_neg_integer()
          },
          persisting: boolean(),
          usage: Helyx.Session.Totals.t(),
          context: Helyx.Session.Totals.context() | nil,
          asks: [ask()]
        }
end
