# Review: the stdin cap test of the harness stop races the turn deadline (#228)

Base: `origin/master` at `f61ced3`. One round, the first and complete round. It reproduced no defect, so no rerun round.

## Cause

`Helyx.Session.Harness.request/3` arms `:timer.kill_after` on the turn until the provider callback returns. The `flood` callback of `WatchdogHarness` returns only after `Port.command/2` of 32 MiB, and the command returns only after the watchdog stops at the 16 MiB cap. `start/2` set the turn deadline to 300 ms for all four tests. A probe that timed the write measured 266 to 296 ms with the file alone, and the failure-path agent measured 348 to 393 ms from the prompt to `agent_end`. Thus the kill often fired first, and the turn failed with `:harness_timeout`. Before the fix, the full suite failed 1 of 1, and the file alone failed 1 of 1 at a load average of 22. Lib code has no defect: the kill is the documented turn bound.

## Change

`start/3` takes the turn deadline, with a default of 60 s. Only the "block" test passes 300 ms, because it tests the armed kill. The comment states the margin: the 5 s wait of `agent_end/0` is now the bound for the flood test, more than 10 times the measured time.

Invariant: in the tests other than "block", the turn deadline never ends the turn, so no wall-clock race between the deadline and the cap stop, the idle reply, or the Core stop decides the outcome.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Four agents: reuse, simplification, efficiency, altitude. One fix: a shorter comment (simplification). The others found nothing.

### Standards

Two wording findings, fixed: the comment did not state the margin of the 5 s wait, and its text was not ASD-STE100.

### Spec

No findings. The "idle" and "hang" tests had the same 300 ms deadline; the diff removes it, and their assertions do not change. `WatchdogHarness` needs no change. `group_gone_within?(group, 300)` polls for more than 3 s and is a liveness wait, not the same race.

### Failure path

No reproduced defect. The file alone passed 6 of 6, and the full suite passed once. Not reached: a stopped watchdog (SIGSTOP), which fails with "no agent_end" after 5 s by the test's own wait.

### Codex

Verdict: approve. No material findings.
