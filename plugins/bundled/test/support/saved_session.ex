defmodule Helyx.Test.SavedSession do
  @moduledoc false
  # Starts a session with a file in a folder of its Core. A session with no
  # file does not save, and the TUI shows that notice at its mount
  # (`Helyx.Reason.text(:not_saved)`). A test of other cells starts its
  # session here. Call it from the test process: it registers the cleanup.

  import ExUnit.Callbacks, only: [on_exit: 1]

  def start(core, model) do
    dir = Path.join(System.tmp_dir!(), "helyx-#{core}")
    on_exit(fn -> File.rm_rf(dir) end)
    Helyx.Session.start(core, model: model, sessions_dir: dir)
  end
end
