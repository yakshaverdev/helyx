defmodule Helyx.Session.UserTextTest do
  # The optional ModelContext callback `user_text/2`: the session asks the
  # plugin for the text of a user message before the text checks
  # (docs/features/skills.md, docs/features/session-model-context.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [collect_until: 1]
  import Helyx.Test.SessionCase, only: [start_core: 1, user_texts: 1]

  alias Helyx.Session

  @moduletag :tmp_dir

  setup do
    %{core: start_core([Helyx.Test.Provider, Helyx.Test.UserText])}
  end

  defp start(core) do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _snapshot, ref} = Session.subscribe(session)
    {session, ref}
  end

  test "prompt, steer, and follow_up send the text of user_text/2 for the user origin", %{
    core: core
  } do
    for op <- [:prompt, :steer, :follow_up] do
      {session, ref} = start(core)
      :ok = apply(Session, op, [session, "expand me"])
      assert user_texts(collect_until(:turn_end)) == ["expanded"], inspect(op)
      Process.demonitor(ref, [:flush])
      :ok = Helyx.Sessions.stop(session)
    end
  end

  test "the callback gets the cwd of the session", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/ok", cwd: dir)
    {:ok, _snapshot, ref} = Session.subscribe(session)
    :ok = Session.prompt(session, "cwd")
    assert user_texts(collect_until(:turn_end)) == ["cwd:" <> dir]
    Process.demonitor(ref, [:flush])
  end

  test "a text of the product origin is sent unchanged", %{core: core} do
    for op <- [:prompt, :steer, :follow_up] do
      {session, ref} = start(core)
      opts = [origin: %{kind: :product, id: "p1"}]
      :ok = apply(Session, op, [session, "expand me", opts])
      assert user_texts(collect_until(:turn_end)) == ["expand me"], inspect(op)
      Process.demonitor(ref, [:flush])
      :ok = Helyx.Sessions.stop(session)
    end
  end

  test "a plugin with no user_text/2 changes nothing", %{tmp_dir: dir} do
    for plugins <- [
          [Helyx.Test.Provider, Helyx.Test.ModelContext],
          [Helyx.Test.Provider]
        ] do
      core = start_core(plugins)
      {:ok, session} = Session.start(core, model: "test/ok", cwd: dir)
      {:ok, _snapshot, ref} = Session.subscribe(session)
      :ok = Session.prompt(session, "expand me")
      assert user_texts(collect_until(:turn_end)) == ["expand me"], inspect(plugins)
      Process.demonitor(ref, [:flush])
      :ok = Helyx.Sessions.stop(session)
    end
  end

  test "a return over the text bound gives text_too_large", %{core: core} do
    {session, ref} = start(core)

    for op <- [:prompt, :steer, :follow_up] do
      assert apply(Session, op, [session, "too large"]) == {:error, :text_too_large}, inspect(op)
    end

    refute_received {:helyx_event, _}
    Process.demonitor(ref, [:flush])
  end

  test "a session that is gone gives session_not_found", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    :ok = Helyx.Sessions.stop(session)

    for op <- [:prompt, :steer, :follow_up] do
      assert apply(Session, op, [session, "expand me"]) == {:error, :session_not_found},
             inspect(op)
    end
  end
end
