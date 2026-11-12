defmodule Helyx.Session.OutputLimitTest do
  # The start option `:max_output_tokens`: checked at the start, kept for
  # every model call of the session, and refused for a provider that cannot
  # apply it, at the start and at a switch (docs/features/output-limit.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [collect_until: 1]
  import Helyx.Test.SessionCase, only: [start_core: 2, final_text: 1]

  alias Helyx.Session

  @moduletag :tmp_dir

  @max 2_147_483_647

  setup %{tmp_dir: dir} do
    %{
      core:
        start_core([Helyx.Test.Provider, Helyx.Test.ProviderOther, Helyx.Test.Connected],
          sessions_dir: dir
        )
    }
  end

  defp start(core, dir, model, opts),
    do: Session.start(core, [model: model, cwd: dir, sessions_dir: dir] ++ opts)

  defp text(session, prompt \\ "go") do
    :ok = Session.prompt(session, prompt)
    final_text(collect_until(:turn_end))
  end

  defp subscribed(session) do
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    session
  end

  test "each model call gets the limit of the start, nil without it", %{core: core, tmp_dir: dir} do
    for {opts, seen} <- [
          {[], "nil"},
          {[max_output_tokens: nil], "nil"},
          {[max_output_tokens: 1], "1"},
          {[max_output_tokens: 7], "7"},
          {[max_output_tokens: @max], "#{@max}"}
        ] do
      {:ok, session} = start(core, dir, "test/limit", opts)
      session = subscribed(session)
      assert text(session) == seen
      # A second turn of the same provider process keeps it.
      assert text(session) == seen
    end
  end

  test "a provider option of the same name does not change the limit", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} =
      start(core, dir, "test/limit", max_output_tokens: 7, provider_opts: [max_output_tokens: 99])

    assert text(subscribed(session)) == "7"

    {:ok, session} = start(core, dir, "test/limit", provider_opts: [max_output_tokens: 99])
    assert text(subscribed(session)) == "nil"
  end

  test "a bad value starts nothing", %{core: core, tmp_dir: dir} do
    for bad <- [0, -1, @max + 1, 1.0, 7.5, "7", :seven, [7], {7}, %{}, true] do
      assert start(core, dir, "test/limit", max_output_tokens: bad) ==
               {:error, :invalid_max_output_tokens},
             inspect(bad)
    end

    assert File.ls!(dir) -- ["core.lock"] == []
  end

  test "a provider that cannot apply the limit starts nothing", %{core: core, tmp_dir: dir} do
    # A model provider and a provider with its own process loop.
    assert start(core, dir, "other/x", max_output_tokens: 7) ==
             {:error, {:max_output_tokens_unsupported, "other"}}

    assert start(core, dir, "conn/echo", max_output_tokens: 7) ==
             {:error, {:max_output_tokens_unsupported, "conn"}}

    assert File.ls!(dir) -- ["core.lock"] == []

    # Without the limit both start.
    assert {:ok, _} = start(core, dir, "other/x", [])
    assert {:ok, _} = start(core, dir, "conn/echo", [])
  end

  test "a switch to a provider that cannot apply the limit keeps the model", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = start(core, dir, "test/limit", max_output_tokens: 7)
    session = subscribed(session)

    assert Session.set_model(session, "other/x") ==
             {:error, {:max_output_tokens_unsupported, "other"}}

    assert text(session) == "7"

    # A switch within a provider that applies it keeps the limit.
    assert Session.set_model(session, "test/limit") == :ok
    assert text(session) == "7"

    # A session with no limit switches to any provider.
    {:ok, free} = start(core, dir, "test/limit", [])
    free = subscribed(free)
    assert Session.set_model(free, "other/x") == :ok
    assert text(free) == "from other"
  end

  # Core reads the callback once, at its start, so a start or a switch
  # runs no plugin code for it.
  test "a max_output_tokens?/0 that is not a boolean fails the start of Core" do
    core = :"core_#{System.unique_integer([:positive])}"
    plugins = [Helyx.Test.Provider, Helyx.Test.BadLimit]

    assert Helyx.Core.start_link(name: core, plugins: plugins) ==
             {:error, {:invalid_max_output_tokens, Helyx.Test.BadLimit}}
  end

  test "Core keeps the providers whose max_output_tokens?/0 is true", %{core: core} do
    assert Helyx.Core.limit_providers(core) == [Helyx.Test.Provider]
  end

  test "Helyx.Sessions.start/2 passes the option", %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    d = Path.join(dir, "sessions")

    start_supervised!(
      {Helyx.Core,
       name: core,
       sessions_dir: d,
       model: "test/limit",
       plugins: [Helyx.Test.Provider, Helyx.Test.ProviderOther]},
      id: core
    )

    {:ok, session} = Helyx.Sessions.start(core, cwd: dir, max_output_tokens: 3)
    assert text(subscribed(session)) == "3"

    assert Helyx.Sessions.start(core, cwd: dir, max_output_tokens: 0) ==
             {:error, :invalid_max_output_tokens}

    assert Helyx.Sessions.start(core, cwd: dir, model: "other/x", max_output_tokens: 3) ==
             {:error, {:max_output_tokens_unsupported, "other"}}
  end

  test "a resume runs with no limit", %{core: core, tmp_dir: dir} do
    {:ok, session} = start(core, dir, "test/limit", max_output_tokens: 7)
    session = subscribed(session)
    assert text(session) == "7"
    :ok = Helyx.Sessions.stop(session)

    {:ok, resumed} = Session.resume(core, sessions_dir: dir, cwd: dir, id: session.id)
    assert text(subscribed(resumed)) == "nil"
  end
end
