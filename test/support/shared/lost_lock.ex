defmodule Helyx.Test.LostLock do
  @moduledoc false
  # Kills the perl process that holds the lock of a session with a file,
  # and waits until the session has seen the loss (session-lock.md).

  import ExUnit.Assertions

  alias Helyx.Session

  def kill(%Session{} = session, tries \\ div(Helyx.Test.Events.wait_ms(), 10)) do
    pid = Session.pid(session)
    {:os_pid, os_pid} = Port.info(:sys.get_state(pid).lock, :os_pid)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    await_lost(pid, tries)
  end

  defp await_lost(_pid, 0), do: flunk("the session did not see the lost lock")

  defp await_lost(pid, tries) do
    unless :sys.get_state(pid).lock_lost do
      Process.sleep(10)
      await_lost(pid, tries - 1)
    end
  end
end
