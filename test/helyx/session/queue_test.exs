defmodule Helyx.Session.QueueTest do
  use ExUnit.Case, async: true

  alias Helyx.Session.Queue

  defp push!(queue, key, text) do
    {:ok, queue} = Queue.push(queue, key, text)
    queue
  end

  # One steer "more", sent with the request ref `from`.
  defp sent_one do
    from = make_ref()
    {Queue.sent(%Queue{}, from, "s1", "more"), from}
  end

  describe "the queues" do
    test "keep the arrival order of each queue, and drain gives steers first" do
      queue =
        %Queue{}
        |> push!(:follow_ups, "f1")
        |> push!(:steers, "s1")
        |> push!(:follow_ups, "f2")
        |> push!(:steers, "s2")

      assert Queue.counts(queue) == %{steers: 2, follow_ups: 2}
      assert {["s1", "s2", "f1", "f2"], drained} = Queue.drain(queue)
      assert Queue.counts(drained) == %{steers: 0, follow_ups: 0}
    end

    test "each queue holds at most 32 entries, and a full queue does not block the other" do
      full = Enum.reduce(1..32, %Queue{}, &push!(&2, :steers, "s#{&1}"))
      assert Queue.push(full, :steers, "s33") == {:error, :queue_full}
      refute Queue.room?(full)
      assert {:ok, queue} = Queue.push(full, :follow_ups, "f1")
      assert Queue.counts(queue) == %{steers: 32, follow_ups: 1}

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
      refute Queue.open?(queue)
    end

    test "taken before its answer, the request stays open; its answer queues nothing" do
      {queue, from} = sent_one()
      {queue, [{:take, "more"}]} = Queue.take(queue, "s1")
      assert {queue, []} = Queue.end_turn(queue, "t1", false)
      assert Queue.open?(queue)
      assert {queue, []} = Queue.answer(queue, from, :rejected)
      refute Queue.open?(queue)
      assert Queue.counts(queue).steers == 0
    end

    test "a confirmed rejection queues the steer again" do
      {queue, from} = sent_one()
      assert {queue, []} = Queue.answer(queue, from, :rejected)
      assert {["more"], _queue} = Queue.drain_steers(queue)
      refute Queue.open?(queue)
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
      refute Queue.open?(queue)
    end

    test "a steer with no answer waits for it: :rejected queues it" do
      {queue, from} = sent_one()
      assert {queue, []} = Queue.end_turn(queue, "t1", true)
      assert Queue.open?(queue)
      assert {queue, []} = Queue.answer(queue, from, :rejected)
      assert Queue.counts(queue).steers == 1
      refute Queue.open?(queue)
    end

    test "a steer with no answer waits for it: any other answer is its notice" do
      {queue, from} = sent_one()
      {queue, []} = Queue.end_turn(queue, "t1", true)
      assert {queue, [{:notice, "t1", "more"}]} = Queue.answer(queue, from, :ok)
      refute Queue.open?(queue)
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
    assert Queue.open?(queue)
    assert {queue, []} = Queue.answer(queue, from, :rejected)
    assert Queue.counts(queue).steers == 0
    refute Queue.open?(queue)
  end

  test "the end of the provider process ends every request; only a steer with no notice gets one" do
    {queue, _from} = sent_one()
    {queue, _notice} = Queue.end_turn(queue, "t1", false)
    assert {queue, []} = Queue.provider_down(queue)
    refute Queue.open?(queue)

    {queue, _from} = sent_one()
    {queue, []} = Queue.end_turn(queue, "t1", true)
    assert {queue, [{:notice, "t1", "more"}]} = Queue.provider_down(queue)
    refute Queue.open?(queue)
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

  test "effects keep the send order" do
    queue = %Queue{} |> Queue.sent(make_ref(), "s1", "one") |> Queue.sent(make_ref(), "s2", "two")

    assert {_queue, [{:notice, "t1", "one"}, {:notice, "t1", "two"}]} =
             Queue.end_turn(queue, "t1", false)
  end
end
