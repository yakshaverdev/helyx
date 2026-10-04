# Review: an animated busy indicator with the turn time (#468)

Date: 2026-10-04. Base: `origin/master` ac6eff9.

Invariant: while a turn runs (`vm.running?` after each session event in `Helyx.TUI.handle_info/2` and at `mount/1`), `Helyx.TUI.subscriptions/1` declares exactly one ExRatatui interval subscription, id `:busy`, at 100 ms, and it declares none while idle. The status bar shows a braille frame and the whole seconds since this client saw the turn start. Accepted hole: events and the snapshot carry no time, so a client that mounts during a turn counts from the mount. Accepted cost: each tick renders the whole frame.

## Bounds sensor

```text
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

## Simplify

- Reuse: the hand-made timer (`:erlang.start_timer/3`, re-arm, cancel, stale-tick check) duplicated `ExRatatui.Subscription.interval/3`, which the callback runtime reconciles by id after each transition and whose stale ticks it drops by token. Fixed: `subscriptions/1` replaces the timer code.
- Simplification: `busy/1` had the name of the state field. Renamed to `sync_busy/1`. The frames are a tuple. The spinner regex is one helper in the tests.
- Efficiency: each tick renders the transcript too, not only the status line. Kept; the bounds row states the cost. Caching the transcript widget would change shared TUI code, which other open tickets change now.
- Altitude: clean. The doc now states the render cost.
- Skipped: Throbber widget (needs its own layout area); derive `elapsed` at render (render would read the clock).

## Round 1 (full)

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | Test helper `event/3` duplicated `fold/3` | Fixed: the busy tests call `fold/3`. |
| Standards | The runtime test matched the private tick message of ExRatatui | Fixed: the test traces the call `TUI.handle_info(:busy_tick, _)`. |
| Standards | No test pinned the frame index | Fixed: frames at 0, 900, 1,000 and 12,300 ms. |
| Standards | `busy` is a bare map with a known shape | Kept: private, two fields, nil while idle. |
| Spec | No test proved that the frame changes | Fixed, as above. |
| Spec | Requirements, scope, late-client choice, bounds row | No finding. |
| Failure path | Stale tick after `turn_end`, re-arm, every writer of `running?`, abort then a new turn at once | No defect reproduced. |
| Codex adversarial | Approve, no material findings | None. |

Not reached: a live test of a stale tick queued after `turn_end` (shown from the token code instead); the render cost with a long transcript. The failure-path agent saw `Session.abort` give no `turn_end` for 15 s while the TUI process was suspended. That path is outside this diff and was not followed.

No defect was reproduced, so the loop ends after round 1. The round 1 fixes are in test files only.
