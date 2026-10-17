defmodule Helyx.Provider.ClaudeCodeRealTest do
  # Runs the real `claude` with the model haiku, so it needs the program,
  # a login, and the network. `test_helper.exs` excludes the tag, so
  # `mix precommit` does not run it. Run it with
  # `mix test --include real_claude test/helyx/provider/claude_code_real_test.exs`.
  use ExUnit.Case, async: false

  import Helyx.Test.Events
  import Helyx.Test.OSHelpers

  alias Helyx.{Event, Message, Session}
  alias Helyx.Provider.ClaudeCode

  @moduletag :real_claude
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # A turn of the real program over the network.
  @real_turn_ms 120_000

  test "a command runs on the Helyx bash, and the hands release it on abort (#478)", %{
    tmp_dir: tmp
  } do
    core = :"core_#{System.unique_integer([:positive])}"

    plugins = [ClaudeCode, Helyx.Tool.Read, Helyx.Tool.Bash, Helyx.Tool.Edit, Helyx.Tool.Write]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})

    {:ok, session} =
      Session.start(core,
        model: "claude-code/haiku",
        cwd: tmp,
        sessions_dir: Path.join(tmp, "sessions")
      )

    {:ok, _, _} = Session.subscribe(session)

    :ok =
      Session.prompt(session, """
      Run this shell command exactly as written: echo $$ > fg.pid; exec sleep 90
      """)

    pid = wait_for_pid(Path.join(tmp, "fg.pid"))
    %{pid: harness} = :sys.get_state(Session.pid(session)).conn
    :ok = Session.abort(session)
    events = collect_until(:turn_end, @real_turn_ms)

    assert [%{outcome: :aborted}] = of_type(events, :turn_end)
    assert gone_within?(pid)
    assert %{pid: ^harness} = :sys.get_state(Session.pid(session)).conn

    names =
      for %Event{type: :message_end, data: %{message: %Message{content: blocks}}} <- events,
          %Message.ToolCall{name: name} <- blocks,
          do: name

    assert names == ["bash"]

    GenServer.stop(Session.pid(session))
  end
end
