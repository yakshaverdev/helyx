defmodule Helyx.Session.Queue.Sent do
  @moduledoc false
  # One steer or background end that a turn sent to its provider process,
  # in `Helyx.Session.Queue.sent` in send order, with the ref of its
  # request in `from`.
  #
  # `stage` is `:in_flight` until the item joins the transcript
  # (`:taken`), or the request ends (`:resolved`); `answer` is `:pending`
  # until the provider answers it. `turn` is the id of the turn that sent
  # it once that turn ended, or nil while the turn is still open.
  defstruct [:from, :id, :item, turn: nil, stage: :in_flight, answer: :pending]

  @type t :: %__MODULE__{
          from: reference(),
          id: String.t(),
          item: {:steer, Helyx.Message.t()} | {:end, Helyx.Message.t()},
          turn: String.t() | nil,
          stage: :in_flight | :taken | :resolved,
          answer: :pending | {:accepted, term()}
        }
end
