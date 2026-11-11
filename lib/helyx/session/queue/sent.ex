defmodule Helyx.Session.Queue.Sent do
  @moduledoc false
  # One steer or background end that a turn sent to its provider process, in
  # `Helyx.Session.Queue.sent` in send order, with the ref of its request in
  # `from`.
  #
  # `status`: `:pending` with no answer in the open turn, `{:ended, turn}` with
  # no answer after its turn ended, `:accepted` answered in the turn with no
  # `user_message` yet, `:taken` after the `user_message` with no answer,
  # `:resolved` after its notice.
  defstruct [:from, :id, :item, status: :pending]

  @type t :: %__MODULE__{
          from: reference(),
          id: String.t(),
          item: {:steer, Helyx.Message.t()} | {:end, Helyx.Message.t()},
          status: :pending | {:ended, String.t()} | :accepted | :taken | :resolved
        }
end
