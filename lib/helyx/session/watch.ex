defmodule Helyx.Session.Watch do
  @moduledoc false
  # One process for each subscription: it sends the subscriber the end
  # signal when the session ends, or the lost signal when the events
  # Registry loses the registration (docs/features/end-signal.md).
  #
  # It has no link and no supervisor: it monitors the session and the
  # subscriber and stops when either ends, so it never outlives them. It
  # registers itself in the events Registry under its own key, so it is
  # linked to the partition that holds the subscriber's entry and gets no
  # event. This holds because the Registry has one partition
  # (`Helyx.Core`); a duplicate-key Registry picks a partition by the pid.

  use GenServer

  # The wait for each supervisor before the lost signal.
  @await_timeout 5_000

  @enforce_keys [:core, :id, :session_pid, :subscriber]
  defstruct @enforce_keys

  @doc "Starts the watch of `subscriber` for the session process `session_pid` with the id `id`."
  @spec start(Helyx.Core.name(), String.t(), pid(), pid()) :: GenServer.on_start()
  def start(core, id, session_pid, subscriber),
    do:
      GenServer.start(__MODULE__, %__MODULE__{
        core: core,
        id: id,
        session_pid: session_pid,
        subscriber: subscriber
      })

  # `:ignore` when the events Registry is gone or stops with its Core, as in
  # `Helyx.Session.subscribe/1`.
  @impl true
  def init(%__MODULE__{} = state) do
    Process.flag(:trap_exit, true)
    registry = Helyx.Core.events_registry(state.core)
    {:ok, _} = Registry.register(registry, {__MODULE__, state.id}, nil)
    Process.monitor(state.session_pid)
    Process.monitor(state.subscriber)
    {:ok, state}
  rescue
    _ in [ArgumentError, ErlangError] -> :ignore
  end

  # Only the two monitors and the partition link send to the watch. The
  # barrier calls use an alias, so a late reply does not come. Any other
  # message is a bug, and the watch crashes on it.
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %__MODULE__{session_pid: pid} = state) do
    send(state.subscriber, {:helyx_session_end, state.id, end_reason(reason)})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{subscriber: pid} = state),
    do: {:stop, :normal, state}

  # The only link is the Registry partition. The lost signal waits until
  # the supervisor that restarts the Registry has handled the exit ("The
  # watch" in docs/features/end-signal.md): the Registry supervisor, or the
  # Core when the Registry supervisor is gone.
  def handle_info({:EXIT, _partition, _reason}, %__MODULE__{} = state) do
    if await_supervisor(Helyx.Core.events_registry(state.core)) == :down,
      do: await_supervisor(state.core)

    send(state.subscriber, {:helyx_subscription_lost, state.id})
    {:stop, :normal, state}
  end

  # The request of `Supervisor.count_children/1`, which has no timeout. A
  # normal call, not a `:sys` call: a process handles its messages in order,
  # so the call waits behind the exit.
  defp await_supervisor(supervisor) do
    GenServer.call(supervisor, :count_children, @await_timeout)
    :ok
  catch
    # A supervisor that does not answer in time is alive: no second call.
    :exit, {:timeout, _call} -> :ok
    :exit, _reason -> :down
  end

  defp end_reason(reason) when reason in [:normal, :shutdown], do: :stopped
  defp end_reason({:shutdown, _}), do: :stopped
  defp end_reason(_reason), do: :crashed
end
