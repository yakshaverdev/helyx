# Review: #584 interrupted tool calls

Scope: the resume read gives each open tool call a derived result that says the call may have run (`Helyx.Session.Transcript.repair/1`), the lost text of a background run in the same form, and the durability rule of the session file. Feature doc: `docs/features/interrupted-calls.md`.

## Round 1 (full)

Simplify (4 agents): one accessor `Transcript.interrupted_result/0` in place of a second literal copy of the text in `persistence_test.exs`; `transcript_test.exs` keeps the literal as the pin. The `resume/2` doc of `Helyx.Session` rewrapped, the file stays at 400 lines. Efficiency and altitude: clean.

Bounds sensor (`--diff origin/master`):

```text
bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Codex (high), failure path | A harness provider whose last assistant message had a call that a crash left open resumed its own session under the stored id (`Transcript.resumable/3`), so it got no replay, and its model never read the interrupted result. Reproduced: `resumable(repair([user, assistant(claude-code, [c1, c2], :tool_use), result(c1)]), %{"claude-code" => {"sid", 0, nil}}, "claude-code")` gave `"sid"`. The same was true for `aborted` before #584. | Fixed: `resumable/3` gives no id when a result after the last assistant message is the interrupted result; the harness starts fresh with the replay. Tests: `transcript_test.exs` "does not resume when a resume found a call of the last assistant message open", the property test models the rule, and `persistence_test.exs` "a resume with an interrupted call of a labelled provider starts that provider fresh" (fails without the fix). Docs: `interrupted-calls.md`, `one-provider-path.md` (Init). |
| Spec | The durability sentence stood in two docs. | `interrupted-calls.md` now only points to the "Durability" rule of `coding-agent.md`. |
| Spec | The test of the lost background text checked only its first two sentences. | `background_test.exs` checks the whole text. |
| Standards | "Replaced mechanism" named the private attribute. | It names `Transcript.interrupted_result/0`. |
| Standards | The VM half of "survives a crash of the process or of the VM" had no probe. | Probe: a `mix run` script appended an assistant message with an open call and sent `kill -9` to its own VM (exit 137); a second VM resumed the file and read the message with the interrupted result. |
| Standards | `@interrupted` and `@lost` keep one form only by a comment. | Judgement, kept: the texts differ on purpose. |
| Spec | `session-lock.md` out-of-scope line changed. | Kept: a pointer to the durability rule, no lock code. |

Guarantee table (spec agent):

| Guarantee | Proof |
| --------- | ----- |
| An open call gets the interrupted text at resume, after its results, in call order | `transcript_test.exs` "repair/1" tests |
| The text is fixed and pinned | `transcript_test.exs` `@interrupted` literal |
| A stored `aborted` result stays | `transcript_test.exs` "a stored aborted result of a user abort stays aborted" |
| The resume writes nothing; the result is at one place on every resume | `persistence_test.exs` "a resume writes nothing, ..." |
| A crash mid-turn: each open call gets the text in the provider request | `persistence_test.exs` "resume after a crash mid-turn ..." |
| Live abort, failure, and harness turn end still write `aborted` | `provider_process_tools_test.exs`, `loop_test.exs`, `claude_code/turn_test.exs` |
| The repair runs only in `resume/2` | probe: one caller |
| The TUI shows the whole text | probe: widths 30, 80, 200 |
| Claude Code and Codex replays carry the text | probe |
| Lost-run and interrupted cases do not overlap | `background_test.exs` (an error result is no start) |
| Durability: a VM kill keeps the appended entry; no fsync | probe above; grep: no sync call |

Codex: 1 finding, confirmed. Failure path: 1 finding (the same), confirmed. Spec: 2 confirmed. Standards: 1 doc fix, 1 probe, 1 judgement kept.

The fix of round 1 added a private function, so round 2 is a full round.

## Round 2 (full)

The fix of round 1: 18 code lines in one code file (`transcript.ex`), with a new private function, so a full round.

Simplify (4 agents): the check moved into the one fold `count_and_last_assistant/1`, which `resumable/3` already runs, so there is no second pass and no reversed copy; the private function is gone. It reads the text with `Message.text/1`, not the content layout. Not taken: the altitude agent proposed that `repair/1` drop the label of the provider whose last message it answers, and return the labels with the transcript. That changes the return shape of `repair/1` and the state build in `Helyx.Session` (at 400 lines) to remove one accepted hole (a tool error with the exact text costs one replay); the value is one module attribute, so a text edit changes both places. The altitude agent also named a sibling outside #584: a live end path that writes `aborted` results that a dead provider process never got, while the provider resumes under its id. Reported as open, not changed. The property model `open_call?/1` stays independent of `pair/2` on purpose.

Bounds sensor (`--diff origin/master`):

```text
bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path | Regression: after the resume, the fresh harness gives the id `L2` and compacts under it (label `{"L2", 1, 1}`); at the next resume the interrupted result still follows the last assistant message, so `resumable/3` gave nil, and the compaction was lost to a full replay. Reproduced through the session. | Fixed: the check applies only to an id given before the last assistant message (`before < count`). An id given after it came with the replay, which held the result. Test: `transcript_test.exs` "does not resume when a resume found ...", the `{"h2", 1, 1}` case (fails without the fix). Docs: the `resumable/3` comment, `one-provider-path.md` (Init), `interrupted-calls.md` (Clients). |
| Codex (high) | The fresh replay has the 400,000-byte bound of `HarnessIO.cap_replay/3`. One assistant message with eight calls, seven stored results of 60,000 bytes, and the eighth open: both replays leave the whole group out, and the model does not read the interrupted result. Reproduced by Codex with direct calls. | Accepted hole, stated in `interrupted-calls.md`: the replay bound is a documented safety bound of every fresh start (`long-lived-harness.md`, Bounds), and the user sees the cut notice of the TUI. Keeping the group over the bound would break the bound, and a turn failure would be a handler for one case. |
| Spec | The compaction branch (`at == count`) of the rule had only a probe. | `transcript_test.exs`: a compacted id before the message gives nil with the interrupted result, and the id with the call answered. |
| Standards | The record named a function that the simplify step removed. | Fixed. |
| Standards | `count_and_last_assistant/1` gives a third value that its name does not say. | Judgement, kept: its comment says it. |

