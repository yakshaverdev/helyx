defmodule Helyx.Session.Server.Flow do
  @moduledoc false
  # The phase of one session process: the turn that runs, the wait before the
  # next turn, and the provider process of the session, in one value
  # (docs/features/session-lifecycle.md, "Turn states", "The wait", and
  # "Provider death").
  #
  # Each phase holds only the provider states that it can have, so a pair
  # that the session never makes is not a value here:
  #
  # - `Idle`: no turn, no wait. The provider is gone, connecting, or up.
  # - `Preparing`: a turn before its `{:turn, ...}` (a compaction turn too);
  #   the provider is connecting or up, or `:none` in the one step where it
  #   died and the turn ends (`TurnLoop.provider_down/3`).
  # - `Sending`: a turn from the send of `{:turn, ...}` or
  #   `{:compact, ...}` to its answer; the provider is up, or `:none` in that
  #   same step.
  # - `Live`: a turn from the `:ok` answer to its end; the provider is up, or
  #   `:none` in that same step.
  # - `Waiting`: the wait after a turn. The provider is gone, connecting, up,
  #   or dying; a dying provider holds the wait until its `provider_down`.
  #
  # The three turn phases hold their `%Helyx.Session.Turn{}` in `turn`, so
  # one pattern matches all of them: `%{turn: %Turn{}}`. `swap/1` is the
  # only maker of a turn phase, and it reads `Turn.phase`, so the phase and
  # the turn agree by construction. `Turn.phase` stays: this pass carries
  # the provider, not the turn's own step.

  alias Helyx.Session.Turn

  defmodule Connecting do
    @moduledoc false
    # The provider process that the session asked the hands to start, or one
    # that the hands answered and that has not sent `{:provider_ready, pid}`
    # yet. `start` is the ref of the request; `pid` is nil until the answer
    # of the hands.
    @enforce_keys [:start, :model, :turn]
    defstruct [:pid, :start, :model, :turn, :resumed]

    @type t :: %__MODULE__{
            pid: pid() | nil,
            start: reference(),
            model: Helyx.ModelRef.t(),
            turn: String.t(),
            resumed: String.t() | nil
          }
  end

  defmodule Up do
    @moduledoc false
    # The provider process after its `{:provider_ready, pid}`: it takes a
    # request. `resumed` is the resume id of its start, until its first
    # resume id event (`Helyx.Session.Server.Records.resume_id/4`), or nil.
    @enforce_keys [:pid, :start, :model, :turn]
    defstruct [:pid, :start, :model, :turn, :resumed]

    @type t :: %__MODULE__{
            pid: pid(),
            start: reference(),
            model: Helyx.ModelRef.t(),
            turn: String.t(),
            resumed: String.t() | nil
          }
  end

  defmodule Dying do
    @moduledoc false
    # The provider process from an event that ends it until its
    # `provider_down`: an answer that stops it, a stop by the session, the
    # close of a model switch, or its `:DOWN`. It takes no request, and it
    # holds the wait.
    @enforce_keys [:start, :model, :turn]
    defstruct [:pid, :start, :model, :turn, :resumed]

    @type t :: %__MODULE__{
            pid: pid() | nil,
            start: reference(),
            model: Helyx.ModelRef.t(),
            turn: String.t(),
            resumed: String.t() | nil
          }
  end

  defmodule Idle do
    @moduledoc false
    # No turn and no wait; the session holds no queued work of its own.
    defstruct provider: :none

    @type t :: %__MODULE__{provider: Helyx.Session.Server.Flow.provider()}
  end

  defmodule Preparing do
    @moduledoc false
    # A turn before the send of `{:turn, ...}` or `{:compact, ...}`: its
    # provider process starts, and its prepare Task builds the context.
    @enforce_keys [:turn, :provider]
    defstruct [:turn, :provider]

    @type t :: %__MODULE__{
            turn: Turn.t(),
            provider: Helyx.Session.Server.Flow.provider() | :none
          }
  end

  defmodule Sending do
    @moduledoc false
    # A turn from the send of its request to the answer of the provider.
    @enforce_keys [:turn, :provider]
    defstruct [:turn, :provider]

    @type t :: %__MODULE__{
            turn: Turn.t(),
            provider: Helyx.Session.Server.Flow.provider() | :none
          }
  end

  defmodule Live do
    @moduledoc false
    # A turn from the `:ok` answer of the provider to its end.
    @enforce_keys [:turn, :provider]
    defstruct [:turn, :provider]

    @type t :: %__MODULE__{
            turn: Turn.t(),
            provider: Helyx.Session.Server.Flow.provider() | :none
          }
  end

  defmodule Waiting do
    @moduledoc false
    # The wait after a turn before the next one: the hands' cleanup answer,
    # the answer to an interrupt or an idle close, a dying provider process,
    # and the session's own steps (`Helyx.Session.Server.Wait`).
    @enforce_keys [:wait]
    defstruct [:wait, provider: :none]

    @type t :: %__MODULE__{
            wait: Helyx.Session.Server.Wait.t(),
            provider: Helyx.Session.Server.Flow.provider()
          }
  end

  @type provider :: :none | Connecting.t() | Up.t() | Dying.t()
  @type t :: Idle.t() | Preparing.t() | Sending.t() | Live.t() | Waiting.t()

  @spec idle?(t()) :: boolean()
  def idle?(%Idle{}), do: true
  def idle?(_phase), do: false

  # The connecting provider after its `{:provider_ready, pid}`.
  @spec up(Connecting.t()) :: Up.t()
  def up(%Connecting{} = connecting), do: copy(Up, connecting)

  # The provider process that ends, until its `provider_down`.
  @spec dying(Connecting.t() | Up.t() | Dying.t()) :: Dying.t()
  def dying(%{start: _} = provider), do: copy(Dying, provider)

  # The phase without a provider process: it ended, and the turn ends now.
  @spec no_provider(t()) :: t()
  def no_provider(%{provider: _provider} = phase), do: %{phase | provider: :none}

  # The phase of a turn whose `Turn.phase` changed.
  @spec swap(Preparing.t() | Sending.t() | Live.t()) :: Preparing.t() | Sending.t() | Live.t()
  def swap(%{turn: %Turn{phase: phase} = turn, provider: provider}) do
    struct(variant(phase), %{turn: turn, provider: provider})
  end

  defp variant(:preparing), do: Preparing
  defp variant(:submitting), do: Sending
  defp variant(:submitted), do: Live

  defp copy(module, provider) do
    struct(module, %{
      pid: provider.pid,
      start: provider.start,
      model: provider.model,
      turn: provider.turn,
      resumed: provider.resumed
    })
  end
end
