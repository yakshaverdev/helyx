defmodule Helyx.Session.HarnessChainsTest do
  # The set of harness chains of a turn (ADR 0013 §3 and §4).
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall
  alias Helyx.Session.HarnessChains

  defp call(id), do: %ToolCall{id: id, name: "fileChange", arguments: %{}}

  # The set after requests "a<n>" for the calls "c<n>", with the effects dropped.
  defp after_requests(range),
    do:
      Enum.reduce(
        range,
        %HarnessChains{},
        &elem(HarnessChains.request(&2, "a#{&1}", call("c#{&1}")), 0)
      )

  test "at most 8 chains run and 16 wait, in arrival order; the next request is denied" do
    chains = after_requests(1..8)
    assert map_size(chains.running) == 8
    assert {chains, []} = HarnessChains.request(chains, "a9", call("c9"))

    chains =
      Enum.reduce(10..24, chains, &elem(HarnessChains.request(&2, "a#{&1}", call("c#{&1}")), 0))

    assert Enum.map(chains.waiting, &elem(&1, 0)) == Enum.map(9..24, &"a#{&1}")

    assert {^chains, [{:answer, "a25", {:deny, "too many approval requests: 8 run and 16 wait"}}]} =
             HarnessChains.request(chains, "a25", call("c25"))
  end

  test "a result answers its request and starts the first waiting chain" do
    chains = after_requests(1..9)

    assert {chains, [{:answer, "a3", :allow}, {:run, "a9", %ToolCall{id: "c9"}}]} =
             HarnessChains.result(chains, "c3", :allow)

    assert HarnessChains.running?(chains, "c9") and not HarnessChains.running?(chains, "c3")

    assert {_chains, [{:answer, "a1", {:deny, "no"}}]} =
             HarnessChains.result(chains, "c1", {:deny, "no"})
  end

  test "a second request for a call with a pending one is denied at once" do
    chains = after_requests(1..1)

    assert {^chains, [{:answer, "b", {:deny, "the call has a pending approval request"}}]} =
             HarnessChains.request(chains, "b", call("c1"))

    # Also while the first one waits.
    chains = after_requests(1..9)

    assert {^chains, [{:answer, "b", {:deny, _}}]} =
             HarnessChains.request(chains, "b", call("c9"))
  end

  test "an id is pending while its chain runs or waits, and not after its answer" do
    chains = after_requests(1..9)
    assert HarnessChains.pending?(chains, "a1") and HarnessChains.pending?(chains, "a9")
    refute HarnessChains.pending?(chains, "a10")
    {chains, _effects} = HarnessChains.result(chains, "c1", :allow)
    refute HarnessChains.pending?(chains, "a1")
  end

  test "each running and waiting request is pending" do
    chains = after_requests(1..10)
    assert Enum.sort(HarnessChains.pending(chains)) == Enum.sort(Enum.map(1..10, &"a#{&1}"))
  end
end
