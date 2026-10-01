defmodule Helyx.Session.SteersTest do
  use ExUnit.Case, async: true

  alias Helyx.Session.Steers

  # One steer "more", sent with the request ref `from`.
  defp one do
    from = make_ref()
    {Steers.sent(%Steers{}, from, "s1", "more"), from}
  end

  test "a sent steer counts as held until its answer and its user_message" do
    {ledger, from} = one()
    assert Steers.held(ledger) == 1

    {ledger, []} = Steers.answer(ledger, from, :ok)
    assert Steers.held(ledger) == 1

    assert {ledger, [{:take, "more"}]} = Steers.take(ledger, "s1")
    assert Steers.held(ledger) == 0
  end

  test "taken before its answer, the steer is held until the answer, with no effect" do
    {ledger, from} = one()
    assert {ledger, [{:take, "more"}]} = Steers.take(ledger, "s1")
    assert {^ledger, []} = Steers.take(ledger, "s1")
    assert Steers.held(ledger) == 1
    assert {ledger, []} = Steers.answer(ledger, from, :rejected)
    assert Steers.held(ledger) == 0
  end

  test "rejected during the turn goes back to the queue" do
    {ledger, from} = one()
    assert {ledger, [{:requeue, "more"}]} = Steers.answer(ledger, from, :rejected)
    assert Steers.held(ledger) == 0
  end

  test "an unknown steer id or a late answer changes nothing" do
    {ledger, _from} = one()
    assert {^ledger, []} = Steers.take(ledger, "other")
    assert {^ledger, []} = Steers.answer(ledger, make_ref(), :ok)
  end

  describe "a normal turn end" do
    test "keeps a steer with no answer for the wait; :rejected queues it" do
      {ledger, from} = one()
      assert {ledger, []} = Steers.end_turn(ledger, "t1", true)
      assert Steers.held(ledger) == 1
      assert {ledger, [{:requeue, "more"}]} = Steers.answer(ledger, from, :rejected)
      assert Steers.held(ledger) == 0
    end

    test "keeps a steer with no answer for the wait; any other answer is its notice" do
      {ledger, from} = one()
      {ledger, []} = Steers.end_turn(ledger, "t1", true)
      assert {ledger, [{:notice, "t1", "more"}]} = Steers.answer(ledger, from, :ok)
      assert Steers.held(ledger) == 0
    end

    test "gives an answered steer with no user_message its notice and drops it" do
      {ledger, from} = one()
      {ledger, []} = Steers.answer(ledger, from, :ok)
      assert {ledger, [{:notice, "t1", "more"}]} = Steers.end_turn(ledger, "t1", true)
      assert Steers.held(ledger) == 0
    end

    test "keeps a taken steer for its answer, with no notice" do
      {ledger, from} = one()
      {ledger, _} = Steers.take(ledger, "s1")
      assert {ledger, []} = Steers.end_turn(ledger, "t1", true)
      assert Steers.held(ledger) == 1
      assert {ledger, []} = Steers.answer(ledger, from, :ok)
      assert Steers.held(ledger) == 0
    end
  end

  test "an abort or a failure gives a steer with no answer its notice; the request stays and a late :rejected queues nothing" do
    {ledger, from} = one()
    assert {ledger, [{:notice, "t1", "more"}]} = Steers.end_turn(ledger, "t1", false)
    assert Steers.held(ledger) == 1
    assert {ledger, []} = Steers.answer(ledger, from, :rejected)
    assert Steers.held(ledger) == 0
  end

  test "an abort in the wait gives its notice now; a late :rejected queues nothing" do
    {ledger, from} = one()
    {ledger, []} = Steers.end_turn(ledger, "t1", true)
    assert {ledger, [{:notice, "t1", "more"}]} = Steers.abort(ledger)
    assert {^ledger, []} = Steers.abort(ledger)
    assert Steers.held(ledger) == 1
    assert {ledger, []} = Steers.answer(ledger, from, :rejected)
    assert Steers.held(ledger) == 0
  end

  test "an abort in the wait keeps a taken steer for its answer, with no notice" do
    {ledger, from} = one()
    {ledger, _} = Steers.take(ledger, "s1")
    {ledger, []} = Steers.end_turn(ledger, "t1", true)
    assert {ledger, []} = Steers.abort(ledger)
    assert Steers.held(ledger) == 1
    assert {_ledger, []} = Steers.answer(ledger, from, :ok)
  end

  test "the end of the harness process ends every request; only an unnoticed steer gets a notice" do
    {ledger, _from} = one()
    {ledger, _} = Steers.end_turn(ledger, "t1", false)
    assert {%Steers{open: []}, []} = Steers.harness_down(ledger)

    {ledger, _from} = one()
    {ledger, []} = Steers.end_turn(ledger, "t1", true)
    assert {%Steers{open: []}, [{:notice, "t1", "more"}]} = Steers.harness_down(ledger)
  end

  test "effects keep the send order" do
    a = make_ref()
    b = make_ref()
    ledger = %Steers{} |> Steers.sent(a, "s1", "one") |> Steers.sent(b, "s2", "two")

    assert {_ledger, [{:notice, "t1", "one"}, {:notice, "t1", "two"}]} =
             Steers.end_turn(ledger, "t1", false)
  end
end
