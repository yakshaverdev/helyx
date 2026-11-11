defmodule Helyx.Session.TurnRecordTest do
  # The system prompt entry of the session file (docs/features/turn-record.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase, only: [start_core: 1, final_text: 1]

  alias Helyx.Session

  @moduletag :tmp_dir

  @cap Helyx.Session.File.max_system_bytes()

  setup do
    %{core: start_core([Helyx.Test.Provider, Helyx.Test.PromptContext])}
  end

  defp start(core, dir) do
    {:ok, session} = Session.start(core, model: "test/system", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)
    session
  end

  defp turn(session, text) do
    :ok = Session.prompt(session, text)
    collect_until(:turn_end)
  end

  defp entries(dir, session) do
    [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  defp prompts(entries), do: for(%{"type" => "system_prompt"} = e <- entries, do: e)

  defp stop(session) do
    ref = Process.monitor(Session.pid(session))
    GenServer.stop(Session.pid(session))
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  test "an entry only when the prompt changes, before the reply of its call", %{
    core: core,
    tmp_dir: dir
  } do
    session = start(core, dir)

    for text <- ["one", "two", "prompt:edited", "prompt:edited", "nil", "nil", "three"],
        do: turn(session, text)

    entries = entries(dir, session)

    assert [
             %{"system" => "same", "bytes" => 4},
             %{"system" => "edited", "bytes" => 6},
             %{"system" => nil, "bytes" => 0},
             %{"system" => "same", "bytes" => 4}
           ] = prompts(entries)

    # The prompt of each reply is the last entry before it, and it is the
    # prompt that the model answered with.
    {_, pairs} =
      Enum.reduce(entries, {nil, []}, fn
        %{"type" => "system_prompt", "system" => s}, {_, acc} -> {s, acc}
        %{"type" => "message", "role" => "assistant"} = m, {s, acc} -> {s, [{s, m} | acc]}
        _, state -> state
      end)

    for {system, %{"content" => [%{"text" => text}]}} <- pairs,
        do: assert(text == (system || "no system"))

    assert length(pairs) == 7
    ids = Enum.map(entries, & &1["id"])
    assert Enum.map(entries, & &1["parent_id"]) == [nil | Enum.drop(ids, -1)]
  end

  for {n, stored} <- [{@cap - 1, @cap - 1}, {@cap, @cap}, {@cap + 1, @cap - 1}] do
    test "a prompt of #{n} bytes is stored as #{stored} bytes with its size", %{
      core: core,
      tmp_dir: dir
    } do
      session = start(core, dir)
      turn(session, "bytes:#{unquote(n)}")

      assert [%{"system" => system, "bytes" => unquote(n)}] = prompts(entries(dir, session))
      assert byte_size(system) == unquote(stored)
      assert String.valid?(system)
      assert String.starts_with?(String.duplicate("x", unquote(n) - 2) <> "é", system)
    end
  end

  test "a change past the cut writes a new entry", %{core: core, tmp_dir: dir} do
    session = start(core, dir)
    turn(session, "bytes:#{@cap + 10}")
    turn(session, "bytes:#{@cap + 20}")
    turn(session, "bytes:#{@cap + 20}")
    assert [%{"bytes" => b1}, %{"bytes" => b2}] = prompts(entries(dir, session))
    assert {b1, b2} == {@cap + 10, @cap + 20}
  end

  test "a resume skips any system prompt entry, and its first call writes one", %{
    core: core,
    tmp_dir: dir
  } do
    session = start(core, dir)
    turn(session, "one")
    stop(session)

    # Entries that the writer never makes: over the cap, and no text field.
    [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
    leaf = List.last(entries(dir, session))["id"]
    big = %{"type" => "system_prompt", "id" => "a", "parent_id" => leaf}
    big = Map.merge(big, %{"system" => String.duplicate("y", @cap + 1), "bytes" => 1})
    bare = %{"type" => "system_prompt", "id" => "b", "parent_id" => "a", "system" => 7}
    File.write!(path, [JSON.encode!(big), "\n", JSON.encode!(bare), "\n"], [:append])

    {:ok, resumed} = Session.resume(core, sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(resumed)
    assert final_text(turn(resumed, "two")) == "same"

    assert [%{"system" => "same"}, %{"id" => "a"}, %{"id" => "b"}, %{"system" => "same"}] =
             prompts(entries(dir, resumed))
  end

  test "a system prompt entry that breaks the chain fails the resume", %{
    core: core,
    tmp_dir: dir
  } do
    session = start(core, dir)
    turn(session, "one")
    stop(session)

    [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
    entry = %{"type" => "system_prompt", "id" => "a", "parent_id" => "other", "system" => "x"}
    File.write!(path, [JSON.encode!(entry), "\n"], [:append])

    assert {:error, {:invalid_file, text}} = Session.resume(core, sessions_dir: dir)
    assert text =~ "does not continue the chain"
  end

  test "a prompt that is not UTF-8 fails the turn and writes nothing", %{
    core: core,
    tmp_dir: dir
  } do
    session = start(core, dir)
    events = turn(session, "raw")
    assert List.last(events).data.outcome == :error
    assert List.last(events).data.error == inspect({:bad_context, :model_context})
    assert prompts(entries(dir, session)) == []
    assert final_text(turn(session, "one")) == "same"
  end

  test "a session without a file hashes nothing and runs", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/system")
    {:ok, _, _} = Session.subscribe(session)
    assert final_text(turn(session, "prompt:x")) == "x"
    assert :sys.get_state(Session.pid(session)).save == :never
  end

  test "a failed write of the entry turns persistence off and keeps no hash", %{
    core: core,
    tmp_dir: dir
  } do
    session = start(core, dir)

    # The user message is written; the build breaks the file before the
    # entry.
    events = turn(session, "break")
    assert final_text(events) == "same"
    assert [_notice] = for(%Helyx.Event{type: :notice} = e <- events, do: e)
    [old] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl.old"))
    lines = String.split(File.read!(old), "\n", trim: true)
    assert [_header, %{"role" => "user"}] = Enum.map(lines, &JSON.decode!/1)
    assert {:stopped, _, _} = :sys.get_state(Session.pid(session)).save
  end

  test "the answer to a context request writes the prompt that it sends", %{tmp_dir: dir} do
    core = start_core([Helyx.Test.Connected, Helyx.Test.PrepareContext])
    Process.register(self(), Helyx.Test.Connected.controller(core))
    {:ok, session} = Session.start(core, model: "conn/context", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "one")
    assert_receive {:conn, :turn, proc, {:turn, turn_id, _}}
    send(proc, {:need_context, turn_id, "fresh"})
    assert_receive {:conn, :context, ^proc, {:context, ^turn_id, {:ok, _}}}
    collect_until(:turn_end)

    assert [%{"system" => "prepared"}, %{"system" => system}] = prompts(entries(dir, session))
    assert system == "prepared for #{turn_id}"
  end
end
