defmodule Helyx.Session.PersistenceTest do
  # The session file: writes, resume, write failures, and the supervisor
  # after a resume. Also the UTF-8 check of prompts.
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Event, Session}

  setup :start_core

  @tag :tmp_dir
  test "a session with a sessions dir writes a header and completed messages", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/blocks", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    collect_until(:turn_end)

    [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
    entries = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert [
             %{"type" => "session", "version" => 1, "model" => "test/blocks"},
             %{"type" => "message", "role" => "user"},
             %{"type" => "message", "role" => "assistant", "stop_reason" => "end_turn"},
             %{"type" => "message", "role" => "tool_result", "tool_call_id" => "call_1"},
             %{"type" => "message", "role" => "assistant"}
           ] = entries

    assert Enum.at(entries, 0)["cwd"] == File.cwd!()

    assert [%{"type" => "thinking"}, %{"type" => "text"}, %{"type" => "tool_call"}] =
             Enum.at(entries, 2)["content"]

    ids = Enum.map(entries, & &1["id"])
    assert Enum.map(entries, & &1["parent_id"]) == [nil | Enum.drop(ids, -1)]
  end

  # The sessions folder holds prompts and tool output (#683).
  for suffix <- ["", "/", "/.", "/new/.."] do
    @tag :tmp_dir
    test "a start creates a new sessions folder with mode 0700: #{inspect(suffix)}", %{
      core: core,
      tmp_dir: tmp
    } do
      dir = Path.join(tmp, "sessions")

      {:ok, _session} =
        Session.start(core, model: "test/ok", sessions_dir: dir <> unquote(suffix))

      assert mode(dir) == 0o700
    end
  end

  # A path through a folder that is missing, then `..`, names one that exists.
  for path <- ["sessions", "sessions/new/..", "gone/../sessions"] do
    @tag :tmp_dir
    test "a start keeps the mode of a sessions folder that exists: #{path}", %{
      core: core,
      tmp_dir: tmp
    } do
      dir = Path.join(tmp, "sessions")
      File.mkdir!(dir)
      File.chmod!(dir, 0o755)

      {:ok, _session} =
        Session.start(core, model: "test/ok", sessions_dir: Path.join(tmp, unquote(path)))

      assert mode(dir) == 0o755
    end
  end

  # `docs/features/usage-and-limits.md`, "Core checks".
  @tag :tmp_dir
  test "a resumed session has the usage of each message of the live session", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/usage", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")
    collect_until(:turn_end)
    {:ok, live, _ref} = Session.subscribe(session)
    stop_session(session, &GenServer.stop/1)

    {:ok, resumed} = Session.resume(core, sessions_dir: dir)
    {:ok, snapshot, _ref} = Session.subscribe(resumed)

    usages = Enum.map(live.messages, & &1.usage)
    assert [nil, %Helyx.Usage{cost: 0.5}, nil, %Helyx.Usage{} = unknown] = usages
    assert unknown == %Helyx.Usage{}
    assert Enum.map(snapshot.messages, & &1.usage) == usages
  end

  @tag :tmp_dir
  test "resume restores the transcript and the next provider call sees it", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/transcript", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:turn_end)) == "user:hello"

    stop_session(session, &GenServer.stop/1)

    {:ok, resumed} = Session.resume(core, sessions_dir: dir)
    assert resumed.id == session.id
    {:ok, _, _} = Session.subscribe(resumed)

    :ok = Session.prompt(resumed, "again")

    assert final_text(collect_until(:turn_end)) ==
             "user:hello\nassistant:user:hello\nuser:again"
  end

  for {model, stop} <- [{"hang", :aborted}, {"crash", :error}] do
    @tag :tmp_dir
    test "a text-only partial message of an #{stop} turn joins with stop #{stop}", %{
      core: core,
      tmp_dir: dir
    } do
      {:ok, session} = Session.start(core, model: "test/#{unquote(model)}", sessions_dir: dir)
      {:ok, _, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")

      if unquote(stop) == :aborted do
        assert_receive {:helyx_event, %Event{type: :message_update}}
        :ok = Session.abort(session)
      end

      assert stop_reason(collect_until(:turn_end)) == unquote(stop)
      {:ok, snapshot, _ref} = Session.subscribe(session)
      assert [_user, %{stop_reason: unquote(stop)}] = snapshot.messages

      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      last = path |> File.read!() |> String.split("\n", trim: true) |> List.last()
      assert %{"role" => "assistant", "stop_reason" => unquote("#{stop}")} = JSON.decode!(last)

      :ok = Session.set_model(session, "test/transcript")
      :ok = Session.prompt(session, "next")
      assert final_text(collect_until(:turn_end)) == "user:hello\nassistant:so far\nuser:next"

      stop_session(session, &GenServer.stop/1)
      {:ok, resumed} = Session.resume(core, sessions_dir: dir)
      {:ok, _, _} = Session.subscribe(resumed)
      :ok = Session.prompt(resumed, "again")

      # The answer of the "next" turn holds the context it saw.
      seen = "user:hello\nassistant:so far\nuser:next"

      assert final_text(collect_until(:turn_end)) ==
               "#{seen}\nassistant:#{seen}\nuser:again"
    end
  end

  describe "the session supervisor after a resume (#103)" do
    # The session process loads the transcript (#589), so no copy of it passes
    # through the supervisor. Short texts stay on the heap; this transcript
    # is about 7 MB there, and the margin is 1 MB.
    @describetag :tmp_dir

    setup %{core: core, tmp_dir: dir} do
      {:ok, file} = Helyx.Session.File.create(dir, "big000000000", File.cwd!(), "test/transcript")

      Enum.reduce(1..20_000, file, fn i, file ->
        Helyx.Test.SessionFile.append_message(file, Helyx.Message.user("m#{i}"))
      end)

      sup = Process.whereis(Helyx.Core.session_supervisor(core))
      {:memory, before} = Process.info(sup, :memory)
      %{sup: sup, limit: before + 1_000_000}
    end

    @tag :slow
    test "keeps no copy after a start and after a failed start", %{
      core: core,
      tmp_dir: dir,
      sup: sup,
      limit: limit
    } do
      {:ok, _session} = Session.resume(core, sessions_dir: dir)
      await(fn -> memory(sup) < limit end, "supervisor memory under #{limit}")

      # The Registry rejects the second start in the supervisor, before the
      # init (docs/features/session-lock.md).
      assert {:error, {:session_locked, "big000000000"}} = Session.resume(core, sessions_dir: dir)
      await(fn -> memory(sup) < limit end, "supervisor memory under #{limit}")
    end

    @tag :slow
    test "keeps no copy when the caller dies during the start", %{
      core: core,
      tmp_dir: dir,
      sup: sup,
      limit: limit
    } do
      # The start message waits in the mailbox of the suspended supervisor
      # while the caller dies.
      :erlang.suspend_process(sup)
      {caller, ref} = spawn_monitor(fn -> Session.resume(core, sessions_dir: dir) end)

      await(
        fn -> Process.info(sup, :message_queue_len) != {:message_queue_len, 0} end,
        "the start message in the supervisor mailbox"
      )

      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, _, _, :killed}
      :erlang.resume_process(sup)

      await(fn -> memory(sup) < limit end, "supervisor memory under #{limit}")
    end
  end

  defp memory(pid), do: pid |> Process.info(:memory) |> elem(1)

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # The text that a resume gives an open call (transcript_test.exs pins it).
  @interrupted elem(Helyx.Session.Transcript.interrupted_result(), 1)

  @tag :tmp_dir
  test "a resume writes nothing, and each open call gets its interrupted result right after it, once",
       %{core: core, tmp_dir: dir} do
    call = %Helyx.Message.ToolCall{id: "c1", name: "slow", arguments: %{}}
    {:ok, file} = Helyx.Session.File.create(dir, "reuse0000000", File.cwd!(), "test/transcript")

    [
      %Helyx.Message{role: :assistant, stop_reason: :tool_use, content: [call]},
      Helyx.Message.tool_result(call, {:ok, "first answer"}),
      %Helyx.Message{role: :assistant, stop_reason: :tool_use, content: [call]}
    ]
    |> Enum.reduce(file, &Helyx.Test.SessionFile.append_message(&2, &1))

    answered = [
      {:assistant, ""},
      {:tool_result, "first answer"},
      {:assistant, ""},
      {:tool_result, @interrupted}
    ]

    written = File.read!(file.path)
    {:ok, session} = Session.resume(core, sessions_dir: dir)
    assert File.read!(file.path) == written

    # The provider request has the result of the reused id, right after it.
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "one")

    assert final_text(collect_until(:turn_end)) ==
             Enum.map_join(answered ++ [{:user, "one"}], "\n", fn {r, t} -> "#{r}:#{t}" end)

    stop_session(session, &GenServer.stop/1)

    # The turn appended after the open call; the next resume puts the
    # result right after the call again, not at the end, and only once.
    written = File.read!(file.path)
    {:ok, session} = Session.resume(core, sessions_dir: dir)
    assert File.read!(file.path) == written
    {:ok, snapshot, _} = Session.subscribe(session)
    roles_texts = Enum.map(snapshot.messages, &{&1.role, Helyx.Message.text(&1)})
    assert Enum.take(roles_texts, 4) == answered
    assert [{:user, "one"}, {:assistant, _reply}] = Enum.drop(roles_texts, 4)
  end

  @tag :tmp_dir
  test "a resume label counts the assistant messages before it, not the inserted results", %{
    core: core,
    tmp_dir: dir
  } do
    call = %Helyx.Message.ToolCall{id: "c1", name: "slow", arguments: %{}}
    {:ok, file} = Helyx.Session.File.create(dir, "counts000000", File.cwd!(), "test/transcript")

    file
    |> Helyx.Test.SessionFile.append_message(%Helyx.Message{role: :assistant, content: [call]})
    |> Helyx.Test.SessionFile.append_message(Helyx.Message.user("next"))
    |> Helyx.Session.File.append_resume_id("claude-code", "h1")

    {:ok, session} = Session.resume(core, sessions_dir: dir)
    state = :sys.get_state(Session.pid(session))
    assert length(state.transcript) == 3
    assert state.resume_ids == %{"claude-code" => {"h1", 1, nil}}
  end

  @tag :tmp_dir
  test "a resume drops each result with no open call, keeps the label count, and writes nothing",
       %{core: core, tmp_dir: dir} do
    call = %Helyx.Message.ToolCall{id: "c1", name: "slow", arguments: %{}}
    stray = %Helyx.Message.ToolCall{id: "x", name: "slow", arguments: %{}}
    {:ok, file} = Helyx.Session.File.create(dir, "orphan000000", File.cwd!(), "test/transcript")

    file
    |> Helyx.Test.SessionFile.append_message(Helyx.Message.user("hi"))
    |> Helyx.Test.SessionFile.append_message(%Helyx.Message{role: :assistant, content: [call]})
    |> Helyx.Test.SessionFile.append_message(Helyx.Message.tool_result(stray, {:ok, "unknown"}))
    |> Helyx.Test.SessionFile.append_message(Helyx.Message.tool_result(call, {:ok, "answer"}))
    |> Helyx.Test.SessionFile.append_message(Helyx.Message.tool_result(call, {:ok, "second"}))
    |> Helyx.Test.SessionFile.append_message(Helyx.Message.user("next"))
    |> Helyx.Test.SessionFile.append_message(Helyx.Message.tool_result(call, {:ok, "late"}))
    |> Helyx.Session.File.append_resume_id("claude-code", "h1")

    repaired = [{:user, "hi"}, {:assistant, ""}, {:tool_result, "answer"}, {:user, "next"}]

    written = File.read!(file.path)
    {:ok, session} = Session.resume(core, sessions_dir: dir)
    assert File.read!(file.path) == written
    assert :sys.get_state(Session.pid(session)).resume_ids == %{"claude-code" => {"h1", 1, nil}}

    # A client mounts from the snapshot: no result there lacks its call.
    {:ok, snapshot, _} = Session.subscribe(session)
    assert Enum.map(snapshot.messages, &{&1.role, Helyx.Message.text(&1)}) == repaired

    # The provider gets the repaired history.
    :ok = Session.prompt(session, "one")

    assert final_text(collect_until(:turn_end)) ==
             Enum.map_join(repaired ++ [{:user, "one"}], "\n", fn {r, t} -> "#{r}:#{t}" end)
  end

  @tag :tmp_dir
  test "resume after a crash mid-turn says that every open tool call may have run",
       %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/abort", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")

    assert_receive {:helyx_event,
                    %Event{type: :message_end, data: %{message: %{role: :assistant}}}}

    # The kill frees the lock once perl reads the end of its stdin, and
    # `stop_session/2` waits for it.
    stop_session(session, &Process.exit(&1, :kill))
    {:ok, _} = Session.resume(core, sessions_dir: dir)

    resumed = %Session{id: session.id, core: core}
    {:ok, _, _} = Session.subscribe(resumed)

    :ok = Session.prompt(resumed, "again")
    assert final_text(collect_until(:turn_end)) == Enum.join(List.duplicate(@interrupted, 3), "|")
  end

  # #584: the provider never got the derived result, so it starts fresh,
  # and its first turn carries the result in the history.
  @tag :tmp_dir
  test "a resume with an interrupted call of a labelled provider starts that provider fresh",
       %{tmp_dir: dir} do
    alias Helyx.Test.Connected
    core = start_core([Connected])
    Process.register(self(), Connected.controller(core))
    call = %Helyx.Message.ToolCall{id: "c1", name: "slow", arguments: %{}}
    {:ok, file} = Helyx.Session.File.create(dir, "label0000000", File.cwd!(), "conn/hang")

    file
    |> Helyx.Test.SessionFile.append_message(Helyx.Message.user("push"))
    |> Helyx.Session.File.append_resume_id("conn", "L")
    |> Helyx.Test.SessionFile.append_message(%Helyx.Message{
      role: :assistant,
      model: "conn/hang",
      stop_reason: :tool_use,
      content: [call]
    })

    {:ok, session} = Session.resume(core, sessions_dir: dir)
    :ok = Session.prompt(session, "again")
    assert_receive {:conn, :init, proc, {"hang", _tools, opts}}
    assert opts[:resume_id] == nil
    assert_receive {:conn, :turn, ^proc, {:turn, _turn_id, context}}
    assert Enum.any?(context.messages, &(Helyx.Message.text(&1) == @interrupted))
  end

  test "a prompt that is not valid UTF-8 is rejected and the session lives", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _, _} = Session.subscribe(session)

    assert {:error, :invalid_utf8} = Session.prompt(session, <<255, 254>>)

    :ok = Session.prompt(session, "hello")
    assert stop_reason(collect_until(:turn_end)) == :end_turn
  end

  @tag :tmp_dir
  test "a write failure turns persistence off and the session lives", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)

    File.rm_rf!(dir)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)
    assert stop_reason(events) == :end_turn
    assert [%{text: "the session file could not be written" <> _}] = notices(events)

    # The notice goes out once: persistence stays off.
    :ok = Session.prompt(session, "again")
    events = collect_until(:turn_end)
    assert stop_reason(events) == :end_turn
    assert notices(events) == []
  end

  defp notices(events), do: for(%Event{type: :notice, data: data} <- events, do: data)
end
