defmodule Helyx.Session.WaitTest do
  use ExUnit.Case, async: true

  alias Helyx.Session.{Turn, Wait}

  defp turn(fields) do
    struct!(
      %Turn{id: "t1", model: nil, provider: nil, phase: :submitted},
      fields
    )
  end

  test "a wait with nothing open ends at once" do
    assert {:done, []} = Wait.next(%Wait{}, nil)
  end

  test "a wait for an ended provider process lasts until its provider_down" do
    pid = self()
    wait = %Wait{provider: pid}
    assert Wait.next(wait, nil) == :open
    wait = Wait.provider_down(wait, pid)
    assert {:done, []} = Wait.next(wait, nil)
  end

  test "with no provider process, no request of the turn is open" do
    turn = turn(results: [make_ref()])
    assert Wait.next(Wait.after_turn(turn, self()), self()) == :open
    assert {:done, []} = Wait.next(Wait.after_turn(turn, nil), nil)
  end

  test "an interrupt answer other than :ok holds the wait until the provider_down" do
    pid = self()
    wait = %Wait{interrupt: {pid, "t1"}}
    {:send, wait, ^pid, request} = Wait.next(wait, pid)
    from = make_ref()
    wait = Wait.sent(wait, request, from)

    wait = Wait.answer(wait, :interrupt, from, {:error, :gone})
    assert Wait.next(wait, pid) == :open
    wait = Wait.provider_down(wait, pid)
    assert {:done, []} = Wait.next(wait, nil)
  end

  test "an interrupt goes only to the provider process of its turn" do
    wait = %Wait{interrupt: {spawn(fn -> :ok end), "t1"}}
    assert {:done, []} = Wait.next(wait, self())
  end

  test "nothing goes out before the hands answer; then each open tool request, then the interrupt" do
    pid = self()

    turn =
      turn(tool: "c1", waiting: [%Helyx.Message.ToolCall{id: "c2", name: "x", arguments: %{}}])

    wait = Wait.after_turn(turn, pid)
    wait = %{wait | hands: make_ref(), interrupt: {pid, "t1"}}
    assert Wait.next(wait, pid) == :open

    wait = %{wait | hands: nil}

    assert {:send, wait, ^pid, {:tool_result, "t1", "c1", {:error, "aborted"}} = r} =
             Wait.next(wait, pid)

    tool_from = make_ref()
    wait = Wait.sent(wait, r, tool_from)

    assert {:send, wait, ^pid, {:tool_result, "t1", "c2", {:error, "aborted"}} = r} =
             Wait.next(wait, pid)

    wait_from = make_ref()
    wait = Wait.sent(wait, r, wait_from)
    wait = Wait.answer(wait, :tool_result, wait_from, :ok)
    assert {:send, wait, ^pid, {:interrupt, "t1"} = i} = Wait.next(wait, pid)
    reply = make_ref()
    wait = Wait.sent(wait, i, reply)

    wait = Wait.answer(wait, :interrupt, reply, :ok)
    assert Wait.next(wait, pid) == :open
    wait = Wait.answer(wait, :tool_result, tool_from, :ok)
    assert {:done, []} = Wait.next(wait, pid)
  end

  test "an idle close: :busy ends the wait, :ok waits for the provider_down" do
    pid = self()
    from = make_ref()
    wait = %Wait{idle: from, provider: pid}

    busy = Wait.answer(wait, :idle_close, from, :busy)
    assert {:done, []} = Wait.next(busy, pid)

    closed = Wait.answer(wait, :idle_close, from, :ok)
    assert Wait.next(closed, pid) == :open
  end

  test "a reply whose ref is not stored changes nothing" do
    wait = %Wait{idle: make_ref(), reply: make_ref(), provider: self()}

    for kind <- [:idle_close, :interrupt, :tool_result, :turn] do
      assert Wait.answer(wait, kind, make_ref(), :ok) == wait
    end
  end
end
