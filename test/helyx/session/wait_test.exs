defmodule Helyx.Session.WaitTest do
  use ExUnit.Case, async: true

  alias Helyx.Session.{Steers, Turn, Wait}

  defp turn(fields) do
    struct!(
      %Turn{id: "t1", model: nil, provider: nil, phase: :submitted},
      fields
    )
  end

  # A turn with one steer "more" that has no answer yet.
  defp steered do
    from = make_ref()
    {turn(steers: Steers.sent(%Steers{}, from, "s1", "more")), from}
  end

  test "a wait with nothing open ends at once" do
    assert {:done, []} = Wait.next(%Wait{}, nil)
  end

  test "a wait for an ended provider process lasts until its provider_down" do
    pid = self()
    wait = %Wait{provider: pid}
    assert Wait.next(wait, nil) == :open
    assert {wait, []} = Wait.provider_down(wait, pid)
    assert {:done, []} = Wait.next(wait, nil)
  end

  test "after a normal end, a steer with no answer holds the wait; :rejected queues it and ends it" do
    {turn, from} = steered()
    assert {wait, []} = Wait.after_turn(turn, self(), true)
    assert Steers.held(wait.steers) == 1
    assert Wait.next(wait, self()) == :open

    assert {wait, [{:requeue, "more"}]} = Wait.answer(wait, :steer, from, :rejected)
    assert {:done, []} = Wait.next(wait, self())
  end

  test "after an abort, a steer with no answer gives its notice and holds the wait until its answer" do
    {turn, from} = steered()
    assert {wait, [{:notice, "t1", "more"}]} = Wait.after_turn(turn, self(), false)
    caller = {self(), make_ref()}
    wait = %{wait | callers: [caller]}
    assert Wait.next(wait, self()) == :open

    assert {wait, []} = Wait.answer(wait, :steer, from, :rejected)
    assert {:done, [^caller]} = Wait.next(wait, self())
  end

  test "an abort in the wait gives a steer its notice and records the caller" do
    {turn, from} = steered()
    {wait, []} = Wait.after_turn(turn, self(), true)
    caller = {self(), make_ref()}
    assert {wait, [{:notice, "t1", "more"}]} = Wait.abort(wait, caller)
    assert Steers.held(wait.steers) == 1
    assert Wait.next(wait, self()) == :open

    assert {wait, []} = Wait.answer(wait, :steer, from, :rejected)
    assert {:done, [^caller]} = Wait.next(wait, self())
  end

  test "an abort in the wait for a taken steer waits for the answer, with no notice" do
    {turn, from} = steered()
    {steers, _} = Steers.take(turn.steers, "s1")
    {wait, []} = Wait.after_turn(%{turn | steers: steers}, self(), true)
    assert {wait, []} = Wait.abort(wait, {self(), make_ref()})
    assert Wait.next(wait, self()) == :open
    assert {wait, []} = Wait.answer(wait, :steer, from, :ok)
    assert {:done, [_caller]} = Wait.next(wait, self())
  end

  test "an answered steer with no user_message gets its notice at a normal end, and the wait ends" do
    {turn, from} = steered()
    {steers, []} = Steers.answer(turn.steers, from, :ok)

    assert {wait, [{:notice, "t1", "more"}]} =
             Wait.after_turn(%{turn | steers: steers}, self(), true)

    assert {:done, []} = Wait.next(wait, self())
  end

  test "the provider_down after an abort ends the open steer requests with no second notice" do
    {turn, _from} = steered()
    {wait, [_notice]} = Wait.after_turn(turn, self(), false)
    pid = self()
    wait = %{wait | interrupt: {pid, "t1"}}

    assert {:send, wait, ^pid, {:interrupt, "t1"} = request} = Wait.next(wait, pid)
    wait = Wait.sent(wait, request, make_ref())
    assert {wait, []} = Wait.provider_down(wait, pid)
    assert {:done, []} = Wait.next(wait, nil)
  end

  test "with no provider process, no request of the turn is open" do
    {turn, _from} = steered()
    turn = %{turn | start: make_ref(), results: [make_ref()]}
    assert {wait, [{:notice, "t1", "more"}]} = Wait.after_turn(turn, nil, false)
    assert {:done, []} = Wait.next(wait, nil)
  end

  test "an interrupt answer other than :ok holds the wait until the provider_down" do
    pid = self()
    wait = %Wait{interrupt: {pid, "t1"}}
    {:send, wait, ^pid, request} = Wait.next(wait, pid)
    from = make_ref()
    wait = Wait.sent(wait, request, from)

    assert {wait, []} = Wait.answer(wait, :interrupt, from, {:error, :gone})
    assert Wait.next(wait, pid) == :open
    assert {wait, []} = Wait.provider_down(wait, pid)
    assert {:done, []} = Wait.next(wait, nil)
  end

  test "an interrupt goes only to the provider process of its turn" do
    wait = %Wait{interrupt: {spawn(fn -> :ok end), "t1"}}
    assert {:done, []} = Wait.next(wait, self())
  end

  test "nothing goes out before the hands answer; then the tool result, then the interrupt" do
    pid = self()
    wait = %Wait{hands: make_ref(), tool: {"t1", "c1"}, interrupt: {pid, "t1"}}
    assert Wait.next(wait, pid) == :open

    wait = %{wait | hands: nil}

    assert {:send, wait, ^pid, {:tool_result, "t1", "c1", {:error, "aborted"}} = r} =
             Wait.next(wait, pid)

    tool_from = make_ref()
    wait = Wait.sent(wait, r, tool_from)
    assert {:send, wait, ^pid, {:interrupt, "t1"} = i} = Wait.next(wait, pid)
    reply = make_ref()
    wait = Wait.sent(wait, i, reply)

    {wait, []} = Wait.answer(wait, :interrupt, reply, :ok)
    assert Wait.next(wait, pid) == :open
    {wait, []} = Wait.answer(wait, :tool_result, tool_from, :ok)
    assert {:done, []} = Wait.next(wait, pid)
  end

  test "an idle close: :busy ends the wait, :ok waits for the provider_down" do
    pid = self()
    from = make_ref()
    wait = %Wait{idle: from, provider: pid}

    assert {busy, []} = Wait.answer(wait, :idle_close, from, :busy)
    assert {:done, []} = Wait.next(busy, pid)

    assert {closed, []} = Wait.answer(wait, :idle_close, from, :ok)
    assert Wait.next(closed, pid) == :open
  end

  test "an open tool request of the turn holds the wait but no steer place" do
    turn = turn(start: make_ref(), results: [make_ref()])
    {wait, []} = Wait.after_turn(turn, self(), true)
    assert Steers.held(wait.steers) == 0
    assert Wait.next(wait, self()) == :open
  end

  test "a reply whose ref is not stored changes nothing" do
    wait = %Wait{idle: make_ref(), reply: make_ref(), provider: self()}

    for kind <- [:idle_close, :interrupt, :steer, :tool_start, :tool_result, :turn] do
      assert {^wait, []} = Wait.answer(wait, kind, make_ref(), :ok)
    end
  end
end
