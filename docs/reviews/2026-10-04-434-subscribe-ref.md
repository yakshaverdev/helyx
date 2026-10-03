# Review: #434, subscribe returns the caller's monitor ref

Invariant: `Helyx.Session.subscribe/1` returns `{:ok, snapshot, ref}`, where `ref` is the caller's monitor of the session pid that answered the snapshot, made before the call, so the caller gets one `{:DOWN, ref, :process, pid, reason}` after the last event; a failed subscribe leaves no monitor and no subscription of the caller. Accepted hole: a failed subscribe also ends an earlier subscription of the same caller, whose ref stays with the caller.

## Round 1 (full)

Bounds sensor: `bounds sensor: 3 candidate functions, 0 flagged, 0 without an answer`

Simplify: one fix (a moduledoc comment line reflowed). Skipped: a test helper for the subscribe-then-demonitor pattern (three uses, small).

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | ADR 0006 exception for `ref` must say that a remote transport does not send it | fixed |
| Standards | `end-signal.md` lost its "Out of scope" section | fixed |
| Spec | `end-signal.md` kept one history sentence | fixed |
| Spec | `session-instance.md` still described the flush by id and #216 as open | fixed |
| Spec | `session-subscribers.md` banner did not name Q2, the tag, the dictionary, and `Helyx.Session.Subscription` | fixed |
| Spec | the deleted tests are not listed | listed in the commit message |
| Failure path | a second subscribe that times out ends the first subscription, and the first ref stays (reproduced) | the accepted hole of the invariant, stated in `end-signal.md`; now also in the `subscribe/1` @doc |
| Codex | approve, no findings | none |

No defect reproduced outside the accepted hole, so the loop ends after round 1.
