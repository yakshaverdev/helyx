defmodule Helyx.Provider.ClaudeCode.MeterTest do
  # The usage of a Claude Code `done` (`docs/features/usage-and-limits.md`,
  # "Per provider"): the sum of the `result` lines since the last `done`,
  # and the cost as the difference of the process totals.
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake,
    only: [
      aborted: 0,
      begin: 0,
      init: 0,
      delta: 1,
      ended?: 1,
      events_of: 1,
      interrupted: 0,
      j: 1,
      lifecycle: 1,
      lost: 1,
      prompt: 2,
      replayed: 0,
      request: 2,
      run_direct: 2,
      running_to: 2,
      script: 3,
      script: 4,
      sid: 0,
      start: 1,
      tool_result: 2,
      tool_use: 2,
      turn: 4
    ]

  import Helyx.Test.HarnessDriver, only: [pump: 4]

  import Helyx.Test.Events, only: [collect_until: 1, messages: 1, of_type: 2]

  alias Helyx.{Message, Session}
  alias Helyx.Provider.ClaudeCode
  alias Helyx.Provider.ClaudeCode.Meter

  # Two turns of one process, from a recorded run (`claude` 2.1.296,
  # `--model=opus`, 2026-10-13). `usage` is for the turn; `total_cost_usd`
  # and `modelUsage` add up over the process.
  @model "claude-opus-5-5"
  @usage1 %{
    "input_tokens" => 2,
    "cache_creation_input_tokens" => 17_836,
    "cache_read_input_tokens" => 10_960,
    "output_tokens" => 4
  }
  @usage2 %{
    "input_tokens" => 2,
    "cache_creation_input_tokens" => 17_994,
    "cache_read_input_tokens" => 13_902,
    "output_tokens" => 4
  }

  defp entry(basis \\ "list", window \\ 1_000_000),
    do: %{"costBasis" => basis, "contextWindow" => window, "costUSD" => 0.1}

  defp result(usage, total, model_usage \\ %{@model => entry()}),
    do: %{"usage" => usage, "total_cost_usd" => total, "modelUsage" => model_usage}

  defp line(meter, usage), do: Meter.assistant(meter, %{"model" => @model, "usage" => usage})

  defp call(meter, usage, total, model_usage \\ %{@model => entry()}) do
    meter |> line(usage) |> Meter.result(result(usage, total, model_usage))
  end

  test "two turns of one process: the tokens of each, and the difference of the totals" do
    {first, meter} = Meter.done(call(%Meter{}, @usage1, 0.144968))

    assert first == %Helyx.Usage{
             input: 2,
             output: 4,
             cache_read: 10_960,
             cache_write: 17_836,
             cost: 0.144968,
             cost_kind: :list,
             context_tokens: 28_802,
             context_window: 1_000_000
           }

    {second, _meter} = Meter.done(call(meter, @usage2, 0.2917884))
    assert %Helyx.Usage{input: 2, cache_read: 13_902, context_tokens: 31_902} = second
    assert_in_delta second.cost, 0.2917884 - 0.144968, 1.0e-12
  end

  # An unresolved steer, a positive `queued_turn_count`, and an aborted
  # turn all give results with no `done` in between.
  test "results with no done between them go into the next done" do
    {usage, _meter} = %Meter{} |> call(@usage1, 0.1) |> call(@usage2, 0.25) |> Meter.done()

    assert %Helyx.Usage{input: 4, output: 8, cache_read: 24_862, cache_write: 35_830} = usage
    assert usage.cost == 0.25
    assert usage.context_tokens == 31_902
  end

  test "a result with no valid usage adds no tokens and makes the cost nil" do
    for bad <- [nil, %{"input_tokens" => "2"}, %{"input_tokens" => -1}] do
      meter = %Meter{} |> call(@usage1, 0.1) |> Meter.result(result(bad, 0.2))
      {usage, meter} = Meter.done(meter)
      assert %Helyx.Usage{input: 2, output: 4, cost: nil, cost_kind: nil} = usage

      # The mark is not known, so the next cost is not known either.
      assert {%Helyx.Usage{cost: nil}, _meter} = Meter.done(call(meter, @usage2, 0.3))
    end
  end

  # A replayed line's result, as a real program sends it (research note,
  # 2026-10-13): no model call, and the cost of the turn stays known.
  test "a result with an empty modelUsage keeps the cost known" do
    zero = %{"input_tokens" => 0, "output_tokens" => 0}
    meter = Meter.result(%Meter{}, result(zero, 0, %{}))

    assert {%Helyx.Usage{input: 2, cost: 0.1, cost_kind: :list}, _} =
             Meter.done(call(meter, @usage1, 0.1))
  end

  test "an assistant line with a bad usage or model keeps the context and the model before it" do
    meter = line(%Meter{}, @usage1)

    for bad <- [%{"usage" => %{"input_tokens" => -1}, "model" => 7}, %{}] do
      assert Meter.assistant(meter, bad) == meter
    end
  end

  test "a costBasis other than list, or a total below the mark, gives cost nil" do
    for model_usage <- [%{@model => entry("billed")}, %{@model => %{}}, nil] do
      meter = call(%Meter{}, @usage1, 0.1, model_usage)
      assert {%Helyx.Usage{input: 2, cost: nil}, _meter} = Meter.done(meter)
    end

    {_usage, meter} = Meter.done(call(%Meter{}, @usage1, 0.5))
    assert {%Helyx.Usage{input: 2, cost: nil}, _meter} = Meter.done(call(meter, @usage1, 0.4))
  end

  test "the window is of the only entry, or of the entry of the last model" do
    other = %{"other" => entry("list", 200_000), @model => entry("list", 300_000)}

    assert {%Helyx.Usage{context_window: 300_000}, _} =
             Meter.done(call(%Meter{}, @usage1, 0, other))

    only = %{"alias-key" => entry("list", 400_000)}

    assert {%Helyx.Usage{context_window: 400_000}, _} =
             Meter.done(call(%Meter{}, @usage1, 0, only))

    none = %{"a" => entry(), "b" => entry()}

    assert {%Helyx.Usage{context_window: nil, cost: 0}, _} =
             Meter.done(call(%Meter{}, @usage1, 0, none))
  end

  # The wire bound: tokens 0 to 10^9, cost 0 to 10^6, window 1 to 10^9. A
  # result with a value outside it is a result with no valid usage.
  test "a value at the wire bound is mapped; one outside it adds nothing" do
    at = %{"input_tokens" => 10 ** 9, "output_tokens" => 10 ** 9}
    meter = call(%Meter{}, at, 10 ** 6, %{@model => entry("list", 10 ** 9)})

    assert {%Helyx.Usage{input: 1_000_000_000, cost: 1_000_000, context_window: 1_000_000_000}, _} =
             Meter.done(meter)

    for {usage, total, window} <- [
          {%{at | "input_tokens" => 10 ** 9 + 1}, 1, 1},
          {Map.put(at, "cache_read_input_tokens", 10 ** 9 + 1), 1, 1},
          {at, 10 ** 6 + 0.01, 1},
          {at, -0.01, 1},
          {at, "1", 1},
          {at, 1, 10 ** 9 + 1},
          {at, 1, 0}
        ] do
      meter = Meter.result(%Meter{}, result(usage, total, %{@model => entry("list", window)}))
      assert {%Helyx.Usage{input: 0, cost: nil, context_window: nil}, _} = Meter.done(meter)
    end
  end

  describe "through the provider process" do
    @describetag :tmp_dir
    setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

    defp result_line(usage, total, queued \\ 0) do
      result("ok")
      |> Map.merge(result(usage, total))
      |> Map.put("queued_turn_count", queued)
      |> j()
    end

    test "an aborted turn, then a completed turn: the message holds both", %{bin: bin} = ctx do
      turn(bin, 1, 1, begin() ++ [delta("a"), j(aborted_line())])
      turn(bin, 1, 2, begin() ++ [delta("b"), result_line(@usage2, 0.3)])

      session = start(ctx)
      assert [%{outcome: :error}] = of_type(prompt(session, "one"), :turn_end)
      events = prompt(session, "two")

      assert [_user, %Message{role: :assistant, usage: usage}] = messages(events)

      assert %Helyx.Usage{input: 4, output: 8, cache_write: 35_830, cost: 0.3, cost_kind: :list} =
               usage
    end

    defp done_usage(actions) do
      assert [{:done, %{usage: usage}}] = for({:done, _} = done <- events_of(actions), do: done)
      usage
    end

    @sum %Helyx.Usage{input: 4, output: 8, cache_read: 24_862, cache_write: 35_830}

    test "a positive queued_turn_count: the done holds both results", %{bin: bin, work: work} do
      lines = [delta("a"), result_line(@usage1, 0.1, 2), delta("b"), result_line(@usage2, 0.25)]
      turn(bin, 1, 1, begin() ++ lines)

      usage = done_usage(run_direct([Message.user("x")], work))
      assert %{@sum | cost: 0.25, cost_kind: :list} == %{usage | context_window: nil}
    end

    test "an unresolved steer: the done holds the result before it and the one after",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [delta("a")])
      rest = [result_line(@usage1, 0.1), lifecycle("started"), delta("b")]
      turn(bin, 1, 2, rest ++ [result_line(@usage2, 0.25)])

      state = running_to(work, {:text_delta, "a"})
      {_from, [{:reply, _, :ok}], state} = request(state, {:steer, "t1", "s1", "more"})
      {actions, _state} = pump(ClaudeCode, state, [], &ended?/1)

      usage = done_usage(actions)
      assert %{@sum | cost: 0.25, cost_kind: :list} == %{usage | context_window: nil}
    end

    test "a user abort: the aborted result goes into the next done", %{bin: bin} = ctx do
      call = tool_use("toolu_01", %{"command" => "sleep 20"})
      turn(bin, 1, 1, begin() ++ [delta("so far"), call])
      aborted = aborted_line()
      script(bin, "ctl.1", [interrupted(), tool_result("toolu_01", "interrupted"), j(aborted)])
      turn(bin, 1, 2, begin() ++ [delta("b"), result_line(@usage2, 0.3)])

      session = start(ctx)
      :ok = Session.prompt(session, "sleep")
      until_tool_call()
      :ok = Session.abort(session)
      assert [%{outcome: :aborted}] = of_type(collect_until(:turn_end), :turn_end)

      assert [_user, %Message{role: :assistant, usage: usage}] = messages(prompt(session, "next"))

      assert %{@sum | cost: 0.3, cost_kind: :list, context_tokens: 19} == %{
               usage
               | context_window: nil
             }
    end

    defp until_tool_call do
      case List.last(collect_until(:message_update)) do
        %{data: %{tool_call: _}} -> :ok
        _ -> until_tool_call()
      end
    end

    # A result with `total_cost_usd` `total`; `:unknown` has no
    # `modelUsage` and `:bad` no valid `usage`, so the cost is not known.
    defp total_line({:unknown, total}),
      do: result("ok") |> Map.merge(result(@usage1, total, nil)) |> j()

    defp total_line({:bad, total}),
      do: result("ok") |> Map.merge(result(nil, total)) |> j()

    defp total_line(total), do: result_line(@usage1, total)

    defp result(text), do: JSON.decode!(Helyx.Test.ClaudeCodeFake.result(text))

    # An aborted turn's result, with the usage of one call.
    defp aborted_line, do: JSON.decode!(aborted()) |> Map.merge(result(@usage1, 0.1))

    defp usage(events) do
      [_user, %Message{role: :assistant, usage: %Helyx.Usage{} = usage}] = messages(events)
      usage
    end

    # The costs of the dones of program 1, one turn for each total, and
    # of the first done of program 2 after a resume of the session. The
    # stored usages, tokens included, are the live ones.
    defp resumed_costs(%{bin: bin} = ctx, totals, resumed_total) do
      for {total, k} <- Enum.with_index(totals, 1),
          do: turn(bin, 1, k, begin() ++ [total_line(total)])

      turn(bin, 2, 1, begin() ++ [total_line(resumed_total)])

      session = start(ctx)
      before = for _total <- totals, do: usage(prompt(session, "p"))
      GenServer.stop(Session.pid(session))

      {:ok, session} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
      {:ok, _, _} = Session.subscribe(session)
      assert for(%Message{role: :assistant, usage: u} <- transcript(session), do: u) == before
      Enum.map(before ++ [usage(prompt(session, "back"))], & &1.cost)
    end

    defp transcript(session), do: :sys.get_state(Session.pid(session)).transcript

    # `docs/features/usage-and-limits.md`, "Per provider": a resumed
    # program reports the totals of its harness session, so the mark is the
    # sum of the stored costs.
    test "a resume: the first done costs only the calls since the last stored done", ctx do
      [first, second, resumed] = resumed_costs(ctx, [0.1, 0.25], 0.4)
      assert first == 0.1
      assert_in_delta second, 0.15, 1.0e-12
      assert_in_delta resumed, 0.15, 1.0e-12
    end

    test "a resume after a stored cost that is not known: the cost is nil", ctx do
      assert [0.1, nil, nil] = resumed_costs(ctx, [0.1, {:unknown, 0.2}], 0.3)
    end

    test "a resume after a result with no valid usage: the cost is nil", ctx do
      assert [0.1, nil, nil] = resumed_costs(ctx, [0.1, {:bad, 0.2}], 0.3)
    end

    test "a resume where the total is below the stored sum: the cost is nil", ctx do
      assert [0.5, nil] = resumed_costs(ctx, [0.5], 0.3)
    end

    # A lost resume starts a new harness session, so its mark is 0.
    test "a lost resume: the cost of the new program is its own total", %{bin: bin} = ctx do
      turn(bin, 1, 1, begin() ++ [total_line(0.4)])
      script(bin, "start.2", [lost(sid())], "exit 1\n")
      turn(bin, 3, 1, [init(), replayed() | begin()] ++ [total_line(0.05)])

      session = start(ctx)
      assert usage(prompt(session, "p")).cost == 0.4
      GenServer.stop(Session.pid(session))

      {:ok, session} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
      {:ok, _, _} = Session.subscribe(session)
      assert usage(prompt(session, "back")).cost == 0.05
    end
  end
end
