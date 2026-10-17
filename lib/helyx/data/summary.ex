defmodule Helyx.Summary do
  @moduledoc """
  The summary of the older part of a transcript: its text, the id of the
  first message that the model context keeps after it, and the token
  estimate of the context before it. The session stores the last one and
  passes it to the Compaction plugin in `opts[:summary]`
  (`docs/features/summary-compaction.md`).
  """

  # The most bytes of a summary, in the session and on the disk.
  @max_bytes 65_536

  @enforce_keys [:text, :first_kept_id, :tokens_before]
  defstruct [:text, :first_kept_id, :tokens_before]

  @type t :: %__MODULE__{
          text: String.t(),
          first_kept_id: String.t(),
          tokens_before: non_neg_integer()
        }

  @doc "The most bytes of a summary text: #{@max_bytes}."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  defmodule Plan do
    @moduledoc """
    The summary that a Compaction plugin asks for: the context of the
    summary call, the id of the first message to keep, and the token
    estimate of the context now. Core checks it at the boundary
    (`docs/features/summary-compaction.md`).
    """

    @enforce_keys [:context, :first_kept_id, :tokens_before]
    defstruct [:context, :first_kept_id, :tokens_before]

    @type t :: %__MODULE__{
            context: Helyx.Context.t(),
            first_kept_id: String.t(),
            tokens_before: non_neg_integer()
          }
  end
end
