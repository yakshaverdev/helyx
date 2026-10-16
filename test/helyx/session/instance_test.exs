defmodule Helyx.Session.InstanceTest do
  # The session instance (#204), and two Cores on one session file (#266).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.Session

  setup :start_core

  describe "session instance (#204)" do
    @describetag :tmp_dir

    defp prompt_events(session, text \\ "hi") do
      :ok = Session.prompt(session, text)
      collect_until(:turn_end)
    end

    test "each start has its own instance, and its events carry it", %{core: core, tmp_dir: dir} do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      {:ok, first, _} = Session.subscribe(session)
      assert Enum.all?(prompt_events(session), &(&1.instance_id == first.instance_id))

      stop_session(session, &GenServer.stop/1)
      {:ok, resumed} = Session.resume(core, sessions_dir: dir)
      {:ok, second, _} = Session.subscribe(resumed)

      assert is_binary(second.instance_id) and second.instance_id != first.instance_id
      assert Enum.all?(prompt_events(resumed), &(&1.instance_id == second.instance_id))
    end

    # The review of #188, round 4, spec item 1. The session process holds
    # its subscribers (#297), so the entry of the old subscription ends with
    # the old process. The new instance starts `seq` at 0 again.
    test "a subscription ends with its process, and a resume starts a new instance", %{
      core: core,
      tmp_dir: dir
    } do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      {:ok, old, ref} = Session.subscribe(session)
      prompt_events(session)

      stop_session(session, &GenServer.stop/1)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
      {:ok, resumed} = Session.resume(core, sessions_dir: dir)
      assert :sys.get_state(Session.pid(resumed)).subscribers == %{}
      {:ok, _, _} = Session.subscribe(resumed)

      events = prompt_events(resumed)
      assert hd(events).seq == 1
      refute Enum.any?(events, &(&1.instance_id == old.instance_id))
    end

    # The review of #188, round 4, failure-path item 1.
    test "a subscribe to the id in another Core leaves the events of the first", %{
      core: core,
      tmp_dir: dir
    } do
      other = start_core([Helyx.Test.Provider])

      {:ok, a} = Session.start(core, model: "test/ok", sessions_dir: dir)
      # A second folder with a link of the file: the lock of the first
      # folder does not stop the second Core (docs/features/session-lock.md).
      {:ok, b} = Session.resume(other, sessions_dir: link_session(dir, a.id), id: a.id)
      assert a.id == b.id

      {:ok, snapshot_a, _} = Session.subscribe(a)
      :ok = Session.prompt(a, "hi")
      queued = fn -> for {:helyx_event, event} <- mailbox(), do: event end
      await(fn -> Enum.any?(queued.(), &(&1.type == :turn_end)) end, "the events of Core A")
      before = queued.()

      {:ok, snapshot_b, _} = Session.subscribe(b)
      assert snapshot_a.instance_id != snapshot_b.instance_id
      assert collect_until(:turn_end) == before
      assert Enum.all?(before, &(&1.instance_id == snapshot_a.instance_id))
      assert Enum.all?(prompt_events(b), &(&1.instance_id == snapshot_b.instance_id))
    end
  end
end
