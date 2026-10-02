# Review: a simpler WallClockUpperBound (#308)

Base: `origin/master` at `2b81e15`. Three rounds.

## Change

`credo/wall_clock_upper_bound.ex` goes from 280 to 230 lines. The moduledoc does not change, and neither does the behavior. The simpler form:

- One walker, `nodes/2`, gives the nodes of a tree in prewalk order. It replaces four separate prewalks. `value_nodes/1` leaves out a module attribute and its subtree, as the original did when it looked for a time value or a pattern variable.
- A table `@negate` turns a comparison around for `refute` and `not`. It replaces `turn/1` and the mirrored `:refute` clauses of `bound/5`.
- Every bound has one shape, `{trigger, meta, how, values, limit}`, so one comprehension in `run/2` checks all of them. `how` is `:contains` (a time value anywhere in the value) or `:itself` (a time value, or a sum or a difference of one, for an equality).

The test file keeps its 11 tests unchanged and gets 2 regression tests from the review.

Invariant: for every parsed source, the check reports the same issues, by line and trigger, as the check at `2b81e15`.

## Reference set

Repository: every assertion that the check at `2b81e15` reports when each `@load_` attribute is renamed to `@xload_` (the margin is removed), over `lib/`, `test/`, `plugins/`, `apps/`, and `credo/`:

| Assertion | Old check | New check |
|---|---|---|
| `plugins/bundled/test/helyx/tool/read_test.exs:233` `micros < @load_us` | `<` | `<` |
| `plugins/bundled/test/helyx/watchdog/group_test.exs:91` `... - until < @load_ms` | `<` | `<` |
| `plugins/bundled/test/helyx/watchdog/group_test.exs:213` `... - until < @load_ms` | `<` | `<` |
| `test/helyx/session/hands_test.exs:155` `elapsed < 1_000 + @load_ms` | `<` | `<` |

With the margins in place, both checks report nothing in the repository, so the new check makes no new false report. `steer_test.exs:161` uses `@load_ms` in a lower bound on `:erlang.read_timer/1`, which is no time call in the check, so neither check reports it with the margin removed.

Test file: the 11 cases of `test/credo/wall_clock_upper_bound_test.exs` at `2b81e15`, with the expected counts 1, 0, 0, 12, 0, 6, 0, 2, 0, 1, 0. Both checks pass all 11. The spec reviewer compared each case by line and trigger: the same. The 2 new tests pass on both checks.

Differential: both checks over the 132 repository files, under five text mutations (as is, margins removed, every `assert ` made `refute `, every `assert ` made `assert not `, and ` < ` made ` >= ` with ` == ` made ` != `). Each file gave the same issue list from both checks: 0, 4, 5, 4, and 0 issues.

## Bounds sensor

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

(Each round: the change is not in a `lib/` directory.)

## Round 1

Simplify (four agents): a dead `time_node?/2` clause for `@` removed, the two range clauses of `bound/5` merged, and a comment on a negated `in`. Skipped: a short-circuit walk in `time?` (no measurable cost at this size), stripping `Kernel.` for every comparison (it changes behavior; the hole is accepted), and a per-caller attribute stop (most callers needed it then).

Standards: judgement calls only (positional tuples, the name `how`, `scope?/1` called twice). Not changed. It also noted that the new walker did not go below `@`.

Spec: no defect. The set is the same on both checks.

Failure path: 1 reproduced. Codex: 1 reproduced, the same defect. The walker did not go into a module attribute body, so `@generated (test ... end)`, `@x (assert ...)`, `@y (t = System.monotonic_time())` and `@c (defp now, do: System.monotonic_time())` gave no issue. The original reported each one.

Fix: `nodes/2` is a plain walk. The stop at `@` stays only where the original had it: `time?/3` and the pattern variables. A regression test asserts the 4 lines.

## Round 2 (full: a new function)

Simplify: no finding.

Standards: a comment reworded, and the regression test asserts the lines and not only a count.

Spec and failure path: no defect. The failure path probed 486 files and attribute shapes in patterns, bounds, and scopes.

Codex: 1 reproduced, a second finding on the attribute mechanism. `nodes/2` kept the attribute node where it stopped, and `time_node?/2` read it as a call to a local function named `@`. With `import Kernel, except: [@: 1]` and `def @_value, do: System.monotonic_time()`, `assert @count < 5` gave a new issue.

Fix (the mechanism, not the path): `value_nodes/1` leaves out the attribute node and its whole subtree, exactly as the original `time?` and `vars_in` did. A regression test with the Codex source. It fails on the round 2 code and passes on the original.

## Round 3 (full: a function replaced)

Simplify: no finding. Skipped: computing `value_nodes` once per binding before the fixpoint (microseconds).

Standards: judgement calls only. The rule for two findings on one mechanism applies, and the fix is at the mechanism: an attribute is opaque at the one point that `time?` and the pattern variables share. "Walk with a stop, then filter by the same predicate" occurs twice; no helper for two uses.

Spec: no defect. The reference set is the same on both checks, and the 13 tests pass on both checks.

Failure path: no defect. 26 attribute cases (a local `@` function under each bound form, `@` in patterns, sums, `assert_in_delta`, def heads, `&@/1`) and 476 files agree.

Codex: approve, 405 parsed inputs agree.

No defect reproduced, so the loop ends.

## Known differences

None found. The equality mode `:itself` keeps the original reading of `@x` as a possible local call, so a local function named `@` gives the same result in both checks.
