# Review: #271, group_test deadline under load

Date: 2026-09-30. Base: `origin/master` at `19469a1`. Test-only change.

## Invariant

The test "a group that survives KILL is still held, and the deadline bounds the wait" in `plugins/bundled/test/helyx/watchdog/group_test.exs` sends its first KILL before the deadline under load, and it still fails when `Helyx.Watchdog.Group.release/4` lets the 5,000 ms KILL wait pass the deadline. The deadline is now `4 * @load_ms` (1,000 ms), not 100 ms.

Accepted hole: a stall of more than 1,000 ms before the first kill(1) run skips the KILL, and the test fails with `signals() == []`. The alternative in the ticket, a deadline taken from the time of the first KILL, needs the deadline after `release/4` starts, which its signature does not allow.

Mutation check: `within/2` changed to ignore the deadline makes the test fail with `left: 4003` (four runs by three agents: 4003, 4004, 4013, and Codex 4002).

## Bounds sensor

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

## Round 1 (full)

Simplify (4 agents): reuse and altitude clean. Skipped: fold of the two grace tests, the `signals/1` default, the `sleep && kill` form, and other line breaks (all outside the diff); a deadline of 400 to 500 ms (a smaller load margin for 0.5 s in an async test).

| # | Axis | Finding | Resolution |
|---|------|---------|------------|
| 1 | Standards | The literal `1_000` is a second load margin, not tied to `@load_ms`. | Fixed: `deadline(4 * @load_ms)`, and the comment states it. |
| 2 | Standards | The comment repeats the 5,000 ms of `@wait_ms` in `group.ex`. | Judgement; kept. The next test's comment does the same, and the test would fail if the wait changed. |
| 3 | Spec | None. The ticket names the larger deadline with the `@load_ms` margin as a fix. | - |
| 4 | Failure path | 1 of 10 fresh-VM runs failed, output not kept. | Not reproduced: 5 more fresh-VM runs passed. The spec agent saw a `within/2` mutation of another reviewer in the shared worktree at the same time, which is the likely cause. |

Codex adversarial review: approve, no findings.

No round reproduced a defect, so the loop ends after round 1. Fix 1 is a wording change of the same value.

## Precommit

Passed on the first run: root 359 tests, bundled 487 tests and 1 property, app 17 tests, 0 failures.
