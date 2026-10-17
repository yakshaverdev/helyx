defmodule Helyx.Session.SummaryTest do
  # The Helyx summary of a model provider (docs/features/summary-compaction.md),
  # through the session with `Helyx.Test.SummaryProvider` and
  # `Helyx.Test.SummaryPlugin`.
  use ExUnit.Case, async: true

  import Helyx.Test.Events

  alias Helyx.Session
  alias Helyx.Test.{Connected, SummaryPlugin, SummaryProvider}

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    plugins = [SummaryProvider, SummaryPlugin, Connected]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    %{core: core}
  end

  defp start(core, opts \\ []) do
    {:ok, session} = Session.start(core, [model: "sum/m"] ++ opts)
    {:ok, _, _} = Session.subscribe(session)
    session
  end

  defp turn(session, text) do
    :ok = Session.prompt(session, text)
    collect_until(:turn_end)
  end

  defp state(session), do: :sys.get_state(Session.pid(session))

  defp entries(dir, session) do
    [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  # The summary call's process ends after its `done`; the next call of the
  # session comes after its `provider_down`.
  defp await_call_end(session),
    do: wait_until(fn -> state(session).summary_call == nil end)

  @tag :tmp_dir
  test "an automatic summary runs before the call, and the context keeps the rest",
       %{core: core, tmp_dir: dir} do
    session = start(core, sessions_dir: dir)
    turn(session, "hello")
    events = turn(session, "summarize:ok")

    assert [%{trigger: :auto, tokens_before: 42, tokens_after: nil}] =
             of_type(events, :compaction)

    # The summary call adds no message; the model gets the summary and the
    # kept message only.
    assert [%{role: :user}, %{role: :assistant} = answer] = messages(events)
    assert Helyx.Message.text(answer) == "user:S:the summary\nuser:summarize:ok"
    assert List.last(events).data == %{outcome: :done}

    kept = hd(messages(events)).id

    assert [%{"summary" => "the summary", "first_kept_id" => ^kept, "tokens_before" => 42}] =
             for(%{"type" => "summary"} = e <- entries(dir, session), do: e)

    # The full history stays in the transcript; a resume keeps the summary.
    await_call_end(session)
    assert length(state(session).transcript) == 4
    Helyx.Test.SessionCase.stop_session(session, &GenServer.stop/1)

    {:ok, resumed} = Session.resume(core, sessions_dir: dir, id: session.id)
    {:ok, _, _} = Session.subscribe(resumed)
    assert %Helyx.Summary{text: "the summary", first_kept_id: ^kept} = state(resumed).summary
    events = turn(resumed, "next")
    assert final(events) =~ "user:S:the summary\nuser:summarize:ok\nassistant:"
  end

  test "a summary text of 65,536 bytes is kept, one byte more fails the summary",
       %{core: core} do
    session = start(core)
    events = turn(session, "summarize:max")
    assert [_] = of_type(events, :compaction)
    assert byte_size(state(session).summary.text) == 65_536

    await_call_end(session)
    events = turn(session, "summarize:big")
    assert of_type(events, :compaction) == []

    assert [%{text: "the summary failed: the summary is over 65536 bytes"}] =
             of_type(events, :notice)

    assert byte_size(state(session).summary.text) == 65_536
  end

  # docs/features/summary-compaction.md, decision 4: the turn goes on with
  # the context of the last summary.
  test "a failed summary keeps the previous summary, and the turn goes on", %{core: core} do
    session = start(core)
    turn(session, "summarize:ok")
    await_call_end(session)
    summary = state(session).summary

    for {mode, error} <- [
          {"fail", "the summary failed: :boom"},
          {"empty", "the summary failed: the summary is empty"},
          {"cut", "the summary failed: the summary ended with the stop reason max_tokens"},
          {"tool", "the summary failed: {:bad_summary_event"}
        ] do
      events = turn(session, "summarize:" <> mode)
      assert of_type(events, :compaction) == []
      assert [%{text: text}] = of_type(events, :notice)
      assert String.starts_with?(text, error)
      assert List.last(events).data == %{outcome: :done}

      assert final(events) =~
               ~r/^user:S:the summary\nuser:summarize:ok\n.*user:summarize:#{mode}$/s

      assert state(session).summary == summary
      await_call_end(session)
    end
  end

  test "a failed summary of a /compact fails it", %{core: core} do
    session = start(core)
    turn(session, "hello")
    assert :ok = Session.compact(session, "fail")
    events = collect_until(:turn_end)
    assert %{outcome: :error, error: "the summary failed: :boom"} = List.last(events).data
    assert state(session).summary == nil
  end

  test "a plan in the build after a summary, or a plan that keeps no message, fails it",
       %{core: core} do
    session = start(core)

    for text <- ["summarize:again", "summarize:bad_id"] do
      events = turn(session, text)
      assert %{outcome: :error, error: error} = List.last(events).data
      assert error =~ "bad_context"
      await_call_end(session)
    end
  end

  test "an abort stops the summary call, and the wait holds until it ends", %{core: core} do
    session = start(core)
    :ok = Session.prompt(session, "summarize:hang")
    wait_until(fn -> match?(%{status: :running}, state(session).summary_call) end)
    pid = state(session).summary_call.pid
    ref = Process.monitor(pid)

    assert :ok = Session.abort(session)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :aborted}}
    assert state(session).activity == :idle
    assert state(session).summary_call == nil
    assert List.last(collect_until(:turn_end)).data == %{outcome: :aborted}
    assert state(session).summary == nil
  end

  test "a second context request while a summary runs for the first is a bad action",
       %{core: core} do
    for why <- [:auto, :overflow] do
      session = start(core)
      :ok = Session.prompt(session, "overflow:hang")
      wait_until(fn -> match?(%{status: :running}, state(session).summary_call) end)
      send(state(session).conn.pid, {:again, why})
      assert %{outcome: :error, error: error} = List.last(collect_until(:turn_end)).data
      assert error =~ "bad_action"
      assert Process.alive?(Session.pid(session))
      await_call_end(session)
    end
  end

  test "a /compact summarizes as a turn with no message", %{core: core} do
    session = start(core)
    turn(session, "hello")
    assert :ok = Session.compact(session, "keep the plan")
    events = collect_until(:turn_end)
    assert [%{trigger: :manual, tokens_before: 42}] = of_type(events, :compaction)
    assert messages(events) == []
    assert List.last(events).data == %{outcome: :done}
    assert state(session).summary.text == "the summary"
  end

  test "a /compact whose plugin returns an error fails with its text", %{core: core} do
    session = start(core)
    turn(session, "plugin_error")
    assert :ok = Session.compact(session)
    assert List.last(collect_until(:turn_end)).data == %{outcome: :error, error: "nope"}
  end

  test "a context overflow summarizes once and calls the model again", %{core: core} do
    session = start(core)
    events = turn(session, "overflow")
    assert [%{trigger: :auto}] = of_type(events, :compaction)
    assert List.last(events).data == %{outcome: :done}
    assert final(events) == "user:S:the summary\nuser:overflow"

    await_call_end(session)
    events = turn(session, "overflow_always")
    assert [_] = of_type(events, :compaction)
    assert %{outcome: :error, error: error} = List.last(events).data
    assert error =~ "context_overflow"
  end

  test "a provider that keeps its own history gets no trigger", %{core: core} do
    Process.register(self(), Connected.controller(core))
    {:ok, session} = Session.start(core, model: "conn/echo")
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "summarize:ok")
    assert_receive {:compact, nil}
  end

  defmodule PlanPlugin do
    @moduledoc false
    # Returns `opts[:result]`.
    @behaviour Helyx.Compaction
    @impl true
    def compact(_context, opts), do: opts[:result]
  end

  test "the plan check of the context build, at its bounds" do
    user = %{Helyx.Message.user("hi") | id: "u1"}
    call = %Helyx.Message.ToolCall{id: "c", name: "bash", arguments: %{}}
    result = %{Helyx.Message.tool_result(call, {:ok, "r"}) | id: "t1"}
    context = %Helyx.Context{messages: [user, result]}
    plan = %Helyx.Summary.Plan{context: %Helyx.Context{}, first_kept_id: "u1", tokens_before: 0}
    prepare = &Helyx.Session.Stream.prepare(nil, PlanPlugin, context, [result: &1] ++ &2)
    bad = {:error, {:bad_context, :compaction}}

    for tokens <- [0, 1_000_000_000] do
      plan = %{plan | tokens_before: tokens}
      assert prepare.({:summarize, plan}, trigger: :auto) == {:summarize, plan}
    end

    for tokens <- [-1, 1_000_000_001, nil, 1.0] do
      assert prepare.({:summarize, %{plan | tokens_before: tokens}}, trigger: :auto) == bad
    end

    assert prepare.({:summarize, plan}, trigger: nil) == bad
    assert prepare.({:summarize, %{plan | first_kept_id: "t1"}}, trigger: :auto) == bad
    assert prepare.({:summarize, %{plan | first_kept_id: "u2"}}, trigger: :auto) == bad
    assert prepare.({:summarize, %{plan | context: %{}}}, trigger: :auto) == bad
    assert prepare.({:summarize, Map.put(plan, :extra, 1)}, trigger: :auto) == bad
    assert prepare.({:error, "nope"}, trigger: :auto) == {:error, "nope"}
    assert prepare.({:error, :nope}, trigger: :auto) == bad
  end

  defp final(events), do: events |> messages() |> List.last() |> Helyx.Message.text()
end
