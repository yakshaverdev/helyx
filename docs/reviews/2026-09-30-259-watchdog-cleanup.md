# Review: #259, watchdog cleanup

Scope: `git diff origin/master` on `ticket/259-watchdog-cleanup`. `Helyx.Watchdog.start/4` takes only `nil` (stdin is /dev/null) or `:open` (input up to a NUL byte, under the 16 MiB cap); `Helyx.Watchdog.grace_ms/0` is the one 500 ms grace default, for the perl watchdog and for `Helyx.Watchdog.Group.release/4`; `HarnessIO.release` and `Bash.release` call `Helyx.Watchdog.Group` directly; the group poll is `@poll_ms 20`.

## Deviation from the ticket

The ticket says the watchdog tests pass unchanged apart from the test at `watchdog_test.exs:297`. Seven more tests used counted input: six launcher tests passed a byte count of 0 or more, and two tests in `watchdog/go_ahead_test.exs` passed a binary through `HarnessIO.start/5`. Four launcher tests covered only counted input and are deleted. Two test the pipe ("does not read cannot stop the kill", "closes its stdin early") and now use open input. The go-ahead tests now pass `:open`; their input is never written, because the watchdog dies before the go-ahead. The spec agent checked that every property of the none and open modes keeps a test.

## Simplify

- Simplification: `$feed` is now a mode flag with 0 for a closed input. Skipped: the ticket says to keep `$feed == 0`.
- Simplification: the history note in the feature doc row. Removed.
- Altitude: `Keyword.get_lazy` for a constant default. Changed to `Keyword.get`.
- Reuse: the harness test support uses `def`, not `defdelegate`. Skipped: that line was a `def` before.
- Efficiency: clean.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| Axis | Finding | Resolution |
|---|---|---|
| Standards | `HarnessIO.release` is a middle man (judgement call) | kept: the ticket says to point it at `Watchdog.Group` |
| Standards | `$feed` and `feed/1` name a mode, not a count (judgement call) | kept: the ticket keeps `$feed`; a rename is outside its scope |
| Standards | `Group` reads the default from `Watchdog` (judgement call) | kept: the perl watchdog needs the value too, and `Group` already depends on `Watchdog` |
| Standards | `harness_start/2` in the go-ahead test takes one value only | fixed: `:open` inlined |
| Standards | the `bash.ex` comment reads as if only `Group` is shared | fixed |
| Spec | none; the test deviation was forced, and no property lost its test | none |
| Failure path | none reproduced (probes: multibyte input, bytes after a NUL, a NUL first, a closed stdin, `nil` input) | none |
| Codex | approve, no findings | none |

No defect reproduced, so the loop ends after round 1. The fixes change one test helper and one comment.
