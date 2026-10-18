defmodule Helyx.Session.Call do
  @moduledoc false
  # A call of the contract of `Helyx.Session`. The session is not running
  # when no process has the id, or when the process is dead (the Registry
  # drops its name asynchronously) or dies during the call. A timeout still
  # exits, also for a session that stopped with the reason `:timeout`
  # (ADR 0006).

  def call(session, request, timeout) do
    case Helyx.Session.pid(session) do
      nil -> {:error, :session_not_found}
      pid -> call_pid(pid, request, timeout)
    end
  end

  def call_pid(pid, request, timeout) do
    GenServer.call(pid, with_deadline(request, timeout), timeout)
  catch
    :exit, {:timeout, _call} = reason ->
      :erlang.raise(:exit, reason, __STACKTRACE__)

    :exit, {_reason, _call} ->
      {:error, :session_not_found}
  end

  # The subscribe of `Helyx.Session.subscribe/2`. The monitor comes before
  # the call, so the real exit reason of the pid of the reply is never lost.
  def subscribe(pid, opts, timeout), do: subscribe(pid, opts, timeout, Process.monitor(pid))

  # On a failure the unsubscribe follows the call from this process to the
  # same pid, so a live session handles it after the subscribe.
  defp subscribe(pid, opts, timeout, ref) do
    case call_pid(pid, {:subscribe, self(), ref, opts}, timeout) do
      %Helyx.Session.Snapshot{} = snapshot ->
        {:ok, snapshot, ref}

      {:replay, _events} = replay ->
        {:ok, replay, ref}

      {:error, :session_not_found} ->
        unsubscribe(pid, ref)
        {:error, :session_not_found}
    end
  catch
    # `call_pid/3` lets only the timeout of a running session exit.
    :exit, reason ->
      unsubscribe(pid, ref)
      :erlang.raise(:exit, reason, __STACKTRACE__)
  end

  defp unsubscribe(pid, ref) do
    Process.demonitor(ref, [:flush])
    send(pid, {:unsubscribe, self()})
  end

  # The request with its deadline (session-lifecycle.md, "Late calls").
  defp with_deadline(request, :infinity), do: request

  defp with_deadline(request, timeout),
    do: {:until, System.monotonic_time(:millisecond) + timeout, request}
end
