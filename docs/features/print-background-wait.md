# Print mode waits for its background runs

## Goal

A print run (`helyx -p`) that starts a long command with `bash` `background: true` and ends its turn keeps that command and its end (#591). Before this, print mode ended at the first `turn_end` after its prompt, and the session stop ended every background run that still ran (`docs/features/print-mode.md`, `docs/features/background-bash.md`). A worker of #578 is a print run, and its `/ship` starts the Codex review and precommit in the background.

Decisions (owner, 2026-10-14, in #591):

1. Print mode stays while the session has a live background run or a waiting end. Each end opens a turn by the rules of #577 (the idle wake).
2. Print mode exits when the session is idle with no live background run and no waiting end. stdout gets the answer of the last turn, and the exit status is that turn's status.
3. The background `timeout` of each run (default 3,600 s, at most 86,400 s) bounds the wait.

Decisions of this doc (the open items of #591):

- **How print mode learns that the session is settled: it derives it from the events.**
  - An open run is a start answer with no end message. The start answer is a tool result (`tool_execution_end`, not an error) whose text opens with `<background id="ID" status="started">`. The end message is a user message (`message_end`) that opens with `<background id="ID" ...>`.
  - Print mode keeps the set of open ids from the transcript of its snapshot and from the events, as `Helyx.Session.Background.lost/1` does at a resume. An open run is live, or its end waits in the session. Either way an end message comes, unless the ends hold.
  - The hold of the ends (`Helyx.Session.Queue`, `hold`) was the one fact that no event showed. So `queue_update` and the snapshot get `held`, the count of the ends that wait under the hold. There is no new event type and no new function.
  - A count, not the flag. The flag changes at every abort and failure and at the next turn open, also with no background run. Each change would be one more event for every client. The count changes only when a held end exists, which is the only case that print mode needs.
  - Why not a query of the live runs: such a query in Core needs the hands, and the hands send an end to the session as a message. A query can see 0 live runs while that end still waits in the mailbox of the session. Print mode would then exit before the turn that the end opens. The events come from the session in its own order, so the derivation has no such race.
  - A background run stays a tool construct of `Helyx.Tool.background/0`. Core names no client.
- **A held end.** Ends hold from an abort, a failed turn, a resume, or an end that a turn gave back, until the next turn opens (`docs/features/background-bash.md`). In print mode no user sends a prompt, so a held end never opens a turn. Print mode does not wait for it once the session counts it (`held` above 0):
  - An aborted or a failed turn ends print mode at once with 1 and nothing on stdout, as before. The session stop ends the runs that are still open.
  - A turn that ends normally with a held end and an open run ends print mode too: its answer goes to stdout, one stderr line says `helyx: background runs whose end did not reach the agent: N`, and the status is 1, as for an answer cut at the output limit. The open runs did not reach the agent, so the work is not complete.
  - A held end that comes between turns ends print mode the same way, with the answer of the last turn: a late answer of the provider gives an end back, or the end of a run arrives while the ends hold. The second case is a hold with no end yet: an end that a turn gave back while it prepared went into that turn, and the hold stays after it. Print mode then waits until the end of the next run arrives, which its `timeout` bounds.
- **SIGTERM and SIGHUP during the wait.** No change to the path of #491. The run process waits in the same receive. The first signal aborts the session (an idle session answers the abort at once), waits at most `abort_ms/0`, and halts with 143 or 129. The run process can end first (a held end, or the end of the session); the halter then waits for the halt of the stop, so the status of the signal stands.
- **stderr between turns.** After each normal turn end that leaves an open run and no held end, one line: `helyx: waiting for background runs: N`. The answers of the turns before the last one do not go to stdout: stdout holds only the answer of the last turn. The session file keeps all of them.

## Interface changes

- `Helyx.Event` `:queue_update` and `Helyx.Session.Snapshot` `queue`: a new count `held: non_neg_integer()`, the background ends that wait for the next prompt and open no turn by themselves (0 while the ends do not hold). A change of `held` alone emits `queue_update`. A client that does not know the key ignores it (ADR 0006).
- `Helyx.Session.Queue.counts/1` (internal) returns `held` with the other counts. The TUI keeps only the steers and the follow-ups.
- `CodingAgent.Print.run/2`: it waits for the session to settle, not for the first `turn_end`. It returns the status of the last turn, or 1 as above.

No new public function and no new event type.

## Replaced mechanism

The end rule of `CodingAgent.Print.run/2`.

1. Old: the first `turn_end` ends the wait. New: a `turn_end` with outcome `:done` ends the wait only when no run is open or an end is held. Else print mode waits for the next `turn_start` or for a `queue_update` with `held` above 0. `:aborted` and `:error` end it as before.
2. Old: the last assistant message of the wait is the answer. New: the last assistant message of the last turn; each `turn_start` clears it.
3. The tests of the old rule stay: a turn with no background run ends print mode at its `turn_end`, with the same output and status.
4. Seen by users: a print run with a background run exits later, after the end of its runs, with the answer of the last turn. A TUI client gets one more `queue_update` at each change of `held`.
5. No state with no bound in print mode beyond the rows below.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| wait with no turn | the open runs: each ends at its `timeout` (default 3,600 s, at most 86,400 s), and its end opens a turn. So the longest wait with no turn is the longest remaining `timeout` of the open runs, plus the release grace of its timeout | n/a | `Helyx.Tool.Bash.run/2`, the hands |
| a whole print run | unbounded inside Helyx: a turn has no bound (owner decision of #491), and each turn can start new runs, at most 16 live at a time. The caller uses `timeout(1)`, which sends SIGTERM | a signal halts the VM | `CodingAgent.Print` |
| open runs that print mode keeps | one id per start answer with no end message in the transcript of the session: at most 16 live, plus the lost runs of a resume, which the transcript bounds (a session file of at most 64 MiB) | n/a | `CodingAgent.Print.run/2` |
| stderr lines | the lines of print mode, through `CodingAgent.clean_line/1`, as before | n/a | `CodingAgent.Print` |

## Ownership

No new resource. The background runs keep the rows of `docs/features/background-bash.md`: the session stop at the end of print mode ends every run that is still open.

## Accepted holes

- A foreground result whose text opens with the exact start line of a background answer counts as an open run, as it does at a resume (`docs/features/background-bash.md`, "Open"). Print mode then waits for an end that never comes, until a signal.
- A turn that the provider starts by itself (#240) clears a hold. Print mode can exit before that turn.
- A hold with no held end yet (above) holds print mode until the end of the next open run arrives, up to its `timeout`, though that end opens no turn.
- Print mode reads the start and end texts that `docs/features/background-bash.md` defines. A change of those texts changes print mode too.

## Out of scope

- A count of the ends that wait with no hold, or of the live runs, in the snapshot or in `queue_update`: print mode derives the open runs.
- A bound of a whole print run inside Helyx.
- The answers of earlier turns on stdout.
