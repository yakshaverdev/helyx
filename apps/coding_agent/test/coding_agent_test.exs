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
             CodingAgent.run(model: "not-a-ref", cwd: dir, sessions_dir: dir, prompt: "p")

    assert Process.whereis(Helyx.Core) == nil
  end

  @tag :tmp_dir
  test "start_session persists to disk, and a resume by id restores the saved model",
       %{tmp_dir: dir} do
    core = :"agent_core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: CodingAgent.plugins()})

    {:ok, session} =
      CodingAgent.start_session(core: core, cwd: dir, sessions_dir: dir, model: "fake/echo")

    assert [_file] = Path.wildcard(Path.join(dir, "*/*.jsonl"))

    Helyx.Test.SessionFile.stop(session)

    # The session has no message, so the newest-session resume leaves it out.
    assert {:error, :not_found} =
             CodingAgent.start_session(core: core, cwd: dir, sessions_dir: dir, resume: true)

    {:ok, resumed} =
      CodingAgent.start_session(core: core, cwd: dir, sessions_dir: dir, resume: session.id)

    assert snapshot(resumed).model == "fake/echo"
  end

  # No other async test changes the log handlers of the VM.
  @tag :tmp_dir
  test "log_to_file sends the log to the file while it runs, then puts the handler back",
       %{tmp_dir: dir} do
    {:ok, before} = :logger.get_handler_config(:default)
    path = Path.join(dir, "tui.log")

    assert CodingAgent.log_to_file(path, fn ->
             {:ok, during} = :logger.get_handler_config(:default)
             assert during.config.file == String.to_charlist(path)
             require Logger
             Logger.error("log_to_file marker")
             :result
           end) == :result

    assert :logger.get_handler_config(:default) == {:ok, before}
    assert File.read!(path) =~ "log_to_file marker"

    # A raise puts the handler back too.
    assert_raise RuntimeError, fn -> CodingAgent.log_to_file(path, fn -> raise "x" end) end
    assert :logger.get_handler_config(:default) == {:ok, before}
  end

  # The sentence of a start error, after the prefix of every start error.
  defp sentence(reason) do
    assert "could not start the agent: " <> text = CodingAgent.error_text(reason)
    text
  end

  test "error_text turns the remaining shapes into text" do
    assert sentence(:not_regular) =~ "not a regular file"
    assert sentence(:invalid_id) == "not a session id"
    assert sentence(:duplicate_id) == "more than one session file has this id"
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

    assert sentence({:lock_failed, "perl gave no answer\nin 5000 ms"}) ==
             "could not lock the session: perl gave no answer in 5000 ms"

    assert sentence(:open_timeout) == "the session file did not open in time"

    # The whole line, with no start prefix (#579).
    assert CodingAgent.error_text({:session_locked, "abc\e[2J"}) ==
             "session abc?[2J is open in another process"

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

  defmodule LongCheck do
    @moduledoc false
    # A tool whose check gives the reason that the test puts in the process.
    def check, do: {:error, Process.get(:check_reason)}
  end

  # The two prefixes take 59 bytes, so the 3-byte character that starts at
  # byte 3999 is cut in half and dropped.
  test "error_text of a long tool check reason has at most 4000 bytes" do
    Process.put(
      :check_reason,
      String.duplicate("a", 3940) <> "€" <> String.duplicate("b", 200_000)
    )

    assert {:error, reason} = Helyx.Tool.check_available([{LongCheck, %{name: "bash"}}])
    text = CodingAgent.error_text(reason)

    assert "could not start the agent: the bash tool is not available: " <> rest = text
    assert byte_size(rest) == 3940
    assert rest =~ ~r/^a+$/
    assert String.valid?(text)
  end

  test "error_text of a long value from the session file has at most 4000 bytes" do
    # `inspect/1` keeps 4096 characters of the string, more than the cap.
    text = CodingAgent.error_text({:unknown_version, String.duplicate("9", 10_000)})
    assert text =~ ~s(could not start the agent: the session file has version "999)
    assert byte_size(text) == 4000
  end

  test "error_text tells a session that ended apart from a failed start" do
    assert CodingAgent.error_text({:session_down, :crashed}) == "the session crashed and stopped"
    assert CodingAgent.error_text({:session_down, :stopped}) == "the session stopped"

    assert CodingAgent.error_text({:session_down, :slow}) ==
             "the client fell behind the session events"

    assert CodingAgent.error_text(:eacces) == "could not start the agent: permission denied"

    assert CodingAgent.error_text({:session_down, :session_not_found}) ==
             "the session stopped"
  end

  test "error_text of the attach and of a TUI over the wire" do
    # A line of the attach is whole, and gets the clean pass: its folder
    # comes from the configuration.
    assert CodingAgent.error_text({:attach, "the data folder /x\e[2J is not a directory"}) ==
             "the data folder /x?[2J is not a directory"

    assert CodingAgent.error_text({:connection_down, {:shutdown, :broken}}) ==
             "the server broke the wire contract"

    assert CodingAgent.error_text({:connection_down, :closed}) ==
             "could not subscribe to the session: no connection to the server"

    assert sentence(:too_many_sessions) == "the server runs as many sessions as it can"
    assert sentence({:start_failed, "no\nroom"}) == "no room"
    assert sentence(:timeout) == "no answer from the server"
    assert sentence(:busy) == "too many requests wait"
    assert sentence(:closed) == "no connection to the server"
    assert sentence(:failed) == "the server failed"
  end
end
