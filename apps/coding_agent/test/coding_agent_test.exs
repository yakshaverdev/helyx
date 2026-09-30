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
    {:ok, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "run it")

    events = collect_until(:agent_end)
    types = Enum.map(events, & &1.type)
    assert :tool_execution_start in types
    assert :tool_execution_end in types

    result =
      Enum.find_value(events, fn
        %{type: :tool_execution_end, data: %{message: message}} -> message
        _ -> nil
      end)

    assert Message.text(result) =~ "hi"
    assert Message.text(Enum.find(events, &(&1.type == :turn_end)).data.message) == "Done."
  end

  test "a bad model ref is rejected before anything starts" do
    core = :"agent_core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: CodingAgent.plugins()})

    assert {:error, _reason} = Session.start(core, model: "not-a-ref")
  end

  test "mix helyx rejects bad arguments before starting anything" do
    assert_raise Mix.Error, ~r/--bogus/, fn -> Mix.Tasks.Helyx.run(["--bogus"]) end
    assert_raise Mix.Error, ~r/at most one directory/, fn -> Mix.Tasks.Helyx.run(["a", "b"]) end

    assert_raise Mix.Error, ~r/not a directory/, fn ->
      Mix.Tasks.Helyx.run(["/nonexistent/helyx-test-dir"])
    end

    bad = "/nonexistent/a\e[31mb\nc"

    # Each message shows the bad argument as inspect/1 prints it.
    for {argv, text, shown} <- [
          {[bad], "not a directory", inspect(bad)},
          {["/x", bad], "at most one directory", inspect(["/x", bad])},
          {["--x\e[31m\n"], "unknown option", inspect("--x\e[31m\n")},
          {["--resume=\e[31m\n"], "bad value", ~S("--resume"="\e[31m\n")},
          {["-a\xFF\e[31m\n"], "not UTF-8", ~S("-a\xFF\e[31m\n")},
          {["/x\xFF"], "not UTF-8", ~S("/x\xFF")},
          {["-="], "bad option", ~S(["-="])},
          {["-=value"], "bad option", ~S(["-=value"])},
          {["-=\e[31m\n"], "bad option", ~S(["-=\e[31m\n"])}
        ] do
      error = assert_raise Mix.Error, fn -> Mix.Tasks.Helyx.run(argv) end
      assert error.message =~ text
      assert error.message =~ shown
      assert String.valid?(error.message)
      refute error.message =~ ~r/[\x00-\x1F\x7F]/
    end

    assert_raise Mix.Error, ~r/"--model"; the options/, fn -> Mix.Tasks.Helyx.run(["--model"]) end

    assert_raise Mix.Error, ~r/does not combine/, fn ->
      Mix.Tasks.Helyx.run(["--resume", "--model", "fake/echo"])
    end
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

    assert GenServer.call(Session.pid(resumed), {:snapshot}).model == "fake/echo"
  end

  @tag :tmp_dir
  test "resume without a saved session reports not_found", %{tmp_dir: dir} do
    core = :"agent_core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: CodingAgent.plugins()})

    assert {:error, :not_found} =
             CodingAgent.start_session(core: core, cwd: dir, sessions_dir: dir, resume: true)
  end

  test "error_text turns the remaining shapes into text" do
    assert CodingAgent.error_text(:not_regular) =~ "not a regular file"
    assert CodingAgent.error_text(:eacces) == "permission denied"
    assert CodingAgent.error_text(:queue_full) == ":queue_full"
    assert CodingAgent.error_text({:repair_failed, "x"}) =~ ~s(session file: "x")

    assert CodingAgent.error_text({:create_failed, :enospc}) =~
             "create the session file: no space"

    assert CodingAgent.error_text({:tool_unavailable, "bash", "perl not found"}) ==
             "the bash tool is not available: perl not found"

    assert CodingAgent.error_text({:too_large, "a\nb\e[2J"}) == "a b?[2J"
    assert CodingAgent.error_text({:invalid_file, <<"a", 0xFF, 0, "b">>}) =~ "damaged: a??b"
    refute CodingAgent.error_text({:repair_failed, %{__struct__: MapSet, map: 1}}) =~ "\n"
    assert CodingAgent.error_text(:invalid_cwd) =~ "the directory is not UTF-8"
    assert CodingAgent.error_text({:create_failed, :eacces}) =~ "session file: permission denied"
    assert CodingAgent.error_text({:terminal_init_failed, "no tty"}) =~ "did not start: no tty"

    assert CodingAgent.error_text({:bad_provider_turn, "x"}) ==
             ~s(the provider "x" has a bad turn/0)

    assert CodingAgent.error_text({:some, "other"}) == ~s({:some, "other"})

    # A Core start error names the plugins, and inspect/1 caps a long id (#169).
    assert CodingAgent.error_text({:invalid_provider_id, Acme.Provider.X}) ==
             "{:invalid_provider_id, Acme.Provider.X}"

    # The worst case is a format character that inspect/1 escapes in 6 bytes.
    for char <- ["\u{1D11E}", "\u{202E}"] do
      text =
        CodingAgent.error_text({:duplicate_provider_id, String.duplicate(char, 10_000), [A, B]})

      assert text =~ "[A, B]"
      assert byte_size(text) <= 24_700
      refute text =~ ~r/[\x00-\x1F\x7F]/
    end
  end
end
