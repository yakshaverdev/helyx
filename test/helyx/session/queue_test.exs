defmodule Helyx.Session.QueueTest do
  use ExUnit.Case, async: true

  alias Helyx.Session.Queue

  defp push!(queue, key, text) do
    {:ok, queue} = Queue.push(queue, key, text)
    queue
  end

  defp open?(queue), do: queue.sent != []

  # One steer "more", sent with the request ref `from`.
  defp sent_one do
    from = make_ref()
    {Queue.sent(%Queue{}, from, "s1", "more"), from}
  end

  describe "the queues" do
    test "keep the arrival order of each queue; drain gives the steers together, then one follow-up at a time" do
      queue =
        %Queue{}
        |> push!(:follow_ups, "f1")
        |> push!(:steers, "s1")
        |> push!(:follow_ups, "f2")
        |> push!(:steers, "s2")

      assert Queue.counts(queue) == %{steers: 2, follow_ups: 2, running: 0, held: 0, waiting: 0}
      assert {["s1", "s2"], queue} = Queue.drain(queue)
      assert {["f1"], queue} = Queue.drain(queue)
      assert {["f2"], queue} = Queue.drain(queue)
      assert {[], drained} = Queue.drain(queue)
      assert Queue.counts(drained) == %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0}
    end

    test "each queue holds at most 32 entries, and a full queue does not block the other" do
      full = Enum.reduce(1..32, %Queue{}, &push!(&2, :steers, "s#{&1}"))
      assert Queue.push(full, :steers, "s33") == {:error, :queue_full}
      refute Queue.room?(full)
      assert {:ok, queue} = Queue.push(full, :follow_ups, "f1")
      assert Queue.counts(queue) == %{steers: 32, follow_ups: 1, running: 0, held: 0, waiting: 0}

      text = String.duplicate("折🚀", 1000)
      full = Enum.reduce(1..32, %Queue{}, fn _n, queue -> push!(queue, :follow_ups, text) end)
      assert Queue.push(full, :follow_ups, "折") == {:error, :queue_full}
    end

    test "sent steers count in the 32 steers until their request ends" do
      {queue, from} = sent_one()
      queue = Enum.reduce(1..30, queue, &push!(&2, :steers, "s#{&1}"))
      assert Queue.room?(queue)
      queue = push!(queue, :steers, "s31")
      assert Queue.push(queue, :steers, "s32") == {:error, :queue_full}

      {queue, [{:take, "more"}]} = Queue.take(queue, "s1")
      assert Queue.push(queue, :steers, "s32") == {:error, :queue_full}

      {queue, []} = Queue.answer(queue, from, :ok)
      assert {:ok, _queue} = Queue.push(queue, :steers, "s32")
    end
  end

  describe "in the turn" do
    test "a steer with :ok joins at its user_message, with no notice at the end" do
      {queue, from} = sent_one()
      {queue, []} = Queue.answer(queue, from, :ok)
      assert {queue, [{:take, "more"}]} = Queue.take(queue, "s1")
      assert {^queue, []} = Queue.take(queue, "s1")
      assert {queue, []} = Queue.end_turn(queue, "t1", true)
      refute open?(queue)
    end

    test "taken before its answer, the request stays open; its answer queues nothing" do
      {queue, from} = sent_one()
      {queue, [{:take, "more"}]} = Queue.take(queue, "s1")
      assert {queue, []} = Queue.end_turn(queue, "t1", false)
      assert open?(queue)
      assert {queue, []} = Queue.answer(queue, from, :rejected)
      refute open?(queue)
      assert Queue.counts(queue).steers == 0
    end

    test "a confirmed rejection queues the steer again" do
      {queue, from} = sent_one()
      assert {queue, []} = Queue.answer(queue, from, :rejected)
      assert {["more"], _queue} = Queue.drain_steers(queue)
      refute open?(queue)
    end

    test "an unknown steer id or a late answer changes nothing" do
      {queue, _from} = sent_one()
      assert {^queue, []} = Queue.take(queue, "other")
      assert {^queue, []} = Queue.answer(queue, make_ref(), :ok)
    end
  end

  describe "a normal turn end" do
    test "an answered steer with no user_message gets its notice" do
      {queue, from} = sent_one()
      {queue, []} = Queue.answer(queue, from, {:error, :gone})
      assert {queue, [{:notice, "t1", "more"}]} = Queue.end_turn(queue, "t1", true)
      refute open?(queue)
    end

    test "a steer with no answer stays open: :rejected queues it" do
      {queue, from} = sent_one()
      assert {queue, []} = Queue.end_turn(queue, "t1", true)
      assert open?(queue)
      assert {queue, []} = Queue.answer(queue, from, :rejected)
      assert Queue.counts(queue).steers == 1
      refute open?(queue)
    end

    test "a steer with no answer stays open: any other answer is its notice" do
      {queue, from} = sent_one()
      {queue, []} = Queue.end_turn(queue, "t1", true)
      assert {queue, [{:notice, "t1", "more"}]} = Queue.answer(queue, from, :ok)
      refute open?(queue)
    end

    test "an abort after it gives the notice now; a late :rejected queues nothing" do
      {queue, from} = sent_one()
      {queue, []} = Queue.end_turn(queue, "t1", true)
      assert {queue, [{:notice, "t1", "more"}]} = Queue.abort(queue)
      assert {^queue, []} = Queue.abort(queue)
      assert {queue, []} = Queue.answer(queue, from, :rejected)
      assert Queue.counts(queue).steers == 0
    end
  end

  test "an abort or a failure gives a steer with no answer its notice; a late :rejected queues nothing" do
    {queue, from} = sent_one()
    assert {queue, [{:notice, "t1", "more"}]} = Queue.end_turn(queue, "t1", false)
    assert open?(queue)
    assert {queue, []} = Queue.answer(queue, from, :rejected)
    assert Queue.counts(queue).steers == 0
    refute open?(queue)
  end

  test "the end of the provider process ends every request; only a steer with no notice gets one" do
    {queue, _from} = sent_one()
    {queue, _effects} = Queue.end_turn(queue, "t1", false)
    assert {queue, []} = Queue.provider_down(queue)
    refute open?(queue)

    {queue, _from} = sent_one()
    {queue, []} = Queue.end_turn(queue, "t1", true)
    assert {queue, [{:notice, "t1", "more"}]} = Queue.provider_down(queue)
    refute open?(queue)
  end

  test "a steer of the next turn is in the turn again" do
    {queue, from} = sent_one()
    {queue, []} = Queue.end_turn(queue, "t1", true)
    {queue, _notice} = Queue.answer(queue, from, :ok)

    next = make_ref()
    queue = Queue.sent(queue, next, "s2", "again")
    assert {queue, []} = Queue.answer(queue, next, :ok)
    assert {_queue, [{:take, "again"}]} = Queue.take(queue, "s2")
  end

  # The next turn does not wait for the answers of an ended turn (#361).
  test "a steer of an ended turn keeps its turn while the next turn sends steers" do
    {queue, from} = sent_one()
    {queue, []} = Queue.end_turn(queue, "t1", true)
    queue = Queue.sent(queue, make_ref(), "s2", "again")

    assert {queue, [{:notice, "t1", "more"}]} = Queue.answer(queue, from, :ok)
    assert {queue, [{:notice, "t2", "again"}]} = Queue.end_turn(queue, "t2", false)
    assert [{_from, "s2", "again", :settled}] = queue.sent
  end

  test "effects keep the send order" do
    queue = %Queue{} |> Queue.sent(make_ref(), "s1", "one") |> Queue.sent(make_ref(), "s2", "two")

    assert {_queue, [{:notice, "t1", "one"}, {:notice, "t1", "two"}]} =
             Queue.end_turn(queue, "t1", false)
  end

  describe "the queued texts" do
    setup do
      {queue, _from} = sent_one()
      %{queue: queue |> push!(:follow_ups, "f") |> push!(:steers, "s")}
    end

    test "an abort or a failure empties both queues and gives the texts back, steers first, after the notices",
         %{queue: queue} do
      assert {aborted, [{:notice, "t1", "more"}, {:dropped, ["s", "f"]}]} =
               Queue.end_turn(queue, "t1", false)

      assert Queue.counts(aborted) == %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0}
      assert {_queue, [{:dropped, ["s", "f"]}]} = Queue.abort(queue)
    end

    test "keep the queue order: a steer that the provider rejected joins the end of the steers" do
      {queue, from} = sent_one()
      queue = push!(queue, :steers, "s")
      {queue, []} = Queue.answer(queue, from, :rejected)
      queue = push!(queue, :follow_ups, "f")
      assert {_queue, [{:dropped, ["s", "more", "f"]}]} = Queue.abort(queue)
    end

    test "stay at the end of the provider process", %{queue: queue} do
      assert {queue, []} = Queue.provider_down(queue)
      assert Queue.counts(queue) == %{steers: 1, follow_ups: 1, running: 0, held: 0, waiting: 0}
      refute open?(queue)
    end
  end

  describe "the background ends" do
    test "an abort or a failed turn keeps them and holds them until a turn opens" do
      queue = %Queue{} |> Queue.push_end("e1") |> push!(:steers, "s1")
      assert Queue.wake?(queue)

      {queue, effects} = Queue.abort(queue)
      assert effects == [{:dropped, ["s1"]}]
      assert queue.ends == ["e1"]
      refute Queue.wake?(queue)
      refute Queue.wake?(Queue.push_end(queue, "e2"))

      {queue, _effects} = Queue.end_turn(Queue.open(queue), "t1", false)
      refute Queue.wake?(queue)
      assert Queue.wake?(Queue.open(queue))
      assert {["e1"], %Queue{ends: []}} = Queue.drain_ends(queue)
    end

    test "count as held only while they hold, else as waiting" do
      queue = Queue.push_end(%Queue{}, "e1")
      assert %{held: 0, waiting: 1} = Queue.counts(queue)
      {held, _effects} = Queue.abort(queue)
      assert %{held: 1, waiting: 0} = Queue.counts(held)
      assert Queue.counts(Queue.push_end(held, "e2")).held == 2
      assert %{held: 0, waiting: 1} = Queue.counts(Queue.open(held))
    end

    test "a run counts as running from its start to its end, which then waits" do
      queue = %Queue{} |> Queue.started() |> Queue.started()
      assert %{running: 2, waiting: 0} = Queue.counts(queue)
      queue = Queue.ended(queue, "e1")
      assert %{running: 1, waiting: 1} = Queue.counts(queue)
      assert queue.ends == ["e1"]
      assert_raise FunctionClauseError, fn -> Queue.ended(%Queue{}, "e2") end
    end

    test "an end goes to a turn only while one more steer fits" do
      queue = Queue.push_end(%Queue{}, "e1")
      assert {"e1", %Queue{ends: []}} = Queue.next_end(queue)
      assert Queue.next_end(%Queue{}) == nil

      full = Enum.reduce(1..32, queue, &push!(&2, :steers, "s#{&1}"))
      assert Queue.next_end(full) == nil
    end

    test "a sent end that is rejected goes back to the ends; taken it is its text" do
      from = make_ref()
      queue = Queue.sent(%Queue{}, from, "id", {:end, "e1"})

      assert {%Queue{ends: ["e1"], steers: [], sent: []} = rejected, []} =
               Queue.answer(queue, from, :rejected)

      # As a rejected steer, it waits for the next turn, and so do the others.
      assert Queue.next_end(Queue.push_end(rejected, "e2")) == nil
      assert {"e1", _queue} = Queue.next_end(Queue.open(rejected))

      assert {_queue, [{:take, "e1"}]} = Queue.take(queue, "id")
    end

    test "a sent end that no user_message took goes back held at the end of its turn, or at its late answer" do
      {answered, late} = {make_ref(), make_ref()}

      queue =
        %Queue{ends: ["e0"]}
        |> Queue.sent(answered, "a", {:end, "e1"})
        |> Queue.sent(late, "b", {:end, "e2"})

      {queue, []} = Queue.answer(queue, answered, {:error, :lost})
      assert {queue, []} = Queue.end_turn(queue, "t1", true)
      assert %Queue{ends: ["e1", "e0"], hold: true} = queue

      for reply <- [:ok, {:error, :lost}] do
        assert {%Queue{ends: ["e2", "e1", "e0"], sent: [], hold: true} = back, []} =
                 Queue.answer(queue, late, reply)

        # Held, it wakes nothing, but an open submitted turn still sends it.
        refute Queue.wake?(back)
        assert {"e2", _} = Queue.next_end(back)
      end
    end

    test "an abort, a failure, or the end of the provider process gives back every end that no user_message took" do
      {open, answered, ended, taken} = {make_ref(), make_ref(), make_ref(), make_ref()}

      queue =
        %Queue{ends: ["e0"]}
        |> Queue.sent(open, "a", {:end, "e1"})
        |> Queue.sent(answered, "b", {:end, "e2"})
        |> Queue.sent(taken, "d", {:end, "e4"})
        |> Queue.sent(make_ref(), "s", "steer")

      {queue, []} = Queue.answer(queue, answered, :ok)
      {queue, [{:take, "e4"}]} = Queue.take(queue, "d")

      after_turn =
        Queue.sent(%Queue{}, ended, "c", {:end, "e3"}) |> Queue.sent(make_ref(), "s", "steer")

      {after_turn, []} = Queue.end_turn(after_turn, "t0", true)

      assert {aborted, [{:notice, "t1", "steer"}]} = Queue.end_turn(queue, "t1", false)
      assert aborted.ends == ["e1", "e2", "e0"]
      assert aborted.hold
      # A late answer of a given-back end only ends its request.
      assert {%Queue{ends: ["e1", "e2", "e0"]}, []} = Queue.answer(aborted, open, :rejected)

      assert {aborted, [{:notice, "t0", "steer"}]} = Queue.abort(after_turn)
      assert aborted.ends == ["e3"]

      assert {down, []} = Queue.provider_down(queue)
      assert down.ends == ["e1", "e2", "e0"]
      assert down.sent == []
      assert down.hold
      assert {%Queue{hold: false}, []} = Queue.provider_down(%Queue{})
    end
  end
end
