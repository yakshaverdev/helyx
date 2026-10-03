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
      collect_until(:agent_end)
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
      {:ok, b} = Session.resume(other, sessions_dir: dir)
      assert a.id == b.id

      {:ok, snapshot_a, _} = Session.subscribe(a)
      :ok = Session.prompt(a, "hi")
      queued = fn -> for {:helyx_event, event} <- mailbox(), do: event end
      await(fn -> Enum.any?(queued.(), &(&1.type == :agent_end)) end, "the events of Core A")
      before = queued.()

      {:ok, snapshot_b, _} = Session.subscribe(b)
      assert snapshot_a.instance_id != snapshot_b.instance_id
      assert collect_until(:agent_end) == before
      assert Enum.all?(before, &(&1.instance_id == snapshot_a.instance_id))
      assert Enum.all?(prompt_events(b), &(&1.instance_id == snapshot_b.instance_id))
    end
  end

  describe "two Cores on one session file (#266)" do
    @describetag :tmp_dir

    defp users(messages), do: for(%{role: :user} = m <- messages, do: Helyx.Message.text(m))

    test "each Core writes its own branch, and a resume reads the branch of the last write", %{
      core: core,
      tmp_dir: dir
    } do
      other = start_core([Helyx.Test.Provider])

      {:ok, a} = Session.start(core, model: "test/transcript", sessions_dir: dir)
      {:ok, _, _} = Session.subscribe(a)
      prompt_events(a, "shared")

      {:ok, b} = Session.resume(other, sessions_dir: dir)
      {:ok, _, _} = Session.subscribe(b)
      prompt_events(b, "b1")
      prompt_events(a, "a1")
      prompt_events(b, "b2")
      prompt_events(a, "a2")
      prompt_events(b, "b3")
      stop_session(b, &GenServer.stop/1)

      # B wrote last. Its branch is whole: every user message has its
      # reply, and no message of Core A is in it.
      {:ok, file} = Session.File.resume(dir, File.cwd!())
      assert users(file.messages) == ["shared", "b1", "b2", "b3"]

      assert Enum.map(file.messages, & &1.role) ==
               List.flatten(List.duplicate([:user, :assistant], 4))

      # Now A writes last, below its own leaf.
      prompt_events(a, "a3")
      stop_session(a, &GenServer.stop/1)
      {:ok, file} = Session.File.resume(dir, File.cwd!())
      assert users(file.messages) == ["shared", "a1", "a2", "a3"]

      assert Enum.map(file.messages, & &1.role) ==
               List.flatten(List.duplicate([:user, :assistant], 4))

      # The next provider call of a resumed session sees that branch only.
      {:ok, resumed} = Session.resume(core, sessions_dir: dir)
      {:ok, _, _} = Session.subscribe(resumed)
      rendered = Enum.map_join(file.messages, "\n", &"#{&1.role}:#{Helyx.Message.text(&1)}")
      assert final_text(prompt_events(resumed, "a4")) == rendered <> "\nuser:a4"
    end
  end
end
