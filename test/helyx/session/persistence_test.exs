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
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    collect_until(:agent_end)

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

  @tag :tmp_dir
  test "resume restores the transcript and the next provider call sees it", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/transcript", sessions_dir: dir)
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:agent_end)) == "user:hello"

    stop_session(session, &GenServer.stop/1)

    {:ok, resumed} = Session.resume(core, sessions_dir: dir)
    assert resumed.id == session.id
    {:ok, _} = Session.subscribe(resumed)

    :ok = Session.prompt(resumed, "again")

    assert final_text(collect_until(:agent_end)) ==
             "user:hello\nassistant:user:hello\nuser:again"
  end

  describe "the session supervisor after a resume (#103)" do
    # The start message of a resume holds the whole transcript. The supervisor
    # hibernates after each message, which collects that copy. Short texts stay
    # on the heap; this transcript is about 7 MB there, and the margin is 1 MB.
    @describetag :tmp_dir

    setup %{core: core, tmp_dir: dir} do
      {:ok, file} = Helyx.Session.File.create(dir, "big", File.cwd!(), "test/transcript")

      Enum.reduce(1..20_000, file, fn i, file ->
        Helyx.Session.File.append_message(file, Helyx.Message.user("m#{i}"))
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

      assert {:error, {:already_started, _}} = Session.resume(core, sessions_dir: dir)
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

  @tag :tmp_dir
  test "a resume writes nothing, and each open call gets its aborted result right after it, once",
       %{core: core, tmp_dir: dir} do
    call = %Helyx.Message.ToolCall{id: "c1", name: "slow", arguments: %{}}
    {:ok, file} = Helyx.Session.File.create(dir, "reuse", File.cwd!(), "test/transcript")

    [
      %Helyx.Message{role: :assistant, stop_reason: :tool_use, content: [call]},
      Helyx.Message.tool_result(call, {:ok, "first answer"}),
      %Helyx.Message{role: :assistant, stop_reason: :tool_use, content: [call]}
    ]
    |> Enum.reduce(file, &Helyx.Session.File.append_message(&2, &1))

    answered = [
      {:assistant, ""},
      {:tool_result, "first answer"},
      {:assistant, ""},
      {:tool_result, "aborted"}
    ]

    written = File.read!(file.path)
    {:ok, session} = Session.resume(core, sessions_dir: dir)
    assert File.read!(file.path) == written

    # The provider request has the result of the reused id, right after it.
    {:ok, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "one")

    assert final_text(collect_until(:agent_end)) ==
             Enum.map_join(answered ++ [{:user, "one"}], "\n", fn {r, t} -> "#{r}:#{t}" end)

    stop_session(session, &GenServer.stop/1)

    # The turn appended after the open call; the next resume puts the
    # result right after the call again, not at the end, and only once.
    written = File.read!(file.path)
    {:ok, session} = Session.resume(core, sessions_dir: dir)
    assert File.read!(file.path) == written
    {:ok, snapshot} = Session.subscribe(session)
    roles_texts = Enum.map(snapshot.messages, &{&1.role, Helyx.Message.text(&1)})
    assert Enum.take(roles_texts, 4) == answered
    assert [{:user, "one"}, {:assistant, _reply}] = Enum.drop(roles_texts, 4)
  end

  @tag :tmp_dir
  test "a resume counts the inserted results in the messages before a program session", %{
    core: core,
    tmp_dir: dir
  } do
    call = %Helyx.Message.ToolCall{id: "c1", name: "slow", arguments: %{}}
    {:ok, file} = Helyx.Session.File.create(dir, "counts", File.cwd!(), "test/transcript")

    file
    |> Helyx.Session.File.append_message(%Helyx.Message{role: :assistant, content: [call]})
    |> Helyx.Session.File.append_message(Helyx.Message.user("next"))
    |> Helyx.Session.File.append_resume_id("claude-code", "h1")

    {:ok, session} = Session.resume(core, sessions_dir: dir)
    state = :sys.get_state(Session.pid(session))
    assert length(state.transcript) == 3
    assert state.resume_ids == %{"claude-code" => {"h1", 3}}
  end

  @tag :tmp_dir
  @tag :capture_log
  test "resume after a crash mid-turn answers every open tool call", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/abort", sessions_dir: dir)
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}

    stop_session(session, &Process.exit(&1, :kill))

    {:ok, resumed} = Session.resume(core, sessions_dir: dir)
    {:ok, _} = Session.subscribe(resumed)

    :ok = Session.prompt(resumed, "again")
    assert final_text(collect_until(:agent_end)) == "aborted|aborted|aborted"
  end

  test "a prompt that is not valid UTF-8 is rejected and the session lives", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _} = Session.subscribe(session)

    assert {:error, :invalid_utf8} = Session.prompt(session, <<255, 254>>)

    :ok = Session.prompt(session, "hello")
    assert stop_reason(collect_until(:agent_end)) == :end_turn
  end

  @tag :tmp_dir
  @tag :capture_log
  test "a write failure turns persistence off and the session lives", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _} = Session.subscribe(session)

    File.rm_rf!(dir)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :end_turn
    assert [%{text: "the session file could not be written" <> _}] = notices(events)

    # The notice goes out once: persistence stays off.
    :ok = Session.prompt(session, "again")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :end_turn
    assert notices(events) == []
  end

  defp notices(events), do: for(%Event{type: :notice, data: data} <- events, do: data)
end
