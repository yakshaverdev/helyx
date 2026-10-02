# Review: #303, fold the near-twin test plugins in test/support/interfaces.ex

Scope: `git diff origin/master` on `ticket/303-fold-test-plugins`. The change touches only test support and tests.

Invariant: the test plugins in `test/support/interfaces.ex` give every existing test the same events, ids, tool names, and tool behaviour as before, and no test is deleted.

Line count of `test/support/interfaces.ex`: 1,100 before, 954 after (−146). The ticket estimated about −280, ±30% (−196 to −364), so the result is under the low end. Round 3 gave back 23 lines: the tool models of `Helyx.Test.Provider` are one clause each again, because a shared dispatch caused the defects of rounds 1 and 2. The rest of the file is plugins that differ in a behaviour that a test proves (see "Kept apart").

## Folds

| Before | After | Tests changed |
|---|---|---|
| `Helyx.Test.Harness` (id `harness`) | The models `events.<name>` of `Helyx.Test.Connected` (id `conn`), from an `@events` table | `stream_events_test.exs`: `harness/<name>` becomes `conn/events.<name>`; `SessionCase` registers `Connected` in place of `Harness` |
| `Helyx.Test.ProviderTwin` (id `test`) | `Helyx.Test.BadId` with `Process.put(:bad_id, "test")` | `core_test.exs`, the duplicate id test keeps three providers and the exact error |
| `Helyx.Test.ModelContextTwin`, `Helyx.Test.CompactionTwin` | `Helyx.Test.PrepareContext`, `Helyx.Test.PrepareCompaction` as the second plugin | `core_test.exs`, the two mode tests |
| The fixed `stream/3` clauses of `Helyx.Test.Provider` | An `@fixed` table; the models that call tools keep one clause each, with the shared helpers `call/3`, `slow_calls/1`, `echo_results/1`, `echo_after/2` | none |
| `name/0`, `description/0`, `parameters/0` in nine test tools | `use Helyx.Test.Tool` | none |

Deleted tests: none.

## Kept apart

- `SingleA`/`SingleB`, `MultiA`/`MultiB`: the Core tests need distinct modules per interface.
- `ModelContext`/`Compaction` and the `Prepare*` plugins: different system text, and the mode tests need two modules per interface.
- `ProviderOther`: a second id that session processes see; `BadId` reads the caller's process dictionary.
- `Tool.UpcaseTwin`: a duplicate tool name. `Tool.HoldTwo`: one release Task per module. `Tool.HoldBare`: no `release/3`.
- `Connected` and `Provider`: a connected provider and a `Helyx.Provider.Loop` provider.

## Round 1 (full)

Bounds sensor, against `origin/master`:

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Findings | Resolution |
|---|---|---|
| Simplify | 1. `after_calls("echo", …)` used a fake model name. 2. The fixed harness events as 13 one-line clauses. 3. `done()` in `Connected`, `@done` in `Provider`. 4. The `gate.` model wrote the "ok" events again. 5. `@calls` repeats the clause heads. 6. `BadId` does two jobs. 7. `HoldTwo` repeats the description of `Hold`. 8. The tools in `gate.ex` and `boundary_test.exs` could use the macro. | 1.–4. Fixed: `echo_results/1`, the `@events` table, `@done`, `[:gate | @fixed["ok"]]`. 5.–7. Kept: small, and each is stated in the module. 8. Kept: `gate.ex` is in `test/support/shared`, and the boundary tools are outside this file. |
| Standards | No hard violation. Judgement calls: 1. The file is over 400 lines (Credo checks only `lib/`). 2. `@calls` and the clauses must stay in step. 3. The changed rule of the tool models. 4. The name `Helyx.Test.Tool`. 5. `HoldTwo` repeats a string. 6. `Connected` did not alias `ToolCall`. 7. `Process.put(:bad_id, "test")` is not explained in the test. 8. The mode tests depend on the `Prepare*` fixtures. 9. "harness events" in the test names. | 3. Fixed in round 1 spec. 6. Fixed: alias. 7. Fixed: a comment. 1., 2., 4., 5., 8., 9. Kept: the file got smaller; "harness event" is still the name of an event that only a connected provider may send. |
| Spec | 1. −186 lines, under the estimate. 2. Reproduced (with Codex): the tool models checked any message for a tool result, so the second prompt of "a tool result with invalid bytes is made valid before it reaches the session" ran no tool, and the test still passed. 3. The tool macro is shared setup, not a fold. | 1. Recorded above. 2. Fixed: `results?/2` keeps the rule of `origin/master` (the last message; any message for "abort", "stuck", "steer"), and the test now asserts the repaired result of the second turn. 3. Kept: the ticket's rules allow shared setup. |
| Failure path | 0 reproduced. All 19 harness models and 29 provider models compared against the `origin/master` modules for three contexts; the only difference was finding 2 of the spec, which the agent judged not a lost check. | None needed. |
| Codex adversarial | 1. Reproduced: as spec 2. | As spec 2. |

Round 1 reproduced one defect. The fix adds a function, so round 2 is a full round.

## Round 2 (full)

Simplify (4 agents): no finding. Bounds sensor, against `origin/master`: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

| Axis | Findings | Resolution |
|---|---|---|
| Spec and standards | 1. Reproduced (with the failure path): after a result, "kill" echoed every result text, where `origin/master` sent the text of the last message only; a second prompt gave other text. No test sends one today. 2. −175 lines, under the estimate. 3. The header said "multibyte" for two models. | 1. Fixed: `after_calls("kill", …)` sends the text of the last message, and the header says so. 2. Recorded above. 3. The header names the two models. |
| Failure path | 1. The round 1 reproduction now fails as it should (the second prompt runs the tool). 2. Reproduced: as spec 1. | 2. As spec 1. |
| Codex adversarial | Approve, no finding. | None needed. |

Round 2 reproduced one defect. It is the second finding on the rule that each tool model follows after its calls, so the mechanism is fixed: each model now has the after-call rule of `origin/master` (two agents compared all models against the `origin/master` modules). Round 3 is a full round, and it is the last.

## Round 3 (full, last)

Simplify: reuse, simplification, and efficiency found nothing new. Altitude: the shared dispatch of the tool models (`@calls`, `@echo_after_any`, `results?/2`, `calls/2`, `after_calls/2`) caused the defects of rounds 1 and 2. Fixed: each tool model is one `stream/3` clause again with the rule of `origin/master`, on the helpers `echo_after/2`, `last_result?/1`, `any_result?/1`. The simplification agent also proposed to drop the "kill" echo of the last message; kept, because it is the `origin/master` behaviour.

Bounds sensor, against `origin/master`: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

| Axis | Findings | Resolution |
|---|---|---|
| Spec and standards | 0 reproduced. 37 provider models compared against `origin/master` for 8 message lists: equal. Judgement calls: 1. The header did not state the after-call rule for each model. 2. `BadId` depends on `id/0` running in the caller. 3. `@done` in three modules. 4. The `big_int` message chain (as on `origin/master`). 5. The file is over 400 lines (it was 1,100). | 1. Fixed: the header states the default rule and each exception. 2.–5. Kept: stated in the module, small, or not new. |
| Failure path | 0 reproduced. 39 provider models over 7 contexts, 19 `events.<name>` models over 7 request kinds, `BadId`, and the nine tools compared against `origin/master`: equal. `Connected` raises on an unknown `info/2` message where `Harness` ignored it; no boundary sends one. | None needed. |
| Codex adversarial | Approve, no finding (259 provider cases, 140 harness cases, 27 tool callbacks). | None needed. |

Round 3 reproduced no defect, so the loop ends.
