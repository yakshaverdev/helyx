# 2026-09-30: simplification run

An orchestrate run on the tickets of the simplification review (`docs/reviews/2026-09-30-simplification.md`). The review found accidental complexity, waits that should be events, and numbers with more than one source. Its low-risk group became seven tickets, #258 to #264. The run built all seven and two test fixes that it found on the way.

## Merged

| Ticket | PR | Change |
|---|---|---|
| #258 | #267 | HarnessIO: the dead exit-wait code and the `done?` and `deadline` fields are gone |
| #259 | #268 | Watchdog: only `nil` or `:open` input, one grace source, no release hop, a named poll |
| #262 | #270 | Session: a notice when an abort cleanup or a session-file write fails |
| #260 | #272 | Harness adapters share launch, release, port messages, and `wire_id/1`; Codex answers `:ok` for a port exit during a close; Claude tool ids no longer collide |
| #261 | #273 | Session: no `provider_pids`, no `Session.model/1`, the kill timer armed inside the Task |
| #264 | #275 | Tests: one `assert_receive` timeout, shared helpers, event waits in place of guessed sleeps |
| #263 | #276 | One source for each number, units in names, a correct heap comment |
| #274 | #278 | Test: one live watch after a second subscribe, independent of the Registry cleanup |
| #271 | #279 | Test: the KILL deadline test has four load margins, not 100 ms |

Process commit: `751af90`, the review itself, straight to master at the owner's request.

No ticket was parked. The waves were chosen by the files that tickets share: #258, #259, #262 and #264 first; #260 after #258 and #259; #261 after #262; #263 last. Rebase conflicts were all mechanical (#259 on #258 in `go_ahead_test.exs`; #260 on #262 in the bounds table of the feature doc; #264 on #259, #260 and #261 in three test files).

## Escapes

| Ticket | Codex | System change |
|---|---|---|
| #264 | gate r1: 1, gate r2: 0 | Checklist, new Tests section: a replaced wait keeps the exit condition of the old poll as an assertion. The worker's sweep found and restored four more lost checks of the same class. |

All other tickets had no Codex finding in the gate.

## Orchestrator mistake

In the #260 rebase, `git rebase ... | tail -1 && ...` took the exit code of `tail`, so a conflict did not stop the chain. The next step committed a feature doc with conflict markers, and precommit ran on that tree. Nothing was pushed: the rebase was aborted and done again. Later rebases in the run tested the exit code of `git rebase` itself.

## New tickets

- #269 (`needs-triage`): a failed session-file write at a resume happens before any client subscribes, so no client sees the notice. A fix needs a snapshot field (ADR 0006).
- #277 (`needs-info`): the Claude Code abort-then-next-turn test failed once in about 16 runs. The long-lived harness run saw it too. The output was not kept.
- #265 and #266 stay `ready-for-human`: the removal of the per-turn external mode needs an ADR 0002/0007 change, and the session-file ownership needs a design decision.

## Next

- Group 3 of the review: the `harness_reply` kind change, then the Steers and Wait extraction from `Session.Server` (review section 2b). No tickets yet.
- Owner notes from #263: the `@max_open` pool of 8 is shared, so 8 open steers make an interrupt get `:busy`; the `Helyx.Provider` moduledoc now names private attributes instead of numbers.
- GitHub again did not close the issues from "Closes #n"; each was closed by hand. Check the repository setting.
