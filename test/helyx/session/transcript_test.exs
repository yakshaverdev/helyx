defmodule Helyx.Session.TranscriptTest do
  use ExUnit.Case, async: true

  alias Helyx.Message
  alias Helyx.Session.Transcript

  defp call(id), do: %Message.ToolCall{id: id, name: "read", arguments: %{}}

  defp assistant(content, model \\ "claude-code/sonnet"),
    do: %Message{role: :assistant, content: content, model: model}

  defp result(id), do: Message.tool_result(call(id), {:ok, "done"})

  describe "open_calls/1" do
    test "gives the calls with no result, in call order" do
      transcript = [
        Message.user("hi"),
        assistant([call("a"), call("b"), call("c")]),
        result("b")
      ]

      assert Transcript.open_calls(transcript) == [call("a"), call("c")]
    end

    test "a result answers the first open call with its id, and a stray result changes nothing" do
      transcript = [assistant([call("a"), call("a")]), result("a"), result("x")]
      assert Transcript.open_calls(transcript) == [call("a")]
      assert Transcript.open_calls([]) == []
    end

    test "only the last assistant message has open calls, and none after another message" do
      assert Transcript.open_calls([assistant([call("a")]), assistant([call("b")])]) ==
               [call("b")]

      assert Transcript.open_calls([assistant([call("a")]), Message.user("next")]) == []
    end
  end

  describe "repair/1" do
    # The session stopped while the call ran (docs/features/interrupted-calls.md).
    @interrupted "The session stopped while this tool call ran, and its result was lost. " <>
                   "The call may have run in full, in part, or not at all. " <>
                   "Check its effects before you repeat it."

    defp interrupted(id), do: Message.tool_result(call(id), {:error, @interrupted})

    test "leaves a transcript with no open calls unchanged" do
      transcript = [Message.user("hi"), assistant([call("a")]), result("a"), assistant([])]
      assert Transcript.repair(transcript) == transcript
      assert Transcript.repair([]) == []

      # A stored aborted result of a user abort stays aborted.
      aborted = Message.tool_result(call("a"), {:error, "aborted"})
      transcript = [assistant([call("a")]), aborted, Message.user("next")]
      assert Transcript.repair(transcript) == transcript
    end

    test "a call never answered gets its result right after it, before the next user message" do
      transcript = [assistant([call("a")]), Message.user("next"), assistant([])]

      assert Transcript.repair(transcript) ==
               [assistant([call("a")]), interrupted("a"), Message.user("next"), assistant([])]
    end

    test "a result after a later message does not answer the call, and it is dropped" do
      transcript = [assistant([call("a")]), Message.user("next"), result("a")]

      assert Transcript.repair(transcript) ==
               [assistant([call("a")]), interrupted("a"), Message.user("next")]
    end

    test "a result with an unknown id, a second result, and a result with no call before it are dropped" do
      transcript = [
        result("x"),
        Message.user("hi"),
        assistant([call("a"), call("b")]),
        result("x"),
        result("a"),
        result("a"),
        result("b"),
        Message.user("next"),
        result("b")
      ]

      repaired = Transcript.repair(transcript)

      assert repaired ==
               [
                 Message.user("hi"),
                 assistant([call("a"), call("b")]),
                 result("a"),
                 result("b"),
                 Message.user("next")
               ]

      assert Transcript.repair(repaired) == repaired
    end

    test "with two calls and one answered, the other gets its result after the answered one" do
      transcript = [assistant([call("a"), call("b")]), result("b"), Message.user("next")]

      assert Transcript.repair(transcript) ==
               [
                 assistant([call("a"), call("b")]),
                 result("b"),
                 interrupted("a"),
                 Message.user("next")
               ]
    end

    test "a reused call id is answered only by a result that follows its own message" do
      transcript = [
        assistant([call("a")]),
        result("a"),
        assistant([call("a")]),
        Message.user("next"),
        assistant([call("a")]),
        result("a")
      ]

      assert Transcript.repair(transcript) ==
               List.insert_at(transcript, 3, interrupted("a"))

      assert Transcript.open_calls(Transcript.repair(transcript)) == []
    end

    test "open calls at the end get their results at the end, and a second pass adds nothing" do
      transcript = [Message.user("hi"), assistant([call("a"), call("b")])]
      answered = Transcript.repair(transcript)
      assert answered == transcript ++ [interrupted("a"), interrupted("b")]
      assert Transcript.repair(answered) == answered
    end
  end

  describe "resume/3" do
    defp used(cost),
      do: %{assistant([]) | usage: %Helyx.Usage{input: 1, cost: cost, cost_kind: cost && :list}}

    test "sums the usages since the resume id; a message with no usage adds nothing" do
      transcript = [used(0.5), Message.user("a"), used(0.1), assistant([]), used(0.2)]

      {id, usage} =
        Transcript.resume(transcript, %{"claude-code" => {"h1", 1, nil}}, "claude-code")

      assert id == "h1"
      assert %Helyx.Usage{input: 2, cost_kind: :list} = usage
      assert_in_delta usage.cost, 0.3, 1.0e-12
    end

    test "a cost that is not known makes the sum's cost nil; no usage gives nil" do
      ids = %{"claude-code" => {"h1", 0, nil}}

      assert {"h1", %Helyx.Usage{cost: nil}} =
               Transcript.resume([used(0.1), used(nil)], ids, "claude-code")

      assert Transcript.resume([used(0.1)], %{"claude-code" => {"h1", 1, 1}}, "claude-code") ==
               {"h1", nil}
    end

    # The transcript before the turn. A turn that ended with no `done` has
    # no assistant message with a usage after its last user message.
    test "after a turn with no done, the sum's cost is nil and its tokens stay" do
      cut = %{assistant([%Message.Text{text: "so far"}]) | stop_reason: :aborted}
      failed = %{cut | stop_reason: :error}
      cut_call = %{assistant([call("c1")]) | stop_reason: :tool_use}
      after_compaction = %{"claude-code" => {"h1", 0, 2}}
      ids = %{"claude-code" => {"h1", 0, nil}}

      for {transcript, ids} <- [
            {[used(0.1), Message.user("a"), cut], after_compaction},
            {[used(0.1), Message.user("a"), failed], after_compaction},
            {[
               used(0.1),
               Message.user("a"),
               cut_call,
               Message.tool_result(call("c1"), {:error, "aborted"})
             ], ids},
            {[used(0.1), Message.user("a")], ids}
          ] do
        assert {"h1", %Helyx.Usage{input: 1, cost: nil, cost_kind: nil}} =
                 Transcript.resume(transcript, ids, "claude-code")
      end
    end

    test "after a turn with no done and no usage since the resume id, the cost is nil" do
      ids = %{"claude-code" => {"h1", 1, 1}}

      assert Transcript.resume([used(0.1), Message.user("a")], ids, "claude-code") ==
               {"h1", %Helyx.Usage{}}
    end

    test "a done with a usage after the cut turn makes the cost known again" do
      cut_call = %{assistant([call("c1")]) | stop_reason: :tool_use}
      aborted = Message.tool_result(call("c1"), {:error, "aborted"})
      transcript = [used(0.1), Message.user("a"), cut_call, aborted, Message.user("b"), used(0.2)]

      {"h1", usage} =
        Transcript.resume(transcript, %{"claude-code" => {"h1", 0, nil}}, "claude-code")

      assert_in_delta usage.cost, 0.3, 1.0e-12
    end

    test "after another provider, the sum starts at the new resume id" do
      other = %{used(0.4) | model: "fake/echo"}
      transcript = [used(0.5), other, used(0.1)]

      {id, usage} =
        Transcript.resume(transcript, %{"claude-code" => {"h2", 2, nil}}, "claude-code")

      assert {id, usage.cost} == {"h2", 0.1}
    end

    test "with no resume id there is no usage" do
      assert Transcript.resume([used(0.1)], %{}, "claude-code") == {nil, nil}
    end
  end

  describe "resumable/3" do
    test "resumes when the provider answered last after its session started" do
      transcript = [Message.user("a"), assistant([])]

      assert Transcript.resumable(transcript, %{"claude-code" => {"h1", 0, nil}}, "claude-code") ==
               "h1"
    end

    test "does not resume without a session, before the session answered, or after another provider" do
      transcript = [Message.user("a"), assistant([])]
      sessions = %{"claude-code" => {"h1", 1, nil}}

      assert Transcript.resumable(transcript, %{}, "claude-code") == nil
      assert Transcript.resumable(transcript, sessions, "claude-code") == nil

      other = transcript ++ [assistant([], "fake/echo")]
      assert Transcript.resumable(other, %{"claude-code" => {"h1", 0, nil}}, "claude-code") == nil
    end

    test "does not resume when an abort or a failure cut the last assistant message" do
      sessions = %{"claude-code" => {"h1", 0, nil}}

      for stop <- [:aborted, :error] do
        cut = [Message.user("a"), assistant([]), %{assistant([]) | stop_reason: stop}]
        assert Transcript.resumable(cut, sessions, "claude-code") == nil
      end
    end

    test "does not resume when a resume found a call of the last assistant message open" do
      sessions = %{"claude-code" => {"h1", 0, nil}}
      file = [Message.user("a"), %{assistant([call("c1"), call("c2")]) | stop_reason: :tool_use}]
      answered = file ++ [result("c1")]

      # The provider got the answered result; a crash kept the other from it.
      assert Transcript.resumable(answered, sessions, "claude-code") == "h1"
      assert Transcript.resumable(Transcript.repair(answered), sessions, "claude-code") == nil
      assert Transcript.resumable(Transcript.repair(file), sessions, "claude-code") == nil
      later = Transcript.repair(answered ++ [Message.user("b")])
      assert Transcript.resumable(later, sessions, "claude-code") == nil

      # A compaction under the id does not give the provider the result.
      compacted = Transcript.compacted(sessions, "claude-code", 1)
      assert Transcript.resumable(answered, compacted, "claude-code") == "h1"
      assert Transcript.resumable(Transcript.repair(answered), compacted, "claude-code") == nil

      # A fresh start after the resume read the replay with the result, and
      # a compaction under its id resumes.
      fresh_compacted = %{"claude-code" => {"h2", 1, 1}}

      assert Transcript.resumable(Transcript.repair(answered), fresh_compacted, "claude-code") ==
               "h2"

      # A stored `aborted` result went to the provider live.
      aborted = answered ++ [Message.tool_result(call("c2"), {:error, "aborted"})]
      assert Transcript.resumable(aborted, sessions, "claude-code") == "h1"

      # The answer of the fresh start under a new id resumes again.
      fresh = Transcript.repair(answered) ++ [Message.user("b"), assistant([])]

      assert Transcript.resumable(fresh, %{"claude-code" => {"h2", 1, nil}}, "claude-code") ==
               "h2"
    end

    test "resumes after a compaction with no assistant message after it" do
      cut = [Message.user("a"), %{assistant([]) | stop_reason: :aborted}]
      ids = Transcript.compacted(%{"claude-code" => {"h1", 0, nil}}, "claude-code", 2)
      assert Transcript.resumable(cut, ids, "claude-code") == nil
      ids = Transcript.compacted(ids, "claude-code", 1)
      assert Transcript.resumable(cut, ids, "claude-code") == "h1"
      assert Transcript.resumable(cut ++ [cut |> List.last()], ids, "claude-code") == nil
      assert Transcript.compacted(%{}, "claude-code", 1) == %{}

      # The compaction does not lift the check of the provider that answered last.
      other = [Message.user("a"), assistant([], "fake/echo")]
      assert Transcript.resumable(other, ids, "claude-code") == nil
    end

    test "does not resume after an assistant message with no model" do
      transcript = [assistant([], nil)]

      assert Transcript.resumable(transcript, %{"claude-code" => {"h1", 0, nil}}, "claude-code") ==
               nil
    end

    # The label stands at a place in the session file. The repair inserts
    # and drops tool results, so a count of all messages would need a shift,
    # but the count of the assistant messages before the label holds. The
    # reference is the old rule on the file, where its count needed no
    # shift: drop the messages before the label's place, then take the last
    # assistant message, from the provider and not cut. Empty files and
    # replies with no tool call are generated too. ExUnit seeds `:rand` per
    # test, so `mix test --seed` repeats a failure. A call of the last
    # assistant message with no result in the file gets an interrupted
    # result at the repair, so no id resumes (#584).
    test "on random transcripts, the assistant count gives the answer of the label's place in the file" do
      for _round <- 1..2000 do
        file = for _ <- 1..Enum.random(0..12)//1, do: random_message()
        place = Enum.random(0..length(file))
        before = Transcript.assistant_count(Enum.take(file, place))
        ids = %{"claude-code" => {"h1", before, nil}}

        assert Transcript.resumable(Transcript.repair(file), ids, "claude-code") ==
                 expected_resume(file, place),
               "file: #{inspect(file)}, place: #{place}"
      end
    end

    defp random_message do
      case Enum.random([:user, :assistant, :assistant, :result, :result]) do
        :user ->
          Message.user("u")

        :assistant ->
          calls = for _ <- 1..Enum.random(0..2)//1, do: call(Enum.random(["a", "b"]))

          model = Enum.random(["claude-code/sonnet", "fake/echo", nil])
          stop = Enum.random([nil, :end_turn, :tool_use, :aborted, :error])
          %{assistant(calls, model) | stop_reason: stop}

        :result ->
          result(Enum.random(["a", "b", "x"]))
      end
    end

    defp expected_resume(file, place) do
      last =
        file
        |> Enum.drop(place)
        |> Enum.filter(&match?(%Message{role: :assistant}, &1))
        |> List.last()

      case last do
        %Message{model: "claude-code/" <> _, stop_reason: stop}
        when stop not in [:aborted, :error] ->
          if open_call?(file), do: nil, else: "h1"

        _other ->
          nil
      end
    end

    # A call of the last assistant message of the file has no result in the
    # results right after it: more calls than results of one id (#584).
    defp open_call?(file) do
      {after_last, rest} =
        file |> Enum.reverse() |> Enum.split_while(&(not match?(%Message{role: :assistant}, &1)))

      [%Message{content: calls} | _] = rest
      results = after_last |> Enum.reverse() |> Enum.take_while(&(&1.role == :tool_result))
      ids = for %Message.ToolCall{id: id} <- calls, do: id

      Enum.any?(ids, fn id ->
        Enum.count(ids, &(&1 == id)) > Enum.count(results, &(&1.tool_call_id == id))
      end)
    end
  end
end
