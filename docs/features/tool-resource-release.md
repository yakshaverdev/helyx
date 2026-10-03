# Tool resource release

## Goal

Preserve the existing cleanup and refusal contract of the hands while moving OS operations into the bash plugin.

Today `Helyx.Hands` (now `Helyx.Session.Hands`), in Core, holds the process groups of the bash tool and does the OS work to release them: the group kinds `:command` and `:watchdog`, the TERM and KILL sequence, the poll until a group is gone, and the rule that the watchdog is swept last. Only the bash tool uses any of it, and Core must stay small (AGENTS.md). After this change the hands hold opaque handles and call the plugin that holds them. Core no longer knows about process groups, signals, or perl.

This is a move, not a redesign. The watchdog protocol, the handshake, and the meaning of the watchdog's exit status do not change (ADR 0004). Protocol changes are out of scope (see the last section).

The design was reviewed in three rounds on 2026-09-25. The findings are in `docs/reviews/2026-09-25-tool-resource-release.md`. Ticket #100.

## The contract that stays

- Registration happens at the same two stages as today: the watchdog at `Port.open`, the command group after the marker and before the go-ahead.
- A handle from a Task that the hands no longer run is dropped. The closed port makes the watchdog clean up.
- The release runs on every Task end, a reply or a `:DOWN` for any reason. It never depends on code in the dead Task.
- A result is delivered only after its release is done or recorded as unconfirmed.
- If any handle of a call stays unconfirmed, the result becomes an error, even when the tool succeeded. Today `killed_error/1` in `deliver` does this.
- An abort returns only after every call of the turn is released or recorded as unconfirmed. The session answers client calls during the wait (#93).
- While any unconfirmed handle is still held, later tool calls are refused with an error result. Chat, abort, and quit are not blocked.

## Interface changes

`Helyx.Tool`:

```elixir
@spec hold(term()) :: :ok
# Replaces register_group/2. Called from the tool Task. The handle is opaque to Core.

@callback release(handles :: [term()], mode :: :deliver | :cancel | :retry,
                  deadline :: integer()) :: [term()]
@optional_callbacks check: 0, release: 3
```

- `release/3` returns the handles that are still held. An empty list means that every handle is released.
- `mode`: `:deliver` when the call ended, `:cancel` when the turn was aborted, `:retry` before a later call, for handles that are unconfirmed.
- `deadline` is absolute: `System.monotonic_time(:millisecond)` on the node of the hands.
- `release/3` must be safe to call again with the same handles.
- `register_group/2` is removed.

`Helyx.Session.Hands` rules:

1. The hands record each handle with the tool module and the Task that held it. The module comes from the call that the hands started, not from the handle.
2. A handle is released only by the return value of `release/3`. After a Task ends, the hands call `release/3` for all its handles and keep only the returned ones.
3. The callback runs in a Task under Core's task supervisor. A timeout, a raise, an exit, or a return value that is not a proper list of only the given handles makes all the given handles unconfirmed. A failed probe never counts as released.
4. On timeout, the hands stop the release Task with `Task.yield_many/2` and `on_timeout: :kill_task`, which calls `Task.shutdown(task, :brutal_kill)` and returns only when the Task is gone. A reply that arrives before the kill counts, because the release did return. Each request has its own reference, and a reply that does not match the current request is ignored. Two release attempts never run at the same time.
5. An abort starts one release Task per tool module, in parallel, all with the same deadline. The wait does not grow with the number of Tasks, handles, or modules.
6. Before each call, the hands call `release(unconfirmed, :retry, deadline)` for each module that has unconfirmed handles, with one deadline for all modules. While any handle is still held, the call is refused.
7. A call to `hold/1` from a tool whose module does not export `release/3` raises in the tool Task, so the call ends with an error result before any external work starts.

`Helyx.Tool.Bash`:

- Implements `release/3`, because the hands find the callback through the tool module of the call. It delegates to `Helyx.Tool.Bash.Group` (`@moduledoc false`), which #10 moved to `Helyx.Watchdog.Group`.
- Handles are `{:watchdog, os_pid}` and `{:command, group}`. A group below 2 is never signalled: `kill -- -1` would reach every process of the user. No caller makes another handle; `Group.release/4` drops one unsignalled (#367; before it, an unknown handle was returned as still held).
- `Helyx.Tool.Bash.Group` (now `Helyx.Watchdog.Group`, #10) receives the code that leaves `lib/helyx/session/hands.ex`: `signal`, `await_gone`, `poll_gone`, `kill_and_wait`, `sweep_watchdogs`, `split_kinds`, and the `kill_cmd` test hook, which becomes the `kill` argument of `Group.release/4`.
- The order does not change: command groups first, the watchdog last, so the watchdog can reap its child before a KILL. A zombie child stays in its group until it is reaped, so this order also prevents an endless poll.
- The mode selects today's sequences. `:deliver` is KILL, wait, then the watchdog sweep. `:cancel` is TERM, 500 ms grace, KILL, wait, then the watchdog sweep. `:retry` is KILL and one probe, with no wait.
- The plugin computes its waits from the deadline. It never waits past it, and it starts no `kill` run at or after it: a probe that it skips counts the group as alive. A group is gone only when `kill` reports "No such process"; any other failure keeps the handle held. The watchdog KILL comes after one wait of 5,000 ms, so it needs that much time before the deadline. The 20,000 ms deadline leaves it.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| release deadline, `:deliver` and `:cancel` | 20,000 ms, absolute monotonic time on the hands node. The worst bash release is 15,500 ms (500 ms grace and three waits of 5,000 ms, `docs/features/coding-agent.md`, row "wait for an abort") | the hands stop the release Task; every given handle is unconfirmed; the result is an error; later calls are refused while a handle is held |
| release deadline, `:retry` | 1,000 ms, one deadline for all modules | every given handle stays unconfirmed; the call is refused |
| TERM grace, KILL wait (bash internal) | 500 ms and 5,000 ms, unchanged | a group still alive after the KILL wait is returned as still held |
| poll interval (bash internal) | 20 ms, unchanged | – |
| handles per Task | 2 per program run, held by `Helyx.Watchdog` for the bash tool and both harness providers: the watchdog and the command group. The bash tool and Codex start one run per Task. Claude Code starts a second run in the same Task after a lost session, so its Task holds at most 4. Plugin code is trusted, so there is no cap; accepted (#101) | – |
| unconfirmed handles | bounded by the refusal rule: once one is held, no new call runs, so no new handle is created. At most the handles of the calls of one turn | – |
| wait in `hold/1` | a `GenServer.call` with `:infinity`, as `register_group/2` was. The handler only updates a map. It can wait behind one release, which the first row bounds | the command is held until the call returns, so nothing runs unheld. An abort kills the tool Task, which ends the wait |

Tests at the limits: a release that returns 50 ms before the deadline, one that returns 50 ms after it, a retry that passes its deadline of 1,000 ms, a return value with a handle that was not given, an improper list, a raise, and an exit.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| command process group | the watchdog's fork; `{:command, group}` is held with the hands before the command may run | hands (opaque handle) and watchdog (the life) | at delivery the hands call `Bash.release(handles, :deliver, deadline)`: KILL and wait until gone | the closed port ends the watchdog's stdin: TERM, 500 ms grace, KILL, reap. If the tool Task crashed, the hands still release at delivery of the crash result | the hands call `Bash.release(handles, :cancel, deadline)`: TERM, grace, KILL, wait |
| watchdog process (its own group) | `Port.open` in `Helyx.Watchdog.start/3` (#10); `{:watchdog, os_pid}` is held with the hands | the port | exits after it reaps the command; `release/3` waits for it after every command group is gone or still held | the closed port is its signal | `release/3` waits for it last, so an abort cannot return while the command is unreaped |
| a process that leaves the command group (`setsid`, `set -m`, `setpgrp`) | the command | nobody | not released: the command group is gone, so the release confirms the handles | not released | not released. A documented limit, as before this change (`docs/features/coding-agent.md`, below the ownership table) |
| release Task | the hands, for each release call | the hands (linked) | returns the handles still held | a raise or an exit counts as unconfirmed; if the hands die, the link kills it | stopped with `Task.shutdown(:brutal_kill)` at the deadline; the hands wait until it is gone |

## Tests

- `test/helyx/session/hands_test.exs`: a test tool whose `release/3` delays past the deadline, raises, exits, returns a handle that was not given, returns an improper list, or keeps a handle. No fake `kill(1)` in Core tests.
- `plugins/bundled/test/helyx/tool/bash/group_test.exs` (now `test/helyx/watchdog/group_test.exs`, #10): the kill order, the stuck group, and the watchdog sweep, with the `kill` argument of `Group.release/4` in place of the `kill_cmd` hook of the hands.
- `test/helyx/session/sweep_test.exs` and `test/helyx/session/loop_test.exs`: the behaviour tests of #93 stay (responsive client calls during an abort, repeated aborts, owner death). They use the delaying test tool instead of `:sys.replace_state` on the hands.
- `test/support/interfaces.ex`: the `Register` test tool becomes the `Hold` test tool, with `HoldTwo` for the parallel release and `HoldBare` for a tool without `release/3`.
- `release_ms`, a start option of the hands, is the test seam for the deadline of `:deliver` and `:cancel`.

## Docs that change with the code

- `docs/adr/0004-os-resource-ownership.md` and `docs/adr/0003-hands-process.md`: amended with this change.
- `docs/features/coding-agent.md`: the Abort section and the rows "wait for a killed process group", "wait for an abort", "session to hands calls", "wait to register a process group", "command process group", and "watchdog process" name the hands as the party that signals. They change to the bash plugin, called by the hands through `release/3`.

## Out of scope

- A cancel line on the watchdog's stdin, and confirmation through `exit_status`.
- A kill of the rest of the group by the watchdog when the command exits.
- Removal of the marker and go-ahead handshake.
- Replacing perl with MuonTrap, erlexec, or ExCmd.
- The other candidates of the architecture review of 2026-09-25: abort through the mailbox of the hands, the tool text helpers out of Core, one module for the provider stream, and a snapshot on subscribe.
