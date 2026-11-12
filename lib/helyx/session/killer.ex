defmodule Helyx.Session.Killer do
  @moduledoc false
  # A kill of a process at a deadline that can be cancelled: the deadline of
  # the open of a session (docs/features/session-lock.md) and of a removal
  # from a session file (docs/features/session-edit.md).
  # `:timer.kill_after/1` cannot be cancelled once it fires: its kill can reach
  # the process after the cancel. `cancel/1` and `disarm/1` wait for the end of
  # the killer, and a signal of a process comes before its `:DOWN`, so no kill
  # comes after they return. A killer that fired ends with the reason `:fired`,
  # after its kill; any other end of it is `:normal`.

  # The longest wait of a `receive`: a longer `after` crashes the killer, and the
  # deadline would be lost. A deadline that grows with the size of a file reaches
  # it only at terabytes.
  @max_wait_ms 4_294_967_295

  # Arms a kill of `target`, the caller by default. Gives the pid of the killer
  # and the monitor of the caller on it.
  def arm(target \\ self(), ms),
    do: spawn_monitor(fn -> kill_at(target, Process.monitor(target), ms) end)

  def cancel({pid, monitor}) do
    send(pid, :cancel)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end
  end

  # The cancel of a process that did not arm the killer, such as its target: it
  # waits on a monitor of its own.
  def disarm(pid) do
    monitor = Process.monitor(pid)
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
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    after
      ms ->
        Process.exit(owner, :kill)
        exit(:fired)
    end
  end
end
