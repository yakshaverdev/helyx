defmodule Helyx.Session.Snapshot do
  @moduledoc """
  The state of a session at one event, as `Helyx.Session.subscribe/1`
  returns it.

    * `instance_id` – the id of the session instance. A client that
      reconnects drops each event with another `instance_id`: a resume keeps
      the session id and starts `seq` at 0 again, and two Cores can hold one
      session id.
    * `seq` – the seq of the last event sent before the snapshot, 0 if none.
      A client that reconnects drops each later event with a `seq` at or
      below it.
    * `messages` – the transcript, oldest first.
    * `turn` – nil, or the running turn: its `id`, and the assistant
      message so far as `partial` (nil before the first stream event). A
      turn whose `:turn_end` waits for the cleanup of the hands still runs,
      with `partial` nil.
    * `model` – the session's `provider/model` ref.
    * `queue` – the counts of the queued steers and follow-ups, the
      running background runs, and the held and waiting background ends, as
      in `queue_update` (`Helyx.Event`).
    * `lock_lost` – true after the session lost the writer lock of its
      file; false while it holds the lock, and for a session with no file.
      A client shows `Helyx.Reason.text(:lock_lost)`, the text of the
      lost-lock notice, for a snapshot with `lock_lost: true`, so a loss
      before its subscribe reaches it too (`docs/features/session-lock.md`).

  A client works with one Helyx version and is a tolerant reader within it:
  it ignores an unknown event type and an unknown field (ADR 0006, revision
  of 2026-10-03, `docs/adr/0006-client-contract.md`).
  """

  @enforce_keys [:instance_id, :seq, :messages, :turn, :model, :queue, :lock_lost]
  defstruct [:instance_id, :seq, :messages, :turn, :model, :queue, :lock_lost]

  @type turn :: %{id: String.t(), partial: Helyx.Message.t() | nil}

  @type t :: %__MODULE__{
          instance_id: String.t(),
          seq: non_neg_integer(),
          messages: [Helyx.Message.t()],
          turn: turn() | nil,
          model: String.t(),
          queue: %{
            steers: non_neg_integer(),
            follow_ups: non_neg_integer(),
            running: non_neg_integer(),
            held: non_neg_integer(),
            waiting: non_neg_integer()
          },
          lock_lost: boolean()
        }
end
