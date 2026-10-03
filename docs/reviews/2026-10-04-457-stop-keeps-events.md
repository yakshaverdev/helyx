# Review: a stop keeps the events of its read (#457)

Date: 2026-10-04. Base: `origin/master` 475581b. Owner decision: option 2, `info/2` may return `{:stop, reason, actions, state}`.

Invariant: the events that a harness provider decoded from one stdout read before the line that ends the turn reach the session, in order, before the provider process stops; a stop that `act/2` returns for one of those actions wins.

## Bounds sensor

```text
bounds sensor: 1 candidate functions, 1 flagged, 0 without an answer
  lib/helyx/session/provider_process.ex:71  SIZE+WAIT  defp loop(proc) do
```

The failure-path agent attacked `loop/1` first (actions that are not a list, an improper list, a terminal then a late delta, an error event): each took the generic failure path. The change adds no read, buffer, or wait: the actions come from one read, which the line cap of `HarnessIO.lines/3` already bounds.

## Simplify

- Altitude: the failed relaunch of Claude Code (`relaunch/2`) dropped the decoded actions the same way. Fixed with the same one-line change.
- Codex `stop/2` repeats the body of `actions/1`; the 3-tuple stop is now `{:stop, r, [], s}`. Skipped: each is optional, and the owner decision keeps both stop shapes.

## Round 1 (full)

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | `done` in `ProviderProcess.stop/2` names a result of `act/2` | Renamed `result`. |
| Standards | The moduledoc of `Helyx.Provider` described the mechanism of the process | Cut to "takes the actions, then stops"; the next sentence already says that a malformed action stops the process. The mechanism stays in `one-provider-path.md`. |
| Standards | Ticket number in a Codex comment | Removed. |
| Standards | Duplicate body in Codex `stop/2`; two stop shapes | Judgement, skipped (see Simplify). |
| Spec | No test of a reply in the actions of a stop | Judgement, skipped: the actions go through the same `act/2` as an `:ok` return, which the reply tests cover. Codex checked replies in memory. |
| Spec | `relaunch/2` change is beyond "one line in each provider" | In scope: the same defect on the same read. It has no test: a failed relaunch needs a launch that fails after a start. |
| Spec | The `go` wait of the #455 test may be unneeded | Kept: it changes no behaviour, and the test still checks the same properties. |
| Failure path | None reproduced | Not reached: a stop whose actions reply to an open close (by reading, `:closed` wins, as the early-stop rule says); the one-read claim measured only on macOS. Each new provider test fails without the fix: Codex 3 of 3 runs, Claude Code 4 of 4 cases in 2 runs. |
| Codex adversarial | Approve, no material findings | None. |

No defect was reproduced, so the loop ends after round 1.
