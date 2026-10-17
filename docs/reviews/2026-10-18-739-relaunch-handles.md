# Review: #739, the relaunch-handles prompt test failed once in a full bundled run

Scope: the working tree on branch `ticket/739-relaunch-handles`, base `origin/master` (`cf993784`). Feature doc: `docs/features/provider-parity.md`, the bounds row "release of the groups of the program before, at a launch" and the ownership row "the hands' handles of a replaced program".

## Cause

The ticket asked first: a test race or a Core defect of #726. It is a test race. #726 is not on the path.

- The test drives `Helyx.Provider.ClaudeCode` from the test process with no session (`Helyx.Test.HarnessDriver`, `Helyx.Test.ClaudeCodeFake`). A call trace of `Helyx.Session.Server.TurnLoop` in a throwaway copy under `.scratch/` counted 0 calls in 40 runs.
- The only path to more than two held handles is `let_go/1` in `Helyx.HarnessIO`: the release of the program before has a deadline of 500 ms, a probe after the deadline is skipped, and the handle stays held. The feature doc allows this.
- Forced order: the copy suspended the test process (`:erlang.suspend_process/1`) for 600 ms at the release of the third launch. The hands then held three handles (`[command: _, watchdog: _, watchdog: _]`), and the old assertion `[command: _, watchdog: _]` failed. A suspension at the release of the second launch did not fail the test: the third launch released the old handles. The release runs in the test process, not in the hands, so the copy suspends the test process; `Helyx.Test.Hands` is a fake.
- Measured times of the release: 3 to 7 ms in 40 runs alone; 3 to 127 ms in 40 releases of one full bundled run (835 tests, 0 failures). `HarnessIO.finish/1` took 50 to 61 ms of its 1,000 ms in the same runs. So the release is the step that load slows most, and its 500 ms deadline is the first bound that a stall breaks. The failure text of the original run was not kept, so that the original run broke this bound is not measured; it is the only mechanism found.

## Change

`Helyx.Test.Hands.assert_one_program/2` asserts that the fake hands hold the handles of the provider state, and, when the step that launched the last program took less than `Helyx.HarnessIO.let_go_ms/0`, also exactly one command and one watchdog. The gate is sound: `let_go/1` takes its deadline after `started`, so a step under the deadline ran every probe in time. The three tests that assert one program after a launch use it: `claude_code/prompt_test.exs` "the hands hold the handles of one program across relaunches", the same test in `codex/prompt_test.exs`, and the lost-session test in `claude_code/compact_test.exs`. `Helyx.HarnessIO.let_go_ms/0` is a new one-line accessor, as `line_max_bytes/0`, so the test does not copy the 500.

Checks: with `let_go/1` made a no-op for one run, the three tests failed (four or six handles). The forced 600 ms stall passes with the new check. In normal runs the gated step took 15 to 176 ms, so the strict assertion runs.

## Simplify

Four agents (reuse, simplification, efficiency, altitude). Efficiency: clean. Altitude: the fix is at the right depth; a check without time would pass a no-op `let_go/1`. Fixed (reuse, simplification, altitude): the copied `@let_go_ms 500` became `Helyx.HarnessIO.let_go_ms/0`; the helper comment became shorter. The altitude agent named the `:slow` test at `prompt_test.exs:86`: see "Accepted holes".

## Round 1 (full)

Bounds sensor, base `origin/master`: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`

Codex adversarial review, base `origin/master`: `Verdict: approve`, "No material defect found in the five working-tree changes." "No material findings."

| Source | Finding | Resolution |
|---|---|---|
| Standards | Judgement: the helper comment was one long sentence and gave a reason. | Fixed: shorter sentences. |
| Standards | Judgement (Mysterious Name): `assert_one_program/2` checks one program only on a fast step. | Kept: the name says the property of the three tests; the comment says when the strict part runs. |
| Standards | Judgement (Duplicated Code, Data Clumps): three call sites repeat `started`, step, check; the helper could take the step as a function. | Kept: the steps return `state` or `{actions, state}`, so a function argument adds code at each site. |
| Standards | The strict assertion could stop running unnoticed when the step is slow. | Kept: measured 15 to 176 ms in normal runs against 500 ms. |
| Spec | The verdict (test race, not #726) was not recorded. | Fixed: this record and the commit message. |
| Spec | `HarnessIO.let_go_ms/0` is in `lib/`, and the ticket says "the test file only". | Kept as a decision: no behaviour changes, and it follows `line_max_bytes/0`; a copy of the 500 could drift. |
| Spec | Two sibling tests changed beyond the named file. | Kept: they assert the same property over the same release. |
| Spec | The accepted hole of the `:slow` test was not written in the file. | Fixed: its comment names it. |
| Failure path | None reproduced. Probes: a 700 ms suspension at the third and at the second release; timing of the gated step in 22 runs (14 to 160 ms). Not reached: a full suite run, a forced suspension in the codex and compact tests. | n/a |

Guarantee table of the helper comment (`plugins/bundled/test/support/hands.ex`):

| Guarantee | Proof |
|---|---|
| The fake holds the handles of the provider state | `hands.ex` `assert_one_program/2`, used at `claude_code/prompt_test.exs:60`, `codex/prompt_test.exs:74`, `claude_code/compact_test.exs:256` |
| A step under the deadline holds one command and one watchdog | the same; no-op `let_go/1` run: three failures |
| A slower step can keep a handle held, with no false failure | forced probes of the author, the failure-path and the spec reviewer (600 and 700 ms) |

Round 1 reproduced no defect, so the loop ends.

## Accepted holes

- The `:slow` test "a group that ignores TERM does not keep the handles of the later programs" keeps its exact assertion. Its release always runs to the deadline, so no time gate applies; a stall at its first probes can keep more handles held.
- On a step of 500 ms or more, the three tests check only that the hands hold the handles of the provider state; a no-op `let_go/1` passes such a run.
