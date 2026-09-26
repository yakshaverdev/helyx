# Review: wall-clock bounds in the watchdog group test (#193)

Base: `origin/master` at `8b0ecc7`. Two rounds: the first and complete round, then one reduced rerun round.

## Change

Only `plugins/bundled/test/helyx/watchdog/group_test.exs` changes. `Helyx.Watchdog.Group` does not change. The fake kill(1) sends the monotonic start time of each run to the test.

- "a deadline that passes during the release stops the kill runs" counts the runs: each run takes 30 ms, so a third run would start after `deadline(50)`. It asserts at most 2 runs. The old `< 35` ms bound failed at 96 ms under load.
- "the TERM grace is 500 ms", "a longer grace waits up to its limit before the KILL", and "a KILL wait ends after 5,000 ms" keep their lower bounds (`>= 500`, `>= 1_000`, `>= 5_000`). `assert_polls_within/3` replaces the upper bounds (`700`, `1_300`, `5_300`): every probe of the wait but the last starts before the wait length after the first probe.
- "a retry KILLs every group and probes once, with no wait" asserts the exact list of runs, so a poll fails it.
- The waits that must not happen (a wait past the deadline, a retry that waits) keep a time check, the option in the ticket body "keep the time check with a bound that has room for load": `@load_ms`, 250 ms, measured from the deadline (from the start for the retry). The old bounds were 15, 100, and 300 ms.

Invariant: every changed check fails when the property it names breaks in `Helyx.Watchdog.Group.release/4`, and no changed check fails under scheduler load. Known ceiling: an overrun past the deadline, or a retry wait, below 250 ms is not caught, for example a poll sleep of 20 ms or 200 ms past `until`. A check of such an overrun needs a bound near the scheduling delay, and that bound is the flake this ticket removes.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Four agents: reuse, simplification, efficiency, altitude. No fixes.

- Skipped (simplification): `signals/1` has `runs()` as its default argument. It is a style note only.
- Skipped (altitude): replace the two `< 2_000` bounds with "every run starts before the deadline". The deadline gate in `until_deadline/2` makes that always true, so it passes when a wait ignores the deadline. A local break of the `within/2` clamp showed this.

### Standards

No hard violations. Judgement calls:

- Fixed: `assert_wait_ms/3` renamed `assert_polls_within/3`, with a clearer comment and `assert` matches in place of a bare match.
- Skipped: the shadowed name `runs = runs()`, the default argument of `signals/1`, an `elapsed_ms/1` helper, and the numbers in comments (the comments were removed with the `< 2_000` bounds).

### Spec

- Fixed: `fake_kill` read the clock after the deadline gate, so a run that the gate let through could record a time at or after the deadline under load. The test now counts the runs.
- Fixed: the KILL wait computes its end after the KILL run, so a helper anchored on the signal could fail under load. It is now anchored on the first probe, which starts after the end of every wait is computed.
- Fixed: the two `< 2_000` bounds let an overrun of 1,950 ms pass, and the retry test had no check of "no wait". Now `@load_ms` from the deadline, and a retry check.

### Failure path

- Fixed (same as the spec findings): `within/2` clamped at `deadline + 1_500` passed all tests; `Process.sleep(800)` after the retry KILL passed all tests.

## Round 2 (reduced)

Fix diff: 0 code lines (test file only). Spec and failure-path agents, briefed on the invariant, with the round 1 reproductions first.

- Spec: no findings. All reproductions fail as expected. The file passed under 30 busy loops on 10 cores, 4 of 4 runs. Not caught, within the known ceiling: a 20 ms sleep past the deadline, a fixed 20 ms poll sleep, a 200 ms retry sleep.
- Failure path: the four reproductions hold, and the file passed under `+S 1` with 24 busy processes, 4 of 4 runs. One finding, the known ceiling: `deadline + 200` in `within/2`, or a 200 ms poll sleep, passes. Not fixed: the proposed check (the last probe starts within 20 ms plus a margin of the one before) fails under load, and the deadline gate records no probe after the deadline.
