defmodule Helyx.Test.LostLock do
  @moduledoc false
  # Kills the perl process that holds the lock of a session with a file,
  # and waits until the session has seen the loss (session-lock.md).

  import ExUnit.Assertions

  alias Helyx.Session
  alias Helyx.Test.PerlSignal

  def kill(%Session{} = session, tries \\ div(Helyx.Test.Events.wait_ms(), 10)) do
    pid = Session.pid(session)
    state = :sys.get_state(pid)
    {:saving, file, lock} = state.save
    lock_path = Path.rootname(file.path) <> ".lock"
    perl = PerlSignal.pid(lock, lock_path)
    PerlSignal.send!(perl, "KILL", lock_path)
    await_lost(pid, tries)
  end

  defp await_lost(_pid, 0), do: flunk("the session did not see the lost lock")

  defp await_lost(pid, tries) do
    if Helyx.Session.Server.State.lock(:sys.get_state(pid)) do
      Process.sleep(10)
      await_lost(pid, tries - 1)
    end
  end
end
