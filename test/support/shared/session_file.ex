defmodule Helyx.Test.SessionFile do
  @moduledoc false
  # The pick and the read of a session file in one call, with no lock.
  # `Helyx.Session.resume/2` takes the lock between the two. And the wait
  # for the lock of a session file before a second open of it.

  import ExUnit.Assertions

  alias Helyx.Session
  alias Helyx.Session.{File, Lock}
  alias Helyx.Test.Events

  # `Helyx.Session.File.append_message/2` with an id for a message that has
  # none: the session makes the id of each message it appends.
  def append_message(file, message),
    do: File.append_message(file, %{message | id: message.id || Helyx.Session.Id.new()})

  def resume(dir, cwd, opts \\ []) do
    with {:ok, path} <- File.pick(dir, cwd, opts), do: File.resume_picked(path, cwd, opts)
  end

  # Stops the session normally, then waits until the lock of its file is
  # free. The stop waits for perl's exit only up to `Lock.release_ms/0`, so
  # under load the lock can outlast it (#670).
  def stop(%Session{} = session) do
    pid = Session.pid(session)
    file = :sys.get_state(pid).file
    :ok = GenServer.stop(pid)
    if file, do: await_lock_free(file.path)
    :ok
  end

  # Polls until a take of the lock of the session file `path` succeeds.
  def await_lock_free(path, what \\ "the lock of the session file to free"),
    do: Events.wait_until(fn -> lock_free?(path) end, Events.wait_ms(), what)

  # The probe waits for the exit of its own perl within the test bound, not
  # `Lock.release_ms/0`, so that it never holds the lock past its return.
  defp lock_free?(path) do
    case Lock.hold(path, fn -> {:ok, :taken} end) do
      {:ok, lock, :taken} ->
        Port.command(lock, "x")
        assert_receive {^lock, {:exit_status, _}}, Events.wait_ms()
        true

      {:error, {:session_locked, _id}} ->
        false
    end
  end
end
