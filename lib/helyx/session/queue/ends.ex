defmodule Helyx.Session.Queue.Ends do
  @moduledoc false
  # The background ends of a session: those that wait, in arrival order, the
  # runs that are still live, whether they wake a turn, and whether an end may
  # go as a steer (`Helyx.Session.Queue`).
  #
  # `wake` is `:off` from an abort, a failed turn, a resume, or an end given
  # back with no turn open, until a turn that is not a compaction opens; `steer`
  # is `:closed` after a rejected end until such a turn opens.
  defstruct items: [], running: 0, wake: :on, steer: :open

  @type t :: %__MODULE__{
          items: [Helyx.Message.t()],
          running: non_neg_integer(),
          wake: :on | :off,
          steer: :open | :closed
        }
end
