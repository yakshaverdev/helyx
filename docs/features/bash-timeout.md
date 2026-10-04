# Bash timeout

## Goal

A bash command that never exits must not hold the turn until the user aborts. Each call gets a time limit: 120 s by default, or the optional `timeout` argument in seconds, at most 600 s. At the limit the tool releases the command group through the release that an abort uses, and returns an error result that says the command timed out, with the output kept so far. The result says that the group was released, not that it is gone: a group that the release does not confirm is left to the hands, which make the result an error at delivery. Issue #482.

The research (`docs/research/coding-tools.md`, "Bash timeout") shows opencode with a 2 minute default and no maximum, pi with no default, and codex with 10 s. opencode stops a timed-out command as it stops an aborted one: TERM to the group, then KILL. Helyx does the same.

## Interface changes

- `Helyx.Tool.Bash.parameters/0` adds `timeout`, an integer from 1 to 600. The description and the moduledoc state the default and the maximum.
- `Helyx.Tool.Bash.run/2` returns `{:error, text}` for a `timeout` that is not an integer from 1 to 600 (a float, a string, a boolean, 0, 601). Nothing runs. Missing or `null` is the default, as the read tool's `offset`.
- `Helyx.Watchdog.start/4` returns `{:started, port, pre, handles}`: the handles it held with `Helyx.Tool.hold/1`. The bash tool gives them to `Helyx.Watchdog.Group.release/4` at the limit. The harness callers ignore them. `Helyx.Watchdog.Group.max_cancel_ms/0` gives the longest cancel release, the deadline of that release.

## Replaced mechanism

none. `collect/3` had no time limit; it gets one.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| `timeout` argument | an integer from 1 to 600, checked in `run/2`; missing or `null` is 120 | an error result; nothing runs |
| wait for a bash command | the `timeout` argument, else 120 s, counted from before the watchdog starts, so it counts the time of the hold of the handles and of the marker but cannot end those waits, in `collect/4`; the deadline is checked before each receive, so queued output cannot pass it | `Helyx.Watchdog.Group.release(handles, :cancel, deadline)`, the release of an abort: TERM, a grace of 500 ms, KILL; then an error result with the output so far. A command that ends near the limit is reported by what the tool reads first: output or nothing after the deadline gives the timeout, an exit status gives the exit, since the command did end and the wait is over |
| release and drain after the limit | one deadline of 15,500 ms, `Helyx.Watchdog.Group.max_cancel_ms/0`, the worst bash release (`docs/features/tool-resource-release.md`). An abort's release has the hands' deadline, `Helyx.Session.Hands.State.release_ms/0`, 20,000 ms, which also covers other tools. The release runs in a Task beside the drain. The drain reads until the exit status, which the port sends only when stdout closes, or the deadline: a process that left the group and keeps stdout open holds it to the deadline. The wait for the release Task ends at the same deadline: a kill(1) run has no timeout of its own | the port is closed, and a release still running is killed, as the hands do; the hands release what is still held at delivery. Output that arrived after the last read stays in the mailbox of the tool's Task, which ends with the call |
| output after the limit | the drain reads while the release runs, so the output written during the grace goes through the bounds of the output while the command runs (`keep_tail/1`) and of the result text (`Helyx.Text.truncate/2`), not into the mailbox unread | as before |

Once `Helyx.Watchdog.start/4` returns, the worst call time is the limit plus 15,500 ms. The wait for the watchdog marker and the wait to hold a handle (`Helyx.Tool.hold/1`, `:infinity`) stay unbounded, accepted, as before.

## Ownership

No new OS resource. The tool releases its own handles at the limit, in a Task linked to the tool's Task, which holds no handle of its own: an abort that kills the tool's Task kills it too, and the hands' `:cancel` releases the same handles; the hands release them again at delivery, which finds the groups gone. A release that does not finish by its deadline leaves the handles to the hands' `:deliver` release, which makes the result an error when a group stays alive.

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort | Released at the limit |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- | --------------------- |
| command process group, watchdog | `Helyx.Watchdog.start/4` | hands | hands, `:deliver` | the watchdog, when the port closes | hands, `:cancel` | the tool, `:cancel`; then hands, `:deliver` |

## Out of scope

Saving the full output to a temp file. A limit on the wait for the watchdog marker.
