defmodule Helyx.Test.SavedSession do
  @moduledoc false
  # Starts a session with a file in the data folder of its Core. A session
  # with no file does not save, and the TUI shows that notice at its mount
  # (`Helyx.Reason.text(:not_saved)`). A test of other cells starts its
  # session here.

  def start(core, model) do
    dir = Helyx.Core.config(core, :sessions_dir)
    Helyx.Session.start(core, model: model, sessions_dir: dir)
  end
end
