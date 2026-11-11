defmodule Helyx.Event do
  @moduledoc """
  A fact emitted by a session. Clients render from events and hold no other
  session state. Every event carries the ids of its session, its session
  instance, and its turn, and a `seq` that increases by one per event within
  an instance; a client that reconnects drops an event of another instance
  and one at or below its snapshot's `seq` (ADR 0006,
  `docs/features/wire-protocol.md`).

  Types and their `data`:

    * `:turn_start` – `%{origin: :provider | :compaction}`, absent for a user turn
    * `:message_start` – `%{message: Helyx.Message.t()}`, may be partial
    * `:message_update` – `%{text_delta: binary}`, `%{thinking_delta: binary}`, or `%{tool_call: Helyx.Message.ToolCall.t()}`
    * `:message_end` – `%{message: Helyx.Message.t()}`, with `error: String.t() | :aborted` on a failed or aborted turn
    * `:tool_execution_end` – `%{message: Helyx.Message.t()}`, the tool result message
    * `:turn_end` – `%{outcome: :done | :aborted}`, or `%{outcome: :error, error: String.t()}`; once per turn
    * `:queue_update` – `%{steers: _, follow_ups: _, running: _, held: _, waiting: _}` counts.
      Between turns it follows the drain, so the counts are the next turn's queue
    * `:queue_dropped` – `%{messages: [Helyx.Message.t()]}`
    * `:model_change` – `%{model: String.t()}`; the turn id is nil, because the
      change is outside a turn
    * `:tools_change` – `%{activated: [String.t()]}`, the activated deferred tool
      names in drop order (`docs/features/mcp-client.md`)
    * `:resume_id` – `%{provider: String.t(), resume_id: String.t(), lost: boolean, cut: non_neg_integer}`;
      `lost` is true when the provider lost its own session
    * `:steer_unconfirmed` – `%{message: Helyx.Message.t()}`
    * `:compaction` – `%{trigger: :manual | :auto, tokens_before: non_neg_integer | nil, tokens_after: non_neg_integer | nil}`
    * `:notice` – `%{text: String.t()}`, not in the transcript
    * `:ask` – `%{ask_id: String.t(), call_id: String.t(), tool: String.t(), request: map}`
    * `:ask_end` – `%{ask_id: String.t(), outcome: :answered | :ended}`
    * `:ui_block` – `%{call_id: String.t() | nil, key: String.t(), block: Helyx.UIBlock.t()}`,
      not in the transcript; a later block with the same call id and key replaces it
      (`docs/features/ui-blocks.md`)

  The `error` of a failed turn is text for a person: Core writes it from the
  reason, valid UTF-8 of at most 4000 bytes, and logs the reason (ADR 0006 §2).
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
          | :tools_change
          | :resume_id
          | :steer_unconfirmed
          | :compaction
          | :notice
          | :ask
          | :ask_end
          | :ui_block

  @type t :: %__MODULE__{
          type: type(),
          session_id: String.t(),
          instance_id: String.t(),
          turn_id: String.t() | nil,
          seq: pos_integer(),
          data: map()
        }
end
