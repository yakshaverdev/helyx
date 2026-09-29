# Review: Claude background tasks outlive the turn (#194)

Scope: the rule in the Ownership row "the harness's own command groups" of `docs/features/long-lived-harness.md`, a "Built in #194" section, a research line in `docs/research/claude-code-stream-json.md`, and the test `plugins/bundled/test/helyx/provider/claude_code_real_test.exs` with the tag `:real_claude`, which `test_helper.exs` excludes. No production code changed.

Invariant: a Claude background task belongs to the harness program, not to the turn. It survives `Session.abort/1` and the turn end, and it ends when the program ends: the close at the session end or at a model switch, a stop after a failed interrupt or another error, or a crash of Helyx. Accepted hole: a KILL after the TERM grace leaves command groups running (Ownership row). Open hole: no idle close yet (#195).

## Simplify

Four agents. Reuse: `collect_until/2` repeats the helper of `claude_code_test.exs`; skipped, because the timeout differs (120 s against 5 s) and a shared helper would change files outside the diff. Altitude: the tag fact is written three times; skipped as cosmetic. Simplification and efficiency: clean.

## Round 1 (full)

Bounds sensor output, as printed:

```
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

- Codex adversarial review: approve, no material findings. The first run stalled and was cancelled; the rerun in the foreground finished.
- Standards: no hard violation. Judgement calls on the poll bounds and `:sys.get_state` follow the idiom of the existing tests; no change.
- Spec: no reproduced defect. Doc findings, fixed: the row named only the close, a provider switch, and a crash, but the program also ends at a model switch (`close_or_start/1` closes on any model change) and on a stop after a failed interrupt or another error. The row now names them. The research line said "no TERM was sent"; `release/3` still TERMs the group after the exit, so it now says "no TERM reached the program before it exited", and "the program ended it" is marked as inferred, because the test did not check the process group of the background command.
- Failure path: no reproduced defect. A Core stop during a turn ended both commands, so a failed run of the test leaves no sleeping python. Doc finding, fixed: the row stated the idle close skip of #195 as present behaviour; it is now a rule for #195. Not reached: a provider switch and a crash of the BEAM while a background task runs, an abort before the background task starts, and repeated runs for model flakiness.

No round reproduced a defect, so the loop ended after round 1.

## Real runs

`claude` 2.1.283, `haiku`: the test passed in 5 runs (3 by the author, 1 by the spec agent, 1 by the failure-path agent). In 2 timed runs the session close took 615 and 628 ms.

## Precommit

Failed twice on one test that this change does not touch: "input over the watchdog stdin cap stops the program group and fails the turn" (`plugins/bundled/test/helyx/watchdog/harness_stop_test.exs:64`) got `:harness_timeout` in place of `{:harness_stop, _}`. The file passed 5 of 5 runs alone. The full `plugins/bundled` suite without this change (the new test removed, `test_helper.exs` as on master) failed the same test in 2 of 2 runs, so the failure is on the base `2210e3a`. The root project passed (format, compile, Credo, Dialyzer, 267 tests), and `plugins/bundled` passed format, compile, and Dialyzer. The run stopped at the `plugins/bundled` tests, so the apps were not reached.
