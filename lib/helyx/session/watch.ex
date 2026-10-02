defmodule Helyx.Session.Watch do
  @moduledoc false
  # One process for each subscription: it sends the subscriber the end
  # signal when the session ends, or the lost signal when the events
  # Registry loses the registration (docs/features/end-signal.md).
  #
  # It has no link and no supervisor: it monitors the session and the
  # subscriber and stops when either ends. The one exception is the wait
  # before the lost signal, which ends when the Registry is back or will
  # not come back, when the subscriber ends, or with a kill by the next
  # subscribe of the caller. It registers itself in the events Registry under its own key, so it is
  # linked to the partition that holds the subscriber's entry and gets no
  # event. This holds because the Registry has one partition
  # (`Helyx.Core`); a duplicate-key Registry picks a partition by the pid.

  use GenServer

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
  # the Registry is back ("The watch" in docs/features/end-signal.md). A
  # subscriber that ends during a pause of the wait gets no signal.
  def handle_info({:EXIT, partition, _reason}, %__MODULE__{} = state) do
    if await_restart(state, partition) == :signal,
      do: send(state.subscriber, {:helyx_subscription_lost, state.id})

    {:stop, :normal, state}
  end

  # The pause between two checks of the Registry. The wait is the time a
  # supervisor takes to handle an exit, or a restart that ends at the
  # restart limit, so the pause adds little to the lost signal.
  @check_ms 10

  # Waits until the events Registry has a live partition that is not the
  # dead one: `:signal`. The exit of the partition can reach the watch
  # before the Registry supervisor: signals from two processes have no
  # order. So the watch checks the pid, not the order. `:signal` also when
  # the Registry does not come back (stopped, or the Core is gone), so the
  # subscriber learns of the loss at once; `:subscriber_down` when the
  # subscriber ends.
  defp await_restart(state, dead) do
    if registry_state(state.core, dead) == :wait do
      subscriber = state.subscriber

      receive do
        {:DOWN, _ref, :process, ^subscriber, _reason} -> :subscriber_down
      after
        @check_ms -> await_restart(state, dead)
      end
    else
      :signal
    end
  end

  # Each check is a call with no timeout: it ends with the answer or the
  # exit of the supervisor, which then answers after the exits it has.
  defp registry_state(core, dead) do
    case Supervisor.which_children(Helyx.Core.events_registry(core)) do
      # A new partition that died before this check is not back.
      [{_id, pid, _type, _modules}] when is_pid(pid) and pid != dead ->
        if Process.alive?(pid), do: :signal, else: :wait

      [{_id, child, _type, _modules}] when child in [dead, :restarting] ->
        :wait

      _stopped_or_deleted ->
        :signal
    end
  catch
    # The Registry supervisor is gone: the Core restarts it, or not.
    :exit, _reason -> registry_child(core)
  end

  defp registry_child(core) do
    case List.keyfind(Supervisor.which_children(core), Helyx.Core.events_registry(core), 0) do
      {_id, child, _type, _modules} when is_pid(child) or child == :restarting -> :wait
      _stopped_or_deleted -> :signal
    end
  catch
    :exit, _reason -> :signal
  end

  defp end_reason(reason) when reason in [:normal, :shutdown], do: :stopped
  defp end_reason({:shutdown, _}), do: :stopped
  defp end_reason(_reason), do: :crashed
end
