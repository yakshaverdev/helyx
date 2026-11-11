defmodule Helyx.Session.Server.Flow do
  @moduledoc false
  # The phase of one session process: the turn that runs, the wait before the
  # next turn, and the provider process, in one value
  # (docs/features/session-lifecycle.md). The variant is the phase, and each
  # phase holds only the provider states that it can have:
  # `%{turn: %Turn{}}` matches the three turn phases and nothing else.

  defmodule Connecting do
    @moduledoc false
    # The provider process asked of the hands, or answered but not ready yet.
    @enforce_keys [:start, :model, :turn]
    defstruct [:pid, :start, :model, :turn, :resumed]

    @type t :: %__MODULE__{}
  end

  defmodule Up do
    @moduledoc false
    # The provider process after `{:provider_ready, pid}`: it takes a request.
    @enforce_keys [:pid, :start, :model, :turn]
    defstruct [:pid, :start, :model, :turn, :resumed]

    @type t :: %__MODULE__{}
  end

  defmodule Dying do
    @moduledoc false
    # The provider process from an event that ends it until its
    # `provider_down`. It takes no request, and it holds the wait.
    defstruct [:pid, :start, :model, :turn, :resumed]

    @type t :: %__MODULE__{}
  end

  defmodule Idle do
    @moduledoc false
    # No turn and no wait.
    defstruct provider: :none

    @type t :: %__MODULE__{}
  end

  defmodule Preparing do
    @moduledoc false
    # A turn before its request.
    @enforce_keys [:turn, :provider]
    defstruct [:turn, :provider]

    @type t :: %__MODULE__{}
  end

  defmodule Sending do
    @moduledoc false
    # A turn from the send of its request to the answer. `pending` is the ref
    # of that answer, nil after an error answer.
    @enforce_keys [:turn, :provider]
    defstruct [:turn, :provider, :pending]

    @type t :: %__MODULE__{}
  end

  defmodule Live do
    @moduledoc false
    # A turn from the `:ok` answer to its end. `pending` is the ref of an open
    # context request, or nil.
    @enforce_keys [:turn, :provider]
    defstruct [:turn, :provider, :pending]

    @type t :: %__MODULE__{}
  end

  defmodule Waiting do
    @moduledoc false
    # The wait after a turn (`Helyx.Session.Server.Wait`).
    @enforce_keys [:wait]
    defstruct [:wait, provider: :none]

    @type t :: %__MODULE__{}
  end

  @type provider :: :none | Connecting.t() | Up.t() | Dying.t()
  @type t :: Idle.t() | Preparing.t() | Sending.t() | Live.t() | Waiting.t()

  defguard is_turn(phase)
           when is_struct(phase, Preparing) or is_struct(phase, Sending) or
                  is_struct(phase, Live)

  @spec idle?(t()) :: boolean()
  def idle?(%Idle{}), do: true
  def idle?(_phase), do: false

  # The connecting provider after its `{:provider_ready, pid}`.
  @spec up(Connecting.t()) :: Up.t()
  def up(%Connecting{} = connecting), do: copy(Up, connecting)

  # The provider process that ends, until its `provider_down`.
  @spec dying(Connecting.t() | Up.t() | Dying.t()) :: Dying.t()
  def dying(%{start: _} = provider), do: copy(Dying, provider)

  # The phase with no provider process: a start that was refused, or one that
  # ended outside a turn.
  @spec no_provider(Idle.t() | Waiting.t()) :: Idle.t() | Waiting.t()
  def no_provider(%{provider: _provider} = phase), do: %{phase | provider: :none}

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
