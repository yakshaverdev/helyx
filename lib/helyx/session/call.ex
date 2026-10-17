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

  # The request with its deadline (session-lifecycle.md, "Late calls").
  defp with_deadline(request, :infinity), do: request

  defp with_deadline(request, timeout),
    do: {:until, System.monotonic_time(:millisecond) + timeout, request}
end
