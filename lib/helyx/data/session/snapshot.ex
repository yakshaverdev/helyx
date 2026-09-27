defmodule Helyx.Session.Snapshot do
  @moduledoc """
  The state of a session at one event, as `Helyx.Session.subscribe/1`
  returns it.

    * `contract_version` – the version of the client contract, 1 now.
    * `instance_id` – the id of the session instance. A client drops each
      event with another `instance_id`: a resume keeps the session id and
      starts `seq` at 0 again, and two Cores can hold one session id.
    * `seq` – the seq of the last event sent before the snapshot, 0 if none.
      A client drops each later event with a `seq` at or below it.
    * `messages` – the transcript, oldest first.
    * `turn` – nil, or the running turn: its `id`, the assistant message
      so far as `partial` (nil before the first stream event), and in
      `running` the ids of the tool calls that have started and have no
      result yet.
    * `model` – the session's `provider/model` ref.
    * `queue` – the counts of the queued steers and follow-ups.

  The version rules are in ADR 0006, section 5
  (`docs/adr/0006-client-contract.md`). Within one version, the server adds
  a field, an event type, or a value only when a client that ignores it
  still behaves correctly. Any other change raises the version: a removal, a
  rename, a change of meaning, or a new value that a client must understand.
  A client that does not support the version of a snapshot says so and does
  not render the session.
  """

  @enforce_keys [:instance_id, :seq, :messages, :turn, :model, :queue]
  defstruct [:instance_id, :seq, :messages, :turn, :model, :queue, contract_version: 1]

  @type turn :: %{id: String.t(), partial: Helyx.Message.t() | nil, running: [String.t()]}

  @type t :: %__MODULE__{
          contract_version: pos_integer(),
          instance_id: String.t(),
          seq: non_neg_integer(),
          messages: [Helyx.Message.t()],
          turn: turn() | nil,
          model: String.t(),
          queue: %{steers: non_neg_integer(), follow_ups: non_neg_integer()}
        }
end
