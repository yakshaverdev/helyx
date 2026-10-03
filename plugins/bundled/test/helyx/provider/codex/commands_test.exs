defmodule Helyx.Provider.Codex.CommandsTest do
  # Aborts during a turn, and the commands that a turn runs.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.Events
  import Helyx.Test.OSHelpers

  alias Helyx.{HarnessIO, Message, Session}

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  test "an abort during model output interrupts the turn, and the program serves the next one",
       %{bin: bin} = ctx do
    fresh(bin, 1, tid(), [delta(tid(), "msg_1", "thinking")])
    on(bin, 1, "turn/interrupt", [j(%{id: "@", result: %{}}), turn_end(tid(), "interrupted")])
    on(bin, 1, "turn/start", as_turn(turn(tid(), reply(tid(), "Next.")), "turn2"), "", 2)

    session = start(ctx)
    :ok = Session.prompt(session, "wait")
    collect_until(:message_update)
    :ok = Session.abort(session)

    assert [%{stop_reason: :aborted}] = of_type(collect_until(:agent_end), :agent_end)

    assert %{"params" => %{"threadId" => tid(), "turnId" => "turn1"}} =
             request(bin, 1, "turn/interrupt")

    events = prompt(session, "next")
    assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)
    assert runs(bin) == "1"
  end

  test "an abort during a command stops the program, and the next turn starts a new one",
       %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    running = [started(tid(), command("exec-1", %{status: "inProgress"}))]
    fresh(bin, 1, tid(), running, ~s{sleep 30 &\necho $! > "#{pidfile}"\n})
    on(bin, 1, "turn/interrupt", [j(%{id: "@", result: %{}}), turn_end(tid(), "interrupted")])

    session = start(ctx)
    :ok = Session.prompt(session, "wait")
    collect_until(:message_update)
    pid = wait_for_pid(pidfile)

    # The abort returns only when the program's group is gone.
    :ok = Session.abort(session)
    refute os_alive?(pid)
    assert request(bin, 1, "turn/interrupt") == nil

    assert [%{stop_reason: :aborted}] = of_type(collect_until(:agent_end), :agent_end)

    # The turn made no message, so its thread is not resumed: the next
    # program starts a thread of its own, with both prompts.
    fresh(bin, 2, fresh_tid(), reply(fresh_tid(), "Back."))
    events = prompt(session, "back")
    assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)
    assert runs(bin) == "2"
    assert request(bin, 2, "thread/resume") == nil

    assert %{
             "params" => %{
               "threadId" => fresh_tid(),
               "input" => [%{"text" => "wait"}, %{"text" => "back"}]
             }
           } =
             request(bin, 2, "turn/start")
  end

  # Like codex: a command in a process group of its own, which the program
  # ends 3 s after the first TERM (the watchdog and the release each send
  # one); a KILL of the program's group would leave it running.
  defp own_group_command(pidfile, after_pid) do
    """
    perl -e 'setpgrp(0, 0); exec "sleep", "30"' </dev/null >/dev/null 2>&1 &
    c=$!
    trap 'trap "" TERM; sleep 3; kill -9 $c; exit 0' TERM
    echo $c > "#{pidfile}"
    #{after_pid}
    while :; do sleep 0.1; done
    """
  end

  @tag :slow
  test "an abort gives the program time to end its commands", %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    running = [started(tid(), command("exec-1", %{status: "inProgress"}))]
    fresh(bin, 1, tid(), running, own_group_command(pidfile, ""))

    session = start(ctx)
    :ok = Session.prompt(session, "wait")
    collect_until(:message_update)
    pid = wait_for_pid(pidfile)

    :ok = Session.abort(session)
    refute os_alive?(pid)
    assert [%{stop_reason: :aborted}] = of_type(collect_until(:agent_end), :agent_end)
  end

  @tag :slow
  test "a line over the cap while a command runs gives the program the same time",
       %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    over_cap = ~s{perl -e 'print "x" x #{HarnessIO.line_max_bytes() + 1}, "\\n"'}
    running = [started(tid(), command("exec-1", %{status: "inProgress"}))]
    fresh(bin, 1, tid(), running, own_group_command(pidfile, over_cap))

    session = start(ctx)
    :ok = Session.prompt(session, "wait")

    # The release returns before the session gets the end of the harness.
    assert [%{stop_reason: :error, error: {:provider_stop, {:line_over_limit, 16_777_216}}}] =
             of_type(collect_until(:agent_end), :agent_end)

    refute os_alive?(wait_for_pid(pidfile))
  end

  @tag :slow
  test "a failed turn with an open command stops the provider process, and the next turn starts a new program",
       %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    failed = Path.join(bin, "failed")
    File.write!(failed, turn_end(tid(), "failed", "usage limit") <> "\n")
    running = [started(tid(), command("exec-1", %{status: "inProgress"}))]
    fresh(bin, 1, tid(), running, own_group_command(pidfile, ~s(cat "#{failed}")))
    # The stop drops the turn's events: no message, so no thread to resume.
    fresh(bin, 2, fresh_tid(), reply(fresh_tid(), "Back."))

    session = start(ctx)

    assert [%{stop_reason: :error, error: {:provider_stop, :command_running}}] =
             of_type(prompt(session, "go"), :agent_end)

    # The release ended the command before the next turn.
    refute os_alive?(wait_for_pid(pidfile))

    events = prompt(session, "again")
    assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)
    assert runs(bin) == "2"
  end

  # A completion with a status that does not end the item.
  @not_ended %{status: "inProgress", exitCode: nil}

  test "an inProgress completion of a command stops the provider process before the turn's end",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), [
      started(tid(), command("exec-1", %{status: "inProgress"})),
      completed(tid(), command("exec-1", @not_ended)),
      turn_end(tid(), "completed")
    ])

    # The stop drops the events of its chunk. The port cuts stdout where a
    # pipe read ends (on macOS at 512 bytes, #340), so the tool call goes
    # out only when the start and the completion are in two chunks.
    assert [{:resume, tid(), 0} | rest] = run_direct([Message.user("go")], work)

    stop = {:stop, {:malformed, "item/completed"}}
    assert [stop] == rest or match?([{:tool_call, %{id: "exec-1"}}, ^stop], rest)
  end

  test "a command start with no turn id or no string id stops the provider process",
       %{bin: bin, work: work} do
    starts = [
      note(tid(), "item/started", %{item: command("exec-1", %{status: "inProgress"})}),
      started(tid(), command(7, %{status: "inProgress"}))
    ]

    # One program run per start.
    for {start, n} <- Enum.with_index(starts, 1) do
      fresh(bin, n, tid(), [start, turn_end(tid(), "completed")])

      assert run_direct([Message.user("go")], work) ==
               [{:resume, tid(), 0}, {:stop, {:malformed, "item/started"}}]
    end
  end

  @tag :slow
  test "an inProgress completion of a command ends the turn, so an abort sends no turn/interrupt",
       %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    line = Path.join(bin, "line")
    File.write!(line, completed(tid(), command("exec-1", @not_ended)) <> "\n")
    running = [started(tid(), command("exec-1", %{status: "inProgress"}))]
    fresh(bin, 1, tid(), running, own_group_command(pidfile, ~s(cat "#{line}")))

    session = start(ctx)

    assert [%{stop_reason: :error, error: {:provider_stop, {:malformed, "item/completed"}}}] =
             of_type(prompt(session, "go"), :agent_end)

    refute os_alive?(wait_for_pid(pidfile))
    :ok = Session.abort(session)
    assert request(bin, 1, "turn/interrupt") == nil
  end
end
