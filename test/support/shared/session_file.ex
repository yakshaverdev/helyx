defmodule Helyx.Test.SessionFile do
  @moduledoc false
  # The pick and the read of a session file in one call, with no lock, and
  # the normal stop of a session.

  alias Helyx.Session
  alias Helyx.Session.File

  # `Helyx.Session.File.append_message/2` with an id for a message that has
  # none: the session makes the id of each message it appends.
  def append_message(file, message),
    do:
      File.append_message(file, %{
        message
        | id: message.id || Helyx.Session.Id.new(),
          origin: origin(message)
      })

  defp origin(%{role: :user, origin: nil}), do: %{kind: :user, id: nil}
  defp origin(message), do: message.origin

  def resume(dir, cwd, opts \\ []) do
    with {:ok, path, cwd} <- File.pick(dir, cwd, opts), do: File.resume_picked(path, cwd, opts)
  end

  # Stops the session normally.
  def stop(%Session{} = session) do
    pid = Session.pid(session)
    :ok = GenServer.stop(pid)
    :ok
  end
end
