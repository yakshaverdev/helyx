defmodule Helyx.Hub.WakeTest do
  use ExUnit.Case, async: true

  import Helyx.Test.HubWake

  alias Helyx.Hub
  alias Helyx.Hub.Live
  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Test.Events
  alias Helyx.Test.WireClient, as: Client

  @moduletag :tmp_dir

  setup context,
    do: serve(context, if(ms = context[:max_live], do: [max_live_sessions: ms], else: []))

  defp settled?(core, id) do
    snapshot = Events.snapshot(%Helyx.Session{id: id, core: core})
    snapshot.turn == nil and length(snapshot.messages) >= 2
  end

  test "a wake-up of a running session is sent once with a product origin", context do
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    id = due(context, context.owner, session.id)
    poll(context.hub)

    row = wait_row(context.hub, id, &(&1.last_outcome == "delivered"))
    assert %{run: 1, delivery_id: nil, due_at: nil, next_try_at: nil, last_at: at} = row
    assert is_integer(at)
    assert [{"wake up", origin}] = woken(context.core, session.id)
    assert byte_size(origin) == 12 and origin != id

    # A schedule of one run has no next wake-up: no second send.
    Events.wait_until(fn -> idle?(context.hub) end)
    poll(context.hub)
    assert idle?(context.hub) and length(woken(context.core, session.id)) == 1
  end

  # A scheduled prompt that meets the idle stop of the session loads it again
  # and is not lost (docs/features/idle-unload.md). The timer is armed by the
  # test and fires while the session is suspended, so the timer message is in
  # the mailbox before the prompt of the delivery Task.
  test "a scheduled prompt that meets the idle stop of the session loads it", context do
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    id = due(context, context.owner, session.id)
    pid = Helyx.Session.pid(session)

    Helyx.Test.Idle.arm_timer(session)
    :erlang.suspend_process(pid)
    Process.sleep(Helyx.Test.Idle.idle_ms() + Helyx.Test.Idle.load_ms())
    poll(context.hub)
    Events.wait_until(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 2} end)
    :erlang.resume_process(pid)

    wait_row(context.hub, id, &(&1.last_outcome == "delivered"))
    assert [{"wake up", _origin}] = woken(context.core, session.id)
  end

  # An outcome after the decide writes only on the row that the decide left,
  # whose `run` it moved: the retry and the refusal of a delivery whose load
  # failed after the decide go through `{:wake_outcome, ...}`, not the
  # start-row writes of `{:wake_retry, ...}` and `{:wake_refused, ...}`
  # (docs/features/idle-unload.md, docs/features/hub.md, decision 12).
  test "an outcome after the decide writes on the row that the decide left", context do
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")

    # A retry: the row of the start, with a next try.
    retry = due(context, context.owner, session.id)
    row = row(context.hub, retry)
    :ok = Helyx.Hub.call(context.hub, {:wake_decide, row})
    %{run: run, last_outcome: "unconfirmed"} = row(context.hub, retry)
    assert run == row.run + 1
    :ok = Helyx.Hub.call(context.hub, {:wake_outcome, row, :back})
    assert %{run: back, next_try_at: next} = row(context.hub, retry)
    assert back == row.run and next > now()

    # A refusal: the row of a refusal before the send, with no next try.
    refused = due(context, context.owner, session.id)
    row = row(context.hub, refused)
    :ok = Helyx.Hub.call(context.hub, {:wake_decide, row})
    :ok = Helyx.Hub.call(context.hub, {:wake_outcome, row, :refused})

    assert %{last_outcome: "refused", next_try_at: nil, delivery_id: nil, run: run} =
             row(context.hub, refused)

    assert run == row.run + 1
  end

  test "a stopped session is resumed, enters the live set, and its record moves", context do
    {ann, socket} = user(context, "ann")
    session = start(socket)
    %{"ok" => true} = Client.request(socket, "r", "stop", %{"session" => session})
    id = due(context, ann, session, %{"prompt" => String.duplicate("é", 600)})
    poll(context.hub)

    wait_row(context.hub, id, &(&1.last_outcome == "delivered"))
    assert Helyx.Session.pid(%Helyx.Session{id: session, core: context.core})
    assert Live.running?(:sys.get_state(context.hub), session)

    # The prompt of the record, cut to 1,024 bytes on a character boundary.
    {:ok, record} = in_hub(context.hub, & &1.store.record(&1.db, session))
    assert record.prompt == String.duplicate("é", 512)
  end

  test "a recurring schedule: the next time, and unrelated ids for two runs", context do
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    id = due(context, context.owner, session.id, %{"every" => 300})
    %{at: at, delivery_id: first} = row(context.hub, id)
    poll(context.hub)

    row = wait_row(context.hub, id, &(&1.run == 1 and &1.last_outcome == "delivered"))
    assert %{at: next, due_at: next, next_try_at: next, delivery_id: second} = row
    assert next == at + 300 and second != first

    Events.wait_until(fn -> idle?(context.hub) and settled?(context.core, session.id) end)
    set(context.hub, id, at: now() - 1, due_at: now() - 1, next_try_at: now() - 1)
    poll(context.hub)
    wait_row(context.hub, id, &(&1.run == 2 and &1.last_outcome == "delivered"))

    assert [{"wake up", ^first}, {"wake up", ^second}] = woken(context.core, session.id)
    refute String.contains?(first <> second, id)
  end

  test "a wake-up past its life is missed; a stop of many periods gives one run", context do
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    old = now() - 3_600 - 10 * 300
    once = due(context, context.owner, session.id)
    every = due(context, context.owner, session.id, %{"every" => 300})
    set(context.hub, once, at: old, due_at: old, next_try_at: old)
    set(context.hub, every, at: old, due_at: old, next_try_at: old)
    poll(context.hub)

    assert %{last_outcome: "missed", delivery_id: nil, run: 1} =
             wait_row(context.hub, once, &(&1.last_outcome != nil))

    assert %{last_outcome: "missed", at: next, run: 1, next_try_at: next} =
             wait_row(context.hub, every, &(&1.last_outcome != nil))

    assert next > now() - 1 and rem(next - old, 300) == 0 and next - 300 <= now()
    assert woken(context.core, session.id) == []
  end

  test "a running turn puts the wake-up off; the session took nothing", context do
    name = :"wake_block_#{System.unique_integer([:positive])}"
    Process.register(self(), name)
    call = %ToolCall{id: "c1", name: "block", arguments: %{"to" => Atom.to_string(name)}}
    :ok = Fake.script(context.core, "blocker", [[call]])
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/blocker")
    :ok = Helyx.Session.prompt(session, "go")
    assert_receive {:blocked, _}

    id = due(context, context.owner, session.id)
    before = row(context.hub, id)
    poll(context.hub)

    # The write-back: the row as it was before the send, tried 30 s later.
    row = wait_row(context.hub, id, &(&1.next_try_at in (now() + 20)..(now() + 31)))
    assert Map.drop(row, [:next_try_at]) == Map.drop(before, [:next_try_at])
    assert woken(context.core, session.id) == []
    :ok = Helyx.Session.abort(session)
  end

  test "a session that the user no longer owns: refused, and the schedule ends", context do
    {ann, socket} = user(context, "ann")
    session = start(socket)
    id = due(context, ann, session, %{"every" => 300})
    %{"ok" => true} = Client.request(socket, "r", "hub.records.delete", %{"session" => session})
    poll(context.hub)

    assert %{last_outcome: "refused", delivery_id: nil, next_try_at: nil} =
             wait_row(context.hub, id, &(&1.last_outcome != nil))

    assert woken(context.core, session) == []
  end

  test "a session whose file is gone: refused, and its record is deleted", context do
    {ann, socket} = user(context, "ann")
    session = start(socket)
    %{"ok" => true} = Client.request(socket, "r", "stop", %{"session" => session})
    id = due(context, ann, session)
    {:ok, path, _header} = Helyx.Session.File.Scan.find(context.data, session)
    File.rm!(path)
    poll(context.hub)

    assert %{last_outcome: "refused"} = wait_row(context.hub, id, &(&1.last_outcome != nil))
    assert in_hub(context.hub, & &1.store.record(&1.db, session)) == {:error, :not_found}

    assert %{"error" => %{"code" => "session_not_found"}} =
             Client.request(socket, "r", "hub.records.get", %{"session" => session})
  end

  test "a Task whose wake-up passed its life after its start sends nothing", context do
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    id = due(context, context.owner, session.id, %{"every" => 300})
    # The row as the start of a Task wrote it, 3,600 s after its due time.
    set(context.hub, id, due_at: now() - 3_600, next_try_at: now() + 150)
    row = row(context.hub, id)

    assert Hub.call(context.hub, {:wake_decide, row}) == {:error, :missed}
    assert %{last_outcome: "missed", run: 1, at: next} = row(context.hub, id)
    assert next > row.at
    assert woken(context.core, session.id) == []
  end

  test "a decide whose row the start of another Task wrote sends nothing", context do
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    id = due(context, context.owner, session.id)
    row = row(context.hub, id)

    assert Hub.call(context.hub, {:wake_decide, %{row | next_try_at: row.next_try_at + 1}}) ==
             {:error, :stale}

    assert row(context.hub, id) == row
  end
end
