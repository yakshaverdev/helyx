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

  describe "repair/2" do
    defp aborted(id), do: Message.tool_result(call(id), {:error, "aborted"})

    defp abort(transcript) do
      {transcript, sessions} = Transcript.repair(transcript, %{})
      assert sessions == %{}
      transcript
    end

    test "a program session count moves past the results inserted before it, and only those" do
      # A count right after an open call's message includes its inserted
      # results: the live session inserted them at the resume, before any
      # program session could start.
      transcript = [
        Message.user("hi"),
        assistant([call("a"), call("b")]),
        Message.user("next"),
        assistant([call("c")]),
        Message.user("last")
      ]

      sessions = %{"early" => {"e", 1}, "at" => {"t", 2}, "late" => {"l", 4}, "end" => {"n", 5}}
      {answered, shifted} = Transcript.repair(transcript, sessions)

      assert shifted == %{
               "early" => {"e", 1},
               "at" => {"t", 4},
               "late" => {"l", 7},
               "end" => {"n", 8}
             }

      # Each count drops the same messages from the answered transcript as
      # it did from the file, plus the results inserted before it.
      assert Enum.at(answered, 4) == Message.user("next")
      assert Enum.at(answered, 7) == Message.user("last")
    end

    test "leaves a transcript with no open calls unchanged" do
      transcript = [Message.user("hi"), assistant([call("a")]), result("a"), assistant([])]
      assert abort(transcript) == transcript
      assert abort([]) == []
    end

    test "a call never answered gets its result right after it, before the next user message" do
      transcript = [assistant([call("a")]), Message.user("next"), assistant([])]

      assert abort(transcript) ==
               [assistant([call("a")]), aborted("a"), Message.user("next"), assistant([])]
    end

    test "a result after a later message does not answer the call, and it is dropped" do
      transcript = [assistant([call("a")]), Message.user("next"), result("a")]

      assert abort(transcript) ==
               [assistant([call("a")]), aborted("a"), Message.user("next")]
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

      repaired = abort(transcript)

      assert repaired ==
               [
                 Message.user("hi"),
                 assistant([call("a"), call("b")]),
                 result("a"),
                 result("b"),
                 Message.user("next")
               ]

      assert abort(repaired) == repaired
    end

    test "a count moves back by the results dropped before it, and forward by the results inserted" do
      transcript = [
        Message.user("hi"),
        assistant([call("a"), call("b")]),
        result("x"),
        result("a"),
        Message.user("next"),
        result("a"),
        assistant([])
      ]

      # 3 is after the stray result, 5 is after the insert point, 6 is after
      # the result that follows a later message.
      sessions = %{"a" => {"a", 2}, "b" => {"b", 3}, "c" => {"c", 5}, "d" => {"d", 6}}
      {repaired, shifted} = Transcript.repair(transcript, sessions)

      assert repaired == [
               Message.user("hi"),
               assistant([call("a"), call("b")]),
               result("a"),
               aborted("b"),
               Message.user("next"),
               assistant([])
             ]

      assert shifted == %{"a" => {"a", 2}, "b" => {"b", 2}, "c" => {"c", 5}, "d" => {"d", 5}}

      # A count drops the same kept messages as in the file.
      assert Enum.drop(repaired, 5) == [assistant([])]
    end

    test "with two calls and one answered, the other gets its result after the answered one" do
      transcript = [assistant([call("a"), call("b")]), result("b"), Message.user("next")]

      assert abort(transcript) ==
               [
                 assistant([call("a"), call("b")]),
                 result("b"),
                 aborted("a"),
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

      assert abort(transcript) ==
               List.insert_at(transcript, 3, aborted("a"))

      assert Transcript.open_calls(abort(transcript)) == []
    end

    test "open calls at the end get their results at the end, and a second pass adds nothing" do
      transcript = [Message.user("hi"), assistant([call("a"), call("b")])]
      answered = abort(transcript)
      assert answered == transcript ++ [aborted("a"), aborted("b")]
      assert abort(answered) == answered
    end
  end

  describe "last_assistant/1" do
    test "gives the last assistant message, or nil" do
      last = assistant([], "fake/echo")

      assert Transcript.last_assistant([assistant([]), Message.user("x"), last, result("a")]) ==
               last

      assert Transcript.last_assistant([Message.user("x")]) == nil
    end
  end

  describe "resumable/3" do
    test "resumes when the provider answered last after its session started" do
      transcript = [Message.user("a"), assistant([])]

      assert Transcript.resumable(transcript, %{"claude-code" => {"h1", 1}}, "claude-code") ==
               "h1"
    end

    test "does not resume without a session, before the session answered, or after another provider" do
      transcript = [Message.user("a"), assistant([])]
      sessions = %{"claude-code" => {"h1", 2}}

      assert Transcript.resumable(transcript, %{}, "claude-code") == nil
      assert Transcript.resumable(transcript, sessions, "claude-code") == nil

      other = transcript ++ [assistant([], "fake/echo")]
      assert Transcript.resumable(other, %{"claude-code" => {"h1", 0}}, "claude-code") == nil
    end

    test "does not resume when an abort or a failure cut the last assistant message" do
      sessions = %{"claude-code" => {"h1", 1}}

      for stop <- [:aborted, :error] do
        cut = [Message.user("a"), assistant([]), %{assistant([]) | stop_reason: stop}]
        assert Transcript.resumable(cut, sessions, "claude-code") == nil
      end
    end

    test "does not resume after an assistant message with no model" do
      transcript = [assistant([], nil)]
      assert Transcript.resumable(transcript, %{"claude-code" => {"h1", 0}}, "claude-code") == nil
    end
  end
end
