defmodule CodingAgentTest do
  # The TUI needs a terminal, so the test drives the same wiring headless:
  # Core with the product's plugin list, a session, a turn with a tool call.
  use ExUnit.Case, async: true

  import Helyx.Test.Events

  alias Helyx.{Message, Session}

  test "the plugin list boots Core and a session runs a tool-call turn" do
    core = :"agent_core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: CodingAgent.plugins()})

    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "echo hi"}}
    :ok = Helyx.Provider.Fake.script(core, "task", [["Running.", call], ["Done."]])

    {:ok, session} = Session.start(core, model: "fake/task")
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "run it")

    events = collect_until(:turn_end)
    types = Enum.map(events, & &1.type)
    assert :tool_execution_end in types

    result =
      Enum.find_value(events, fn
        %{type: :tool_execution_end, data: %{message: message}} -> message
        _ -> nil
      end)

    assert Message.text(result) =~ "hi"
    assert Message.text(List.last(messages(events))) == "Done."
  end

  # run/1 starts Core under its default name; no other async test uses it.
  @tag :tmp_dir
  test "run/1 rejects a bad model ref and stops the Core it started", %{tmp_dir: dir} do
    assert {:error, {:invalid_model_ref, "not-a-ref"}} =
             CodingAgent.run(model: "not-a-ref", cwd: dir, sessions_dir: dir)

    assert Process.whereis(Helyx.Core) == nil
  end

  @tag :tmp_dir
  test "start_session persists to disk and resume restores the saved model", %{tmp_dir: dir} do
    core = :"agent_core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: CodingAgent.plugins()})

    {:ok, session} =
      CodingAgent.start_session(core: core, cwd: dir, sessions_dir: dir, model: "fake/echo")

    assert [_file] = Path.wildcard(Path.join(dir, "*/*.jsonl"))

    :ok = GenServer.stop(Session.pid(session))

    {:ok, resumed} =
      CodingAgent.start_session(core: core, cwd: dir, sessions_dir: dir, resume: true)

    assert GenServer.call(Session.pid(resumed), :snapshot).model == "fake/echo"
  end

  @tag :tmp_dir
  test "resume without a saved session reports not_found", %{tmp_dir: dir} do
    core = :"agent_core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: CodingAgent.plugins()})

    assert {:error, :not_found} =
             CodingAgent.start_session(core: core, cwd: dir, sessions_dir: dir, resume: true)
  end

  # The sentence of a start error, after the prefix of every start error.
  defp sentence(reason) do
    assert "could not start the agent: " <> text = CodingAgent.error_text(reason)
    text
  end

  test "error_text turns the remaining shapes into text" do
    assert sentence(:not_regular) =~ "not a regular file"
    assert sentence(:eacces) == "permission denied"
    assert sentence(:queue_full) == ":queue_full"
    assert sentence({:repair_failed, "x"}) == "could not repair the session file: x"

    assert sentence({:create_failed, :enospc}) =~
             "create the session file: no space"

    assert sentence({:tool_unavailable, "bash", "perl not found"}) ==
             "the bash tool is not available: perl not found"

    assert sentence({:too_large, "a\nb\e[2J"}) == "a b?[2J"
    assert sentence({:invalid_file, <<"a", 0xFF, 0, "b">>}) =~ "damaged: a??b"
    refute sentence({:repair_failed, %{__struct__: MapSet, map: 1}}) =~ "\n"
    assert sentence(:invalid_cwd) =~ "the directory is not UTF-8"
    assert sentence({:create_failed, :eacces}) =~ "session file: permission denied"
    assert sentence({:terminal_init_failed, "no tty"}) =~ "did not start: no tty"

    assert sentence({:some, "other"}) == ~s({:some, "other"})

    # A Core start error names the plugins, and inspect/1 caps a long id (#169).
    assert sentence({:invalid_provider_id, Acme.Provider.X}) ==
             "{:invalid_provider_id, Acme.Provider.X}"

    # The worst case is a format character that inspect/1 escapes in 6
    # bytes; the text of `Helyx.Reason` has at most 4000 bytes, and the
    # clean pass turns no character into more bytes.
    for char <- ["\u{1D11E}", "\u{202E}"] do
      text =
        sentence({:duplicate_provider_id, String.duplicate(char, 10_000), [A, B]})

      assert text =~ "{:duplicate_provider_id"
      assert byte_size(text) <= 4000
      refute text =~ ~r/[\x00-\x1F\x7F]/
    end
  end

  test "error_text of a start error with a stacktrace holds no stack frame" do
    stack = [{Acme.Plugin, :init, 1, [file: ~c"lib/acme/plugin.ex", line: 7]}]

    reason =
      {:shutdown, {:failed_to_start_child, Acme.Plugin, {%RuntimeError{message: "boom"}, stack}}}

    text = sentence(reason)
    assert text =~ ~s({%RuntimeError{message: "boom"}, :stacktrace})
    refute text =~ "plugin.ex"
    refute text =~ "Acme.Plugin, :init"
  end

  test "error_text tells a session that ended apart from a failed start" do
    assert CodingAgent.error_text({:session_down, :crashed}) == "the session crashed and stopped"
    assert CodingAgent.error_text({:session_down, :stopped}) == "the session stopped"
    assert CodingAgent.error_text(:eacces) == "could not start the agent: permission denied"

    assert CodingAgent.error_text({:session_down, :session_not_found}) ==
             "the session stopped"
  end
end
