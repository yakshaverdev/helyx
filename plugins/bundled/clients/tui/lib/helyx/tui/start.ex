defmodule Helyx.TUI.Start do
  @moduledoc false
  # The start window of `Helyx.TUI.run/1`: `start` gives the result of
  # the `start_link` of the TUI, and `run/1` blocks until the TUI ends.

  @spec run((-> GenServer.on_start())) :: :ok | {:error, term()}
  def run(start) do
    # A failed init (dead session, no terminal) exits the linked caller
    # before start_link can return the error. Trapping for just the start
    # window turns that into the {:error, reason} return; the flag is
    # restored before blocking, so the caller's other links keep their kill
    # semantics while the TUI runs.
    trap = Process.flag(:trap_exit, true)

    case start.() do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        # The TUI answers Process.info/2 only after it handles the monitor,
        # so a live answer means the DOWN carries the real reason. A TUI that
        # died before gives :noproc there; its EXIT comes over the link.
        if Process.info(pid, :status) do
          # Unlinked, an abnormal exit reaches the receive as a DOWN instead
          # of killing the caller through the link. Unlink before restoring
          # the flag, so no kill window opens.
          Process.unlink(pid)
          Process.flag(:trap_exit, trap)

          receive do
            {:DOWN, ^ref, :process, ^pid, reason} -> flush_exit(pid, exit_result(reason))
          end
        else
          reason = receive do: ({:EXIT, ^pid, reason} -> reason)
          Process.demonitor(ref, [:flush])
          Process.flag(:trap_exit, trap)
          exit_result(reason)
        end

      {:error, reason} ->
        # proc_lib unlinks and flushes the dead child's exit signal before
        # start_link returns an error, so there is nothing to drain here.
        Process.flag(:trap_exit, trap)
        {:error, reason}
    end
  end

  defp exit_result(:normal), do: :ok
  defp exit_result(reason), do: {:error, reason}

  # A crash in the trap window queues an EXIT that the flag cannot stop.
  defp flush_exit(pid, result) do
    receive do
      {:EXIT, ^pid, _reason} -> result
    after
      0 -> result
    end
  end
end
