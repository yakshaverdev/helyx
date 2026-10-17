defmodule Helyx.SessionsCapTest do
  # The cap of 64 live sessions per Core (#657, docs/features/server-management.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Session, Sessions}

  @moduletag :tmp_dir

  setup :start_core

  test "the 64th session starts, the 65th does not, and a resume of a running one attaches", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, saved} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _, ref} = Session.subscribe(saved)
    :ok = Session.prompt(saved, "hi")
    collect_until(:turn_end)

    for _ <- 2..63, do: {:ok, _} = Session.start(core, model: "test/ok")
    assert length(Sessions.list_live(core)) == 63

    {:ok, last} = Session.start(core, model: "test/ok")
    assert length(Sessions.list_live(core)) == 64

    assert Session.start(core, model: "test/ok") == {:error, :too_many_sessions}
    assert {:ok, ^saved} = Session.resume(core, sessions_dir: dir, id: saved.id)

    # A stop frees the place when the supervisor handles the exit, which
    # has no order with the return of the stop; a resume of a stopped
    # session counts again.
    :ok = Sessions.stop(saved)
    assert_receive {:DOWN, ^ref, :process, _, _}
    await(fn -> match?({:ok, _}, Session.start(core, model: "test/ok")) end, "the place to free")
    assert Session.resume(core, sessions_dir: dir, id: saved.id) == {:error, :too_many_sessions}
    assert Session.pid(last)
  end
end