Standards and spec ran in one agent with two sections in this round. Codex: 1 finding, confirmed, accepted as a stated hole. Failure path: 1 finding, confirmed and fixed. Spec: 1 confirmed (test gap). Standards: 1 confirmed (record), 1 judgement kept.

Two findings landed on one mechanism, the resume rule of a harness after a derived result. The mechanism stays: without it the harness model never reads the result. The alternative of round 2 (drop the label in `repair/1`) needs the same condition, a label given before the message, so the rule is now stated as that condition. Round 3 is a full round under the two-findings rule.

## Round 3 (full)

The fix of round 2: 3 code lines in one code file, a second finding on the resume rule of a harness, so a full round under the two-findings rule.

Simplify (4 agents): the new clause writes `count > before` as the clause above it does. Not taken: reading `@interrupted` from `interrupted_result/0` in `transcript_test.exs` (the literal is the pin of the text); matching the content layout in the fold head in place of `Message.text/1` (round 2 chose `Message.text/1` so that the check does not depend on the layout; the cost is one text per error result in a fold that runs once per provider start). Altitude: clean; the sibling of a live end path stays open, outside #584.

Bounds sensor (`--diff origin/master`):

```text
bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | "It takes results of more than 400,000 bytes in one message" was false: the call arguments count too. Probe: one call with 450,000 bytes of arguments and the interrupted result; both replays cut it. | Doc fixed: the message, its call arguments, and its results. |
| Spec | "The user sees the notice" was false for print mode, which drops the `resume_id` event. | Doc fixed: the TUI shows it; print mode shows no notice for a cut. |
| Spec | "so it resumes" read alone was false for a fresh id with no later message and no compaction. | Doc fixed: it resumes after a later message or a compaction, as any id does. |
| Failure path | With the fake provider only: a provider that sends the id it resumed again after a message, then compacts under it, resumes without the interrupted result. Both bundled harnesses send their id only at the first turn of a fresh program. | Not a defect of a real provider; the order is stated as an assumption in `interrupted-calls.md`, "Accepted holes". |
| Standards | The two `with` clauses of opposite polarity; one test holds six cases. | Judgement, kept. |
| Codex | Approve, no finding. | none |

The failure-path agent passed through the session: the round-2 reproduction (the provider starts with `"L2"`), a second crash before the fresh harness answers, a second crash with a compaction under `L2`, and a model switch and back.

Round 3 reproduced no defect: the loop ends. Codex: 0 findings. Failure path: 0 defects, 1 stated assumption. Spec: 3 doc findings, fixed. Standards: 0 violations, 2 judgement calls kept.

Precommit: `HELYX_SLOW=1 .claude/skills/ship/precommit.sh` passed with no warnings.

## Orchestrator gate

| Round | Finding | Resolution |
| ----- | ------- | ---------- |
| r1 (Codex) | none (approve) | n/a |

The owner chose the fresh start with the replay for a harness whose resume id came before an open call (2026-10-14), over a resume with a notice message and over native providers only. The gap of aborted results that a dead harness never got is #593.
