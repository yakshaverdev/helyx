# Print mode waits for its background runs

## Goal

A print run (`helyx -p`) that starts a long command with `bash` `background: true` and ends its turn keeps that command and its end (#591). Before this, print mode ended at the first `turn_end` after its prompt, and the session stop ended every background run that still ran (`docs/features/print-mode.md`, `docs/features/background-bash.md`). A worker of #578 is a print run, and its `/ship` starts the Codex review and precommit in the background.

Decisions (owner, 2026-10-14, in #591):

1. Print mode stays while the session has a live background run or a waiting end. Each end opens a turn by the rules of #577 (the idle wake).
2. Print mode exits when the session is idle with no live background run and no waiting end. stdout gets the answer of the last turn, and the exit status is that turn's status.
3. The background `timeout` of each run (default 3,600 s, at most 86,400 s) bounds the wait.

Decision (owner, 2026-10-15, in #591): print mode reads no text, tool name, or arguments to count the live runs. Core counts them. Two review rounds found that a count from the result texts breaks: a call of another tool can return the start line, and the programs of Claude Code and Codex give their tools names of their own.

Decisions of this doc (the open items of #591):

- **How print mode learns that the session is settled: Core counts, and print mode reads the counts.**
  - The hands send the start answer of a background run as a `{:started, text}` result (`Helyx.Session.Hands`), on the same line as before. The session server adds 1 to `running` (`Helyx.Session.Queue`) and handles the result as `{:ok, text}`, so the transcript and the provider see nothing new. Each `{:background_end, text}` subtracts 1. A crash of a run goes through the same end, and `kill/3` and a cancel do not reach a background run, so each start adds 1 and each end subtracts 1, exactly once. A Task that a cancel or a kill ends before its start answer sends no start answer and no end.
  - The count lives in `Helyx.Session.Queue` next to `ends` and `hold`, so no new process holds it and every change goes out through `queue_update`.
  - A resume starts `running` at 0: its lost runs are not live, and their lost ends wait under the hold (`held`).
  - An end that no turn took yet is `held` or `waiting`. `waiting` counts the ends that wait for a turn with no hold, and the ends that a turn sent to the provider and no `user_message` took or gave back. A turn that ends normally can give such an end back, held, after its `turn_end`; so print mode must not exit while one is sent.
  - Print mode waits while `running + waiting` is above 0 and `held` is 0. The counts come from the session in its own order, so no end can wait in the mailbox of the session while print mode sees 0: the end that subtracts 1 from `running` adds 1 to `waiting` in the same change.
  - A background run stays a tool construct of `Helyx.Tool.background/0`. Core counts its start and its end, which the hands already send. Core names no client.
- **A held end.** Ends hold from an abort, a failed turn, a resume, or an end that a turn gave back, until the next turn opens (`docs/features/background-bash.md`). In print mode no user sends a prompt, so a held end never opens a turn. Print mode does not wait for it once the session counts it (`held` above 0):
  - An aborted or a failed turn ends print mode at once with 1 and nothing on stdout, as before. The session stop ends the runs that are still open.
  - A turn that ends normally with a held end ends print mode too: its answer goes to stdout, one stderr line says `helyx: background runs whose end did not reach the agent: N` (N is `running + waiting + held`), and the status is 1, as for an answer cut at the output limit. The runs did not reach the agent, so the work is not complete.
  - A held end that comes between turns ends print mode the same way, with the answer of the last turn: a late answer of the provider gives an end back, or the end of a run arrives while the ends hold. The second case is a hold with no end yet: an end that a turn gave back while it prepared went into that turn, and the hold stays after it. Print mode then waits until the end of the next run arrives, which its `timeout` bounds.
- **SIGTERM and SIGHUP during the wait.** No change to the path of #491. The run process waits in the same receive. The first signal aborts the session (an idle session answers the abort at once), waits at most `abort_ms/0`, and halts with 143 or 129. The run process can end first (a held end, or the end of the session); the halter then waits for the halt of the stop, so the status of the signal stands.
- **stderr between turns.** After each normal turn end that leaves a running run or a waiting end and no held end, one line: `helyx: waiting for background runs: N` (N is `running + waiting`). The answers of the turns before the last one do not go to stdout: stdout holds only the answer of the last turn. The session file keeps all of them.

## Interface changes

- `Helyx.Event` `:queue_update` and `Helyx.Session.Snapshot` `queue`: three new counts. `running: non_neg_integer()`, the background runs from their start answer to their end. `held: non_neg_integer()`, the background ends that wait for the next prompt and open no turn by themselves (0 while the ends do not hold). `waiting: non_neg_integer()`, the other ends that no turn took yet. A change of one of them alone emits `queue_update`. A client that does not know a key ignores it (ADR 0006). The TUI keeps only the steers and the follow-ups.
- The result that the hands send for a background start (internal): `{:started, text}` in place of `{:ok, text}`. Only the session server reads it.
- `Helyx.Session.Queue` (internal): `started/1`, `ended/2`, and `running`; `counts/1` returns the five counts.
- `CodingAgent.Print.run/2`: it waits for the session to settle, not for the first `turn_end`. It returns the status of the last turn, or 1 as above.

No new public function and no new event type.

## Replaced mechanism

The end rule of `CodingAgent.Print.run/2`.

1. Old: the first `turn_end` ends the wait. New: a `turn_end` with outcome `:done` ends the wait only when `running + waiting` is 0 or an end is held. Else print mode waits for the next `turn_start` or for a `queue_update` with `held` above 0. `:aborted` and `:error` end it as before.
2. Old: the last assistant message of the wait is the answer. New: the last assistant message of the last turn; each `turn_start` clears it.
3. The text derivation of round 1 of the review is gone: print mode kept the ids of the open runs from the start answers (`tool_execution_end`) and the end messages (`message_end`) with a copy of the start-line pattern. `CodingAgent.Print` now reads only `queue_update` and the snapshot `queue`.
4. The tests of the old rule stay: a turn with no background run ends print mode at its `turn_end`, with the same output and status.
5. Seen by users: a print run with a background run exits later, after the end of its runs, with the answer of the last turn. A TUI client gets one more `queue_update` at each start and each end of a background run.
6. No state with no bound in print mode beyond the rows below.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| wait with no turn | the running runs: each ends at its `timeout` (default 3,600 s, at most 86,400 s), and its end opens a turn. So the longest wait with no turn is the longest remaining `timeout` of the running runs, plus the release grace of its timeout | n/a | `Helyx.Tool.Bash.run/2`, the hands |
| a whole print run | unbounded inside Helyx: a turn has no bound (owner decision of #491), and each turn can start new runs, at most 16 live at a time. The caller uses `timeout(1)`, which sends SIGTERM | a signal halts the VM | `CodingAgent.Print` |
| wait for a sent end after `turn_end` | the answer of the provider to the steer: 2,000 ms (`@provider_reply_ms` of `Helyx.Session.Server.State`), then the kill of the provider process and its `provider_down`. A rejection queues the end and opens a turn; any other answer, and the `provider_down`, give it back, held when no turn is open (`Helyx.Session.Queue.answer/4`, #587) | a held end: print mode exits with the held-end line and 1 | `Helyx.Session.Queue`, `CodingAgent.Print` |
| `running` | the live runs: at most 16 (`Helyx.Tool.background/0`) | the place is refused | `Helyx.Session.Queue` |
| state of the wait in print mode | the last assistant message and the last counts | n/a | `CodingAgent.Print.run/2` |
| stderr lines | the lines of print mode, through `CodingAgent.clean_line/1`, as before | n/a | `CodingAgent.Print` |

## Ownership

No new resource. The background runs keep the rows of `docs/features/background-bash.md`: the session stop at the end of print mode ends every run that is still open.

## Accepted holes

- A start answer can reach the session after a `turn_end` with outcome `:done` (review round 4). A turn can end normally while a Helyx tool call runs; the session emits `turn_end` and then asks the hands to cancel the Tasks of the turn. If the hands handle the start answer of a background run before the cancel, the run leaves its turn and lives, and its start answer comes after `turn_end`. Print mode then sees all counts at 0, exits with the answer and 0, and the session stop ends the run. The model got `aborted` for that call. Only a provider that ends its turn while a Helyx tool call is open reaches it, in the window between the place of the run and its start answer. The fix is #595: the order of `turn_end` and the cleanup in Core, or a count of the place.

- A turn that the provider starts by itself (#240) clears a hold. Print mode can exit before that turn.
- A hold with no held end yet (above) holds print mode until the end of the next running run arrives, up to its `timeout`, though that end opens no turn.

## Out of scope

- A bound of a whole print run inside Helyx.
- The answers of earlier turns on stdout.
