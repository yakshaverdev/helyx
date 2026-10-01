# Review: harness replies carry their kind (#287)

Date: 2026-10-01. Base: `origin/master` at `7e234e6`. Scope: `lib/helyx/session/harness.ex`, `server.ex`, `turn.ex`, `queues.ex`, `session.ex`, the tests that call `:snapshot` and `Queues.push/4`, and `docs/features/long-lived-harness.md`.

## Invariant

Every harness reply is `{:harness_reply, from, kind, value}`. `Session.Server` routes each kind by pattern, with one clause for each state that the reply can arrive in (a turn or a wait; the two never exist at the same time). A clause acts only when its stored ref matches (`turn.pending`, `turn.start`, `turn.steers`, `turn.results`, `wait.reply`, `wait.idle`, `wait.steers`, `wait.results`). A wait ends only when `hands`, `reply`, and `harness` are nil and `steers` and `results` are empty. Empty `steers` and `results` alone never end it.

Accepted changes:

- The tool start and tool result requests of an ended turn are in `Wait.results`, not in `Wait.steers` (N7). So they no longer count as held steers during the wait. The turn did not count them before, and the bounds table of the feature doc counts only steers.
- A stale tool reply in a wait runs `progress/1`, which changes nothing in a wait at rest.
- A normal turn end builds its wait and runs `progress/1`. A wait with nothing open settles at once, as the direct `settle/1` did.
- The S5 item "the `queues` closure argument" has no work left: an earlier commit removed it.

## Round 1 (full)

Bounds sensor: `bounds sensor: 9 candidate functions, 0 flagged, 0 without an answer`.

Simplify (4 agents): the three wait sites built the same fields, and the normal end repeated the "nothing open" test of `progress/1`. Fixed: `end_requests/2` returns the wait fields, and the normal end runs `wait |> progress`. Skipped: a reply helper for the five `send` calls in the loop (small, and the literal kinds are clear).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 0 hard, 6 judgement calls | 0 | The `wait/2` comment is clearer. The names `results` and `end_requests` stay; the missing membership guard on the tool reply clauses is harmless (see above). |
| Spec | 0 missing, 2 partial, 2 out of scope, 2 nits | 0 | The feature doc no longer says that tool requests wait "as an open steer request does". `server.ex` grew by about 48 lines (longer comments, the `results` field), against the review estimate of −20 to −30. |
| Failure path | 0 | 0 | Two scratch probes (an abort and a crash with the start ask open) passed. Not reached: the `apps/` and `plugins/bundled` suites (run in precommit), a normal end with the harness suspended during the ask. |
| Codex adversarial | 0 | 0 | Approve. |

No round reproduced a defect, so the loop ends after round 1.

## Open

- No test checks that an open tool request in a wait leaves room for one more steer (the N7 change of `held/1`).
