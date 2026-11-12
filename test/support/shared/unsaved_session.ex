defmodule Helyx.Test.UnsavedSession do
  @moduledoc false
  # Stops the saving of a session with a file: the folder of its file goes
  # away, so the next append fails, and the session stops persisting
  # (docs/features/session-lock.md). The folder comes back before the call
  # returns.

  alias Helyx.Session
  alias Helyx.Test.Events

  def stop_saving(%Session{} = session) do
    pid = Session.pid(session)
    %{save: {:saving, file}, model: %{provider: provider} = model} = :sys.get_state(pid)
    original = Helyx.ModelRef.to_string(model)
    folder = Path.dirname(file.path)
    moved = folder <> ".unsaved"
    File.rename!(folder, moved)

    try do
      :ok = Session.set_model(session, "#{provider}/unsaved")

      Events.wait_until(
        fn -> match?({:stopped, _}, :sys.get_state(pid).save) end,
        Events.wait_ms(),
        "the session to stop saving"
      )

      # A switch with no file changes only the session's model.
      :ok = Session.set_model(session, original)
    after
      File.rename!(moved, folder)
    end
  end
end
