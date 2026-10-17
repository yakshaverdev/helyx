defmodule Helyx.ModelContext.DefaultIntegrationTest do
  # The seam through the session: the provider receives the assembled system
  # prompt when the Default plugin is registered.
  use ExUnit.Case, async: true

  import Helyx.Test.Events

  alias Helyx.Session

  @tag :tmp_dir
  test "the Fake provider receives the assembled system prompt", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "rules for #{dir}")

    core = :"core_#{System.unique_integer([:positive])}"
    plugins = [Helyx.Provider.Fake, Helyx.ModelContext.Default]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})

    {:ok, session} = Session.start(core, model: "fake/system", cwd: dir)
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")

    text = Helyx.Message.text(List.last(messages(collect_until(:turn_end))))
    assert text =~ "You are a coding agent."
    assert text =~ "## #{Path.join(Path.expand(dir), "AGENTS.md")}\n\nrules for #{dir}"
  end

  @tag :tmp_dir
  test "the session section shows the turn's model, the session id, and its folder",
       %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    plugins = [Helyx.Provider.Fake, Helyx.ModelContext.Default]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    sessions = Path.join(dir, "sessions")

    {:ok, session} = Session.start(core, model: "fake/system", cwd: dir, sessions_dir: sessions)
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")

    text = Helyx.Message.text(List.last(messages(collect_until(:turn_end))))
    session_dir = Helyx.Session.File.Scan.project_dir(sessions, dir)
    assert text =~ "Working directory: #{Path.expand(dir)}\n"
    assert text =~ "Model: fake/system\n"
    assert text =~ "Session id: #{session.id}\n"
    assert text =~ "Session directory: #{session_dir}\n"

    # A write failure turns persistence off: the session is not saved.
    File.rm_rf!(Path.join(dir, "sessions"))
    :ok = Session.prompt(session, "again")
    collect_until(:turn_end)
    :ok = Session.prompt(session, "and again")

    text = Helyx.Message.text(List.last(messages(collect_until(:turn_end))))
    assert text =~ "Session directory: not saved\n"
  end
end
