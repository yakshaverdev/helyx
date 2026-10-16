defmodule Helyx.Test.SessionFile do
  @moduledoc false
  # The pick and the read of a session file in one call, with no lock.
  # `Helyx.Session.resume/2` takes the lock between the two.

  alias Helyx.Session.File

  def resume(dir, cwd, opts \\ []) do
    with {:ok, path} <- File.pick(dir, cwd, opts), do: File.resume_picked(path, cwd, opts)
  end
end
