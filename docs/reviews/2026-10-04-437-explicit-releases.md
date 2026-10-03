# Review: #437 explicit releases in place of timed fakes and polls

Date: 2026-10-04. Scope: test files only (`test/support/interfaces.ex`,
`test/helyx/session/provider_process_test.exs`, `test/helyx/session/file_test.exs`,
`test/support/shared/gate.ex`, `test/support/session_case.ex`).

Invariant: each held request of the fake connected provider gets no answer
until the test answers it, so each changed test reaches the phase its name
names under any machine load and keeps every check it had on master.

## Change

- `Helyx.Test.Connected`: "late_turn", "late_interrupt", "late_idle" and
  "steer_hold" hold their request; "late_close" holds its first close, and a
  later close (the one of a session stop) answers `:ok`. The controller gets
  `{:held, from}`; `{:answer, from, value}` or `{:batch, actions}` answers.
  The 100 ms and 300 ms `send_after` replies, the `{:late, ...}` message and
  the unused "tools_late" model are gone.
- `Helyx.Test.PrepareContext`: "block_prepare" sends `{:preparing, pid}` to
  the controller; the test of an interrupt during a context request waits
  for it in place of `SessionCase.await`.
- `file_test`: the header scan test writes explicit start times in place of
  two 2 ms sleeps.
- `Gate.settle` and `SessionCase.await` keep their polls and say why: the
  provider process of `Helyx.Provider.Loop` drops other messages and answers
  nothing; the other `await` callers poll a Registry entry, a mailbox
  length, or memory.

## Bounds sensor

Round 1 (base `origin/master`): `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full)

Simplify: `@done` moved to the module top; the `closes` counter became a
`closed` flag; a comment reflowed. Skipped: an option of `Session.File.create`
for the start time (lib change, out of scope); a generic "hold once" table
(one user).

Findings:

1. Codex (medium) and failure-path agent (reproduced: the stale reply landed
   with the session `:idle`): in "while submitting sends the interrupt after
   the turn", the stale reply of the aborted turn came before turn two
   existed. Fixed: it now comes after turn two is held in `submitting`.
2. Standards (checklist "Tests", #264: an event wait keeps the old exit
   condition as an assertion): the `{:preparing, task}` wait lost the check
   that the session holds the Task. Fixed: `assert prepare_task(pid) == task`.
3. Spec: "a turn reply that comes late" lost the check of the prepared
   context. Fixed in round 2 (see there).
4. Spec, not taken: `Tool.Slow` (200 ms, `provider_process_tools_test`) and
   the `{:slow, ms}` release (`hands_test`, a deadline test) are not named by
   the ticket; open for a later ticket.
5. Standards judgement calls, not taken: rename of the "late_" models (many
   call sites); a `held_turn` helper.

## Round 2 (reduced: test files only, 0 code lines)

1. Failure-path agent, reproduced: with a mutation in `turn_loop.ex` that sent
   turn two a stale context, the abort test still passed, because the test
   answered turn two with a fixed text. Fixed: `echo/3` answers a held turn as
   the "echo" model does, so the three late_turn tests assert the master texts
   again ("echo:prepared|one", "echo:prepared|two", the refuted stale
   "echo:prepared|one").
2. Spec, not reproduced, taken as a wording of the sync: "dropped in a switch
   close wait" now waits for the held close before its batch. `Task.await`
   uses `wait_ms()`.
3. Spec, not taken: "abort while preparing" is unchanged by this diff.

## Round 3 (reduced: test files only, 0 code lines)

No defect of this change reproduced, so the loop ends. The round 2
mutation (stale context for turn two) now fails the abort test.

1. Failure-path, judgement, taken: the header scan test gave the start
   times in id order, so a choice by path also passed. The start times now
   differ from the id order, and the test expects "second" (oldest mtime,
   newest start).
2. Failure-path, gap on master too, not taken: a session that took any turn
   reply in `submitting` without the check of `from` passes the abort test.
   A phase check after the stale reply is not deterministic: the stale
   events reach the session through the provider process, after a
   `:sys.get_state` of the test can. Open for a later ticket.
3. Spec: no findings.

Findings per round: round 1, 3 taken (1 defect reproduced); round 2, 1
defect reproduced, 1 judgement taken; round 3, 0 defects, 1 judgement taken.

## #277

The TERM test (`claude_code/turn_test.exs`, "with work still queued stops
the program with TERM after a 5,000 ms grace") passed 20 of 20 sequential
runs with `HELYX_SLOW=1`, about 5.3 s each, no load generator. The
cancel_queued test at line 272 passed 20 of 20. It is a deadline test and
keeps its real timer. None of the waits of #437 is in that test. #277 stays
open with a comment.

## Precommit

The first run failed one test outside this diff:
`plugins/bundled/test/helyx/provider/codex/commands_test.exs:117` ("a failed
turn with an open command stops the provider process, and the next turn
starts a new program") timed out waiting for the `turn_end` of the turn
"again". The plugin project compiles none of the changed files except a
comment in `test/support/shared/gate.ex`. Locally it passed 20 of 20 runs.
The second precommit run passed. Open: this flake has no ticket yet.
