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
- If any handle of a call stays unconfirmed, the result becomes an error, even when the tool succeeded. Today `Helyx.Session.Hands.Release.error/1` in `Helyx.Session.Hands.deliver/3` does this.
- An abort returns only after every call of the turn is released or recorded as unconfirmed. The session answers client calls during the wait (#93).
- Once a handle is unconfirmed, later tool calls are refused with an error result until the session stops (rule 6). Chat, abort, and quit are not blocked.
- No resource survives its Task. A background Task (`Helyx.Tool.started/1`) keeps its handles past its call, outside every turn, and releases them at its own end through the same delivery path; a cancel of the turn does not reach it, and the abort or the failure of its turn revokes it (`docs/features/background-bash.md`, ADR 0014).

## Interface changes

`Helyx.Tool`:

```elixir
@spec hold(term()) :: :ok
# Replaces register_group/2. Called from the tool Task. The handle is opaque to Core.

@callback release(handles :: [term()], mode :: :deliver | :cancel,
                  deadline :: integer()) :: [term()]
@optional_callbacks check: 0, release: 3
```

- `release/3` returns the handles that are still held. An empty list means that every handle is released.
- `mode`: `:deliver` when the call ended, `:cancel` when the turn was aborted.
- `deadline` is absolute: `System.monotonic_time(:millisecond)` on the node of the hands.
- `register_group/2` is removed.

`Helyx.Session.Hands` rules:

1. The hands record each handle with the tool module and the Task that held it. The module comes from the call that the hands started, not from the handle.
2. A handle is released only by the return value of `release/3`. After a Task ends, the hands call `release/3` for all its handles and keep only the returned ones.
3. The callback runs in a Task under Core's task supervisor. A timeout, a raise, an exit, or a return value that is not a proper list of only the given handles makes all the given handles unconfirmed. A failed probe never counts as released.
4. On timeout, the hands stop the release Task with `Task.yield_many/2` and `on_timeout: :kill_task`, which calls `Task.shutdown(task, :brutal_kill)` and returns only when the Task is gone. A reply that arrives before the kill counts, because the release did return. Each request has its own reference, and a reply that does not match the current request is ignored. Two release attempts never run at the same time.
5. An abort starts one release Task per tool module, in parallel, all with the same deadline. The wait does not grow with the number of Tasks, handles, or modules.
6. A handle that a release leaves unconfirmed gets no second release. From then on, the hands refuse every tool call and every provider start, until the session stops. Revision of 2026-10-16: the retry of unconfirmed handles is removed. Before it, the hands called `release(unconfirmed, :retry, deadline)` before each call, with one deadline of 1,000 ms for all modules, and calls ran again when the retry confirmed every handle. No run, issue, or research note showed a handle that a retry confirmed. Removed capability: recovery from an unconfirmed handle without a restart of the session.
7. A call to `hold/1` from a tool whose module does not export `release/3` raises in the tool Task, so the call ends with an error result before any external work starts.
8. A call to `hold/1` from a process outside the hands exits, so no external work starts. An older Core made it a no-op, so a bare unit test of a tool could hold with no hands; such a test now gives the tool a fake hands process.
9. Revision of 2026-10-17 (#651): `Helyx.Tool.unhold/1` drops handles whose resources the caller released itself with its own `release/3`, and only the handles that the release confirmed. A harness provider replaces its program at a turn start, so without it the hands held two handles per relaunch until the provider process ended, and the release at that end signalled group ids that the OS could have given to other processes. A handle that the caller does not hold changes nothing.
10. Revision of 2026-10-23 (#752): the session stops the hands with a call (`Helyx.Session.Hands.stop/3`), not with an exit signal. The hands kill every Task that still runs, a background run and the provider process of a turn too, and release their handles with `:cancel`, one release Task per module in parallel as at an abort (rule 5), by the deadline that the session gives. Before it, the hands ended those Tasks with no release, and the closed port made the watchdog clean up with no confirmation. The answer is every handle that a release of the hands left unconfirmed, from the start of the session: `Helyx.Sessions.stop/1` returns `:ok` when it is empty, else `{:error, {:not_released, handles}}` (`docs/features/session-lifecycle.md`, "Session stop"). Rule 6 holds: a handle that is unconfirmed gets no release at the stop. A child session of the agent tool counts: the release of its handle confirms it only when the stop report of the child is `:ok` (`docs/features/agent-tool.md`, "The stop report of the child").
    Replaced mechanism. The exit signal `:shutdown` of the session to the hands, and the `terminate/2` of the hands that killed each Task with no release, are replaced by the call `{:stop, deadline}`, whose reply comes before the hands end with `:shutdown`, so the `:DOWN` reason of the hands does not change (`test/helyx/session/provider_process_test.exs`). Revision of 2026-10-23 (#840): the `terminate/2` of the hands stays, for the ends of the hands other than the stop call: a kill of the session, a crash of the stop of the session (`Helyx.Session.Server.Stop.run/1`) before the stop call, and a crash of the hands. On those ends the hands end with a reason other than `:normal`, and the link of `Task.Supervisor.async` ends each Task but one: a provider Task in the crash path of `Helyx.Reason.task/2` traps exits while Logger runs plugin code, such as the `message/1` of an exception, and when that code blocks, only the kill of `terminate/2` ends the Task. Open hole, no ticket: the kill of the hands when the stop call passes its wait (`Helyx.Session.Server.Stop`) cannot be trapped and runs no `terminate/2`, so such a provider Task stays, and so does a release Task of the hands in the same crash path, which is not in the Tasks of the hands at all. The probes are in `docs/reviews/2026-10-23-840-hands-terminate.md`. The flag `unconfirmed?` of the hands becomes the list `unconfirmed`; a non-empty list refuses as the flag did (`test/helyx/session/hands_test.exs`, `hands_busy_test.exs`, `summary_test.exs`). The order guarantee stays: the hands handle the end of a closed provider process before the stop call, as they did before the exit signal. `GenServer.stop/3` in `Helyx.Sessions.stop/1` is replaced by a `:stop` call that `terminate/2` answers; the subscribers still get `:normal`, so `Helyx.Session.end_reason/1` gives `:stopped` (`test/helyx/sessions_test.exs`). A client sees one change: a stop that another end of the session overtakes gives `{:error, {:not_released, :unknown}}`, where it gave `:ok`, or `{:error, :session_not_found}` when the other end came during the abort. The wire answers `{}` for both, so a wire `stop` that another end overtook during its abort answers `{}` where it answered `session_not_found`.

`Helyx.Tool.Bash`:

- Implements `release/3`, because the hands find the callback through the tool module of the call. It delegates to `Helyx.Tool.Bash.Group` (`@moduledoc false`), which #10 moved to `Helyx.Watchdog.Group`.
- At its timeout, bash releases its own handles with `:cancel` (`docs/features/bash-timeout.md`), and the hands give the same handles to its `release/3` with `:deliver` when the call delivers. So the bash release must be safe to call again with the same handles; a group that is gone counts as released.
- Handles are `{:watchdog, os_pid}` and `{:command, group}`, each with its release record since #492 ("The release record" below). A group below 2 is never signalled: `kill -- -1` would reach every process of the user. No caller makes another handle; `Group.release/4` drops one unsignalled (#367; before it, an unknown handle was returned as still held).
- `Helyx.Tool.Bash.Group` (now `Helyx.Watchdog.Group`, #10) receives the code that leaves `lib/helyx/session/hands.ex`: `signal`, `await_gone`, `poll_gone`, `kill_and_wait`, `sweep_watchdogs`, `split_kinds`, and the `kill_cmd` test hook, which becomes the `kill` argument of `Group.release/4`.
- The order does not change: command groups first, the watchdog last, so the watchdog can reap its child before a KILL. A zombie child stays in its group until it is reaped, so this order also prevents an endless poll. A watchdog exits by itself once its command is reaped; its KILL is the fallback for one that never does. The watchdog ignores TERM, so only the command groups get one.
- The mode selects today's sequences. `:deliver` is KILL, wait, then the watchdog sweep. `:cancel` is TERM, 500 ms grace, KILL, wait, then the watchdog sweep.
- Revision of 2026-10-17 (#651): the release probes every group once before any signal or wait, and a group that is gone drops out. Before it, a command group that stayed to the deadline kept the watchdog handles, which the release probes only after the commands, even when those watchdogs were gone.
- The plugin computes its waits from the deadline. It never waits past it, and it starts no `kill` run at or after it: a probe that it skips counts the group as alive. A group is gone only when `kill` reports "No such process"; any other failure keeps the handle held. The watchdog KILL comes after one wait of 5,000 ms, so it needs that much time before the deadline.
- Revision of 2026-10-19 (#802): a start that fails releases the watchdog hold that it took. `Helyx.Watchdog.start/4` holds `{:watchdog, os_pid}` before it reads the marker, and its error return gives the caller no handles. Before it, the hands held that handle until the end of the Task or of the provider process, one per failed start, and the release at that end could signal a group id that the OS had given to another process. Now both error paths, a watchdog that could not start the command and a watchdog that gave no marker, close the port, release the handle with `Helyx.Watchdog.Group.release/4` with a deadline of 100 ms, and drop it with `Helyx.Tool.unhold/1` when the release confirms that the watchdog is gone (rule 9). A watchdog that is not gone by the deadline, or a probe that cannot run because kill(1) is not on PATH, keeps the hold for the release of the hands, as before; the start still returns its reason. The release never KILLs it: the KILL waits 5,000 ms. The release runs in the caller, as the release at a harness launch does (`Helyx.HarnessIO`), so a kill(1) run that started before the deadline is waited for: accepted, a kill(1) run has no timeout of its own. The success path does not change.

### The release record

Decision of the owner on 2026-11-06 (#492). It landed with slice 8 of `docs/features/mcp-client.md`; the handle shapes above gain the record as a third element.

- Every group that `Helyx.Watchdog.start/4` makes, the watchdog process and the command group, gets one release record, an `:atomics` slot, and its handle carries it: `{:watchdog, os_pid, record}` and `{:command, group, record}`. A copy of a handle, such as the one that an MCP call Task holds for the groups of its server, carries the same record.
- `Helyx.Watchdog.Group.release/4` takes the record of each handle with a compare-exchange before any probe or signal, on every path: the `release/3` of `bash` and of the MCP plugin, `let_go/2`, the cleanup of a failed start, and the harness providers through `Helyx.HarnessIO`. The states: held (the start state), releasing (taken, with the deadline of the release that took it as its lease), gone (confirmed gone), not confirmed. The record and its states are `Helyx.Watchdog.Record`.
- Held or not confirmed: the release takes it, probes, and signals as above. A probe that confirms the group gone writes gone at once; at its end, or when it raises, the release writes not confirmed for each record that it still holds. A group that a release could not confirm gone is still its holder's group as far as Helyx knows, so the next release may try again; the window between a probe and a signal stays, as before.
- Gone: the release sends no probe and no signal, and confirms the handle. A number that the OS gave to a new group after the confirmed release is never signalled: not at the second release of one handle (the bash timeout, then the delivery), not at the release of a second holder (the server Task after the abort of an MCP call), and not at the release of a handle that a Task kept because it was killed between its own release and its `Helyx.Tool.unhold/1` (rule 9).
- Releasing: a release that finds it waits, polling every 20 ms, for the release that holds it to write gone or not confirmed, and then confirms the handle or takes the record; or for that release's lease to pass, after which that release starts no kill(1) run, and takes it over. It sends no probe and no signal while it waits, and its own deadline ends the wait with the handle unconfirmed. So each group gets signals from one release at a time. A release that was killed in the middle, such as the bash timeout release in the call Task that an abort kills, or the release Task that the hands kill at the deadline, holds the record until its lease passes (slice 8 review).
- One release that gets two handles with one record, such as the stop of the session that releases an MCP call Task and its server Task in one `release/3` of the plugin (rule 5: one release Task per tool module), takes the record once and gives both handles the one outcome.
- Rule 9 is unchanged: `unhold/1` drops only handles whose resources the caller released itself, and only those that the release confirmed.


## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| release deadline, `:deliver` and `:cancel` | `Helyx.Session.Hands.State.release_ms/0` (value in `docs/features/session-lifecycle.md`, "Bounds"), absolute monotonic time on the hands node. The worst bash release is 15,500 ms (500 ms grace and three waits of 5,000 ms, `docs/features/coding-agent.md`, row "wait for a killed process group") | the hands stop the release Task; every given handle is unconfirmed; the result is an error; later calls are refused until the session stops |
| TERM grace, KILL wait (bash internal) | 500 ms and 5,000 ms, unchanged | a group still alive after the KILL wait is returned as still held |
| poll interval (bash internal) | 20 ms, unchanged | – |
| wait for the watchdog of a failed start to be gone | a deadline of 100 ms (`@gone_ms` in `Helyx.Watchdog`), after the port is closed: no kill(1) run starts at or after it, and one that started before it is waited for. A watchdog that read to its exit status is gone at the first probe. One that gave no marker and still runs ends at the end of its stdin (`watchdog.pl`). In a harness launch the wait is part of the bound of the launch: the 2,000 ms reply bound in a turn, or the 30,000 ms connect bound of `init/3` (`docs/features/session-lifecycle.md`) | the handle stays held, and the hands release it at the end of the Task or of the provider process |
| handles per Task | 2 per program run, held by `Helyx.Watchdog` for the bash tool and both harness providers: the watchdog and the command group. The bash tool and Codex start one run per Task. Claude Code starts a second run in the same Task after a lost session, so its Task holds at most 4. Plugin code is trusted, so there is no cap; accepted (#101) | – |
| unconfirmed handles | bounded by the refusal rule: once one is held, no new call runs, so no new handle is created. At most the handles of the calls of one turn, of the background runs, and of the provider processes. The hands keep them until their stop, for its answer (rule 10) | – |
| release at the stop of the hands | the deadline that the session gives: `release_ms` from the send of the stop call (`docs/features/session-lifecycle.md`, "Bounds"). A release of a message that the hands handled before the stop call takes from it | as for a release: every given handle is unconfirmed, and the stop answers it |
| wait of a release for a record that another release took | until that release writes its outcome, or its lease, the deadline of that release, passes; a poll every 20 ms (`Helyx.Watchdog.Record`); never past the waiting release's own deadline. The longest: a bash timeout release killed by an abort holds its record up to `Helyx.Watchdog.Group.max_cancel_ms/0`, 15,500 ms, from the timeout, inside the 20,000 ms release deadline of the abort | the handle stays unconfirmed, with no signal |
| wait in `hold/1` | a `GenServer.call` with `:infinity`, as `register_group/2` was. The handler only updates a map. It can wait behind one release, which the first row bounds | the command is held until the call returns, so nothing runs unheld. An abort kills the tool Task, which ends the wait |

Tests at the limits: a release that returns 50 ms before the deadline, one that returns 50 ms after it, a return value with a handle that was not given, an improper list, a raise, and an exit.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| command process group | the watchdog's fork; `{:command, group}` is held with the hands before the command may run | hands (opaque handle) and watchdog (the life) | at delivery the hands call `Bash.release(handles, :deliver, deadline)`: KILL, then a bounded wait | the closed port ends the watchdog's stdin: TERM, 500 ms grace, KILL, reap. If the tool Task crashed, the hands still release at delivery of the crash result | the hands call `Bash.release(handles, :cancel, deadline)`: TERM, grace, KILL, wait |
| watchdog process (its own group) | `Port.open` in `Helyx.Watchdog.start/3` (#10); `{:watchdog, os_pid}` is held with the hands | the port | exits after it reaps the command; `release/3` waits for it after every command group is gone or still held. At a failed start, `Helyx.Watchdog.start/4` releases it and drops the hold when the release confirms it gone (#802) | the closed port is its signal | `release/3` waits for it last |
| a process that leaves the command group (`setsid`, `set -m`, `setpgrp`) | the command | nobody | not released: the command group is gone, so the release confirms the handles | not released | not released. A documented limit, as before this change (`docs/features/coding-agent.md`, below the ownership table). Such a process can survive any stop of the session; a caller that must be certain runs Helyx in a container or a cgroup |
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
