defmodule Helyx.Provider.ClaudeCodeRealTest do
  # Runs the real `claude` with the model haiku, so it needs the program,
  # a login, and the network. `test_helper.exs` excludes the tag, so
  # `mix precommit` does not run it. Run it with
  # `mix test --include real_claude test/helyx/provider/claude_code_real_test.exs`.
  use ExUnit.Case, async: false

  import Helyx.Test.Events
  import Helyx.Test.OSHelpers

  alias Helyx.{Event, Session}
  alias Helyx.Provider.ClaudeCode

  @moduletag :real_claude
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # A turn of the real program over the network.
  @real_turn_ms 120_000

  # The `Bash` tool refuses a standalone `sleep`, so the commands are python
  # (research note, #200 section).
  defp sleeper(file, seconds),
    do:
      ~s|python3 -c "import os, time; open('#{file}', 'w').write(str(os.getpid())); time.sleep(#{seconds})"|

  test "a background task survives an abort and is gone after the session ends",
       %{tmp_dir: tmp} do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [ClaudeCode]})

    {:ok, session} =
      Session.start(core,
        model: "claude-code/haiku",
        cwd: tmp,
        sessions_dir: Path.join(tmp, "sessions")
      )

    {:ok, _} = Session.subscribe(session)

    :ok =
      Session.prompt(session, """
      Run these two commands with the Bash tool, one after the other, exactly as written.
      First, with run_in_background set to true: #{sleeper("bg.pid", 240)}
      Second, in the foreground, after the first one started: #{sleeper("fg.pid", 90)}
      """)

    bg = wait_for_pid(Path.join(tmp, "bg.pid"))
    fg = wait_for_pid(Path.join(tmp, "fg.pid"))
    %{pid: harness} = :sys.get_state(Session.pid(session)).conn

    :ok = Session.abort(session)

    assert [%{stop_reason: :aborted}] =
             for(
               %Event{type: :agent_end, data: d} <- collect_until(:agent_end, @real_turn_ms),
               do: d
             )

    # The interrupt ends the foreground command; the background task and
    # the program stay.
    assert gone_within?(fg)
    assert os_alive?(bg)
    assert %{pid: ^harness} = :sys.get_state(Session.pid(session)).conn

    GenServer.stop(Session.pid(session))

    assert gone_within?(bg)
  end
end
