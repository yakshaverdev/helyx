defmodule Helyx.Session.Server.Flow do
  @moduledoc false
  # The phase of one session process: the turn that runs, the wait before the
  # next turn, and the provider process of the session, in one value
  # (docs/features/session-lifecycle.md, "Turn states", "The wait", "Provider
  # death").
  #
  # The variant is the phase. `Preparing` is a turn before its `{:turn, ...}`
  # or `{:compact, ...}`, with the prepare Task in `turn.prepare`; `Sending`
  # is the turn from that send to the answer, with the ref in `pending`;
  # `Live` is the turn from the `:ok` answer to its end, with `pending` set
  # only while a context request is open. `Idle` and `Waiting` hold no turn,
  # so `%{turn: %Turn{}}` matches the three turn phases and nothing else.
  #
  # Each phase holds only the provider states that it can have: a turn that
  # sent its request has an `%Up{}`, and a dying process holds only a wait.
  # The provider's fields are the same in each state, so `pid`, `model`,
  # `turn`, and `resumed` read the same way in all of them.

  defmodule Connecting do
    @moduledoc false
    # The provider process asked of the hands, or one they answered that has
    # not sent `{:provider_ready, pid}` yet. `pid` is nil until the answer.
    @enforce_keys [:start, :model, :turn]
    defstruct [:pid, :start, :model, :turn, :resumed]

    @type t :: %__MODULE__{}
  end

  defmodule Up do
    @moduledoc false
    # The provider process after `{:provider_ready, pid}`: it takes a
    # request. `resumed` is the resume id of its start, until its first
    # resume id event, or nil.
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
    # A turn before its request. The provider is `:none` before the start,
    # and may be connecting, up, or dying.
    @enforce_keys [:turn, :provider]
    defstruct [:turn, :provider]

    @type t :: %__MODULE__{}
  end

  defmodule Sending do
    @moduledoc false
    # A turn from the send of `{:turn, ...}` or `{:compact, ...}` to the
    # answer. `pending` is the ref of that answer, nil after an error answer.
    @enforce_keys [:turn, :provider]
    defstruct [:turn, :provider, :pending]

    @type t :: %__MODULE__{}
  end

  defmodule Live do
    @moduledoc false
    # A turn from the `:ok` answer to its end. `pending` is the ref of an
    # open context request, or nil.
    @enforce_keys [:turn, :provider]
    defstruct [:turn, :provider, :pending]

    @type t :: %__MODULE__{}
  end

  defmodule Waiting do
    @moduledoc false
    # The wait after a turn: the hands' cleanup answer, the answer to an
    # interrupt or an idle close, and a provider process that ends
    # (`Helyx.Session.Server.Wait`).
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
