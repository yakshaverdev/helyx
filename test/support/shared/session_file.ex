defmodule Helyx.Test.SessionFile do
  @moduledoc false
  # The pick and the read of a session file in one call, with no lock.
  # `Helyx.Session.resume/2` takes the lock between the two.

  alias Helyx.Session.File

  # `Helyx.Session.File.append_message/2` with an id for a message that has
  # none: the session makes the id of each message it appends.
  def append_message(file, message),
    do: File.append_message(file, %{message | id: message.id || Helyx.Session.Id.new()})

  def resume(dir, cwd, opts \\ []) do
    with {:ok, path} <- File.pick(dir, cwd, opts), do: File.resume_picked(path, cwd, opts)
  end
end
