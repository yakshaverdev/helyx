defmodule Helyx.Session.Killer do
  @moduledoc false
  # A kill of the calling process at a deadline that can be moved and
  # cancelled: the deadline of the open of a session (session-lock.md) and of
  # a removal from a session file (session-edit.md). `:timer.kill_after/1`
  # cannot be cancelled once it fires: its kill can reach the process after
  # the cancel. `cancel/1` waits for the end of the killer, and a signal of
  # a process comes before its `:DOWN`, so no kill comes after it returns.

  # The longest wait of a `receive`: a longer `after` crashes the killer,
  # and the deadline would be lost. A deadline that grows with the size of
  # a file reaches it only at terabytes.
  @max_wait_ms 4_294_967_295

  def arm(ms) do
    owner = self()
    spawn_monitor(fn -> kill_at(owner, Process.monitor(owner), ms) end)
  end

  # A move restarts the wait with its own ms. One that comes after the
  # kill finds no killer: the kill was sent.
  def move({pid, _monitor}, ms), do: send(pid, {:move, ms})

  def cancel({pid, monitor}) do
    send(pid, :cancel)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end
  end

  defp kill_at(owner, monitor, ms) when ms > @max_wait_ms,
    do: kill_at(owner, monitor, @max_wait_ms)

  defp kill_at(owner, monitor, ms) do
    receive do
      :cancel -> :ok
      {:move, ms} -> kill_at(owner, monitor, ms)
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    after
      ms -> Process.exit(owner, :kill)
    end
  end
end
