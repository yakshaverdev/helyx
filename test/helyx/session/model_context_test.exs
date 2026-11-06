defmodule Helyx.Session.ModelContextTest do
  # The start option `:model_context`: a session picks one of the
  # ModelContext plugins of its Core, the first by default, and a resume
  # gets the first (docs/features/session-model-context.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [collect_until: 1]
  import Helyx.Test.SessionCase, only: [start_core: 1, final_text: 1]

  alias Helyx.Session

  @moduletag :tmp_dir

  setup do
    plugins = [Helyx.Test.Provider, Helyx.Test.ModelContext, Helyx.Test.PrepareContext]
    %{core: start_core(plugins)}
  end

  defp start(core, dir, opts),
    do: Session.start(core, [model: "test/system", cwd: dir, sessions_dir: dir] ++ opts)

  defp system(session) do
    {:ok, _snapshot, ref} = Session.subscribe(session)
    :ok = Session.prompt(session, "system")
    text = final_text(collect_until(:turn_end))
    Process.demonitor(ref, [:flush])
    text
  end

  test "a session gets the ModelContext that it names, the first by default", %{
    core: core,
    tmp_dir: dir
  } do
    assert Helyx.Core.plugins(core, Helyx.ModelContext) ==
             [Helyx.Test.ModelContext, Helyx.Test.PrepareContext]

    {:ok, default} = start(core, dir, [])
    assert system(default) == "built for #{dir}"
    {:ok, explicit_nil} = start(core, dir, model_context: nil)
    assert system(explicit_nil) == "built for #{dir}"
    {:ok, second} = start(core, dir, model_context: Helyx.Test.PrepareContext)
    assert system(second) == "prepared"
    {:ok, first} = start(core, dir, model_context: Helyx.Test.ModelContext)
    assert system(first) == "built for #{dir}"
  end

  test "Helyx.Sessions.start/2 passes the option", %{tmp_dir: dir} do
    core =
      :"core_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core,
       name: core,
       sessions_dir: dir,
       model: "test/system",
       plugins: [Helyx.Test.Provider, Helyx.Test.ModelContext, Helyx.Test.PrepareContext]},
      id: core
    )

    {:ok, session} =
      Helyx.Sessions.start(core, cwd: dir, model_context: Helyx.Test.PrepareContext)

    assert system(session) == "prepared"

    assert Helyx.Sessions.start(core, cwd: dir, model_context: Helyx.Test.Compaction) ==
             {:error, :invalid_model_context}
  end

  test "a value that names no registered ModelContext starts nothing", %{
    core: core,
    tmp_dir: dir
  } do
    # A registered plugin of another interface, a ModelContext that this
    # Core did not register, an Erlang module, the name as a string, and
    # other terms.
    for bad <- [
          Helyx.Test.Provider,
          Helyx.Test.Compaction,
          Helyx.ModelContext,
          :lists,
          "Elixir.Helyx.Test.ModelContext",
          [Helyx.Test.ModelContext],
          1
        ] do
      assert start(core, dir, model_context: bad) == {:error, :invalid_model_context}
    end

    assert File.ls!(dir) == []
    assert Helyx.Sessions.list_live(core) == []
  end

  test "a Core with no ModelContext takes only nil", %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Provider])
    {:ok, session} = start(core, dir, model_context: nil)
    assert system(session) == "no system"

    assert start(core, dir, model_context: Helyx.Test.ModelContext) ==
             {:error, :invalid_model_context}
  end

  test "a resume gets the first ModelContext: the header does not keep it", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = start(core, dir, model_context: Helyx.Test.PrepareContext)
    assert system(session) == "prepared"
    :ok = Helyx.Sessions.stop(session)

    {:ok, resumed} = Session.resume(core, sessions_dir: dir, id: session.id)
    assert system(resumed) == "built for #{dir}"
  end
end
