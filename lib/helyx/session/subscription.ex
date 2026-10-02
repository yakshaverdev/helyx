defmodule Helyx.Session.Subscription do
  @moduledoc false
  # The caller side of `Helyx.Session.subscribe/1`: the process dictionary
  # entries `{Helyx.Session, core, id} => {ref, pid}` and the end monitors
  # of the calling process (S5 in docs/features/session-subscribers.md).

  # A call of the contract to the session pid: `Helyx.Session` lets only the
  # timeout of a running session exit.
  @type call :: (pid(), term() -> term())

  @spec subscribe(Helyx.Session.t(), pid() | nil, call()) ::
          {:ok, Helyx.Session.Snapshot.t()} | {:error, :session_not_found}
  def subscribe(%Helyx.Session{id: id, core: core}, pid, call) do
    # Tests read this key, so the module is written literally.
    key = {Helyx.Session, core, id}

    # The old monitor goes first, with its signal.
    case Process.delete(key) do
      nil -> :ok
      {old, _pid} -> Process.demonitor(old, [:flush])
    end

    forget_ended()
    flush_end_signals(id)

    case pid do
      nil -> {:error, :session_not_found}
      # The monitor comes before the call, so the real exit reason of the
      # pid of the snapshot is never lost.
      pid -> subscribe_pid(key, Process.monitor(pid, tag: {:helyx_session_end, id}), pid, call)
    end
  end

  # On a failure the unsubscribe follows the call from this process to the
  # same pid, so a live session handles it after the subscribe.
  defp subscribe_pid(key, ref, pid, call) do
    Process.put(key, {ref, pid})

    case call.(pid, {:subscribe, self()}) do
      %Helyx.Session.Snapshot{} = snapshot ->
        {:ok, snapshot}

      {:error, :session_not_found} ->
        unsubscribe(key, ref, pid)
        {:error, :session_not_found}
    end
  catch
    # `call` lets only the timeout of a running session exit.
    :exit, reason ->
      unsubscribe(key, ref, pid)
      :erlang.raise(:exit, reason, __STACKTRACE__)
  end

  defp unsubscribe(key, ref, pid) do
    Process.delete(key)
    Process.demonitor(ref, [:flush])
    send(pid, {:unsubscribe, self()})
  end

  # The entries of ended sessions go, so the dictionary holds one entry for
  # each session that this process still monitors. A monitor leaves the list
  # of this process only when its end signal is in the mailbox, where it
  # stays for the client. A dead pid is not enough: a process is dead before
  # its `:DOWN` arrives.
  defp forget_ended do
    {:monitors, monitors} = Process.info(self(), :monitors)
    monitored = MapSet.new(monitors)

    for {{Helyx.Session, _core, _id} = key, {_ref, pid}} <- Process.get(),
        not MapSet.member?(monitored, {:process, pid}),
        do: Process.delete(key)
  end

  # An end signal for the id whose entry `forget_ended/0` removed: it is of
  # an earlier process, a resume makes a new one.
  defp flush_end_signals(id) do
    receive do
      {{:helyx_session_end, ^id}, _ref, :process, _pid, _reason} -> flush_end_signals(id)
    after
      0 -> :ok
    end
  end
end
