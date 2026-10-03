# Review: #428, run/1 stops the Core it started

Branch `ticket/428-run-lifecycle`, base `origin/master` `10b0775`.

Invariant: `CodingAgent.run/1` stops the Core it started with `Supervisor.stop/1` in a `try/after` on every exit after a successful Core start: a failed `start_session/1`, the normal return of `Helyx.TUI.run/1`, and a raise, throw, or exit in the TUI; `Helyx.Session.abort/1` runs in an inner `after` before that stop whenever a session started, so the hands kill and wait for the shell process groups first; no `Helyx.Core` process is left in the node when `run/1` returns or raises; a failed Core start returns before any Core exists. Accepted: a failure of the stop itself replaces the original raise, and an exit signal to the caller from its link to Core is not handled.

## Scope

The ticket asked for a stop on a failed session start and on the normal end. The orchestrator widened it before review: a TUI that raises or exits also stops the Core, with the abort first. So both the stop and the abort are in an `after`.

## Round 1 (full)

Simplify: four agents, run again after the scope change. All clean. Noted, not applied: a `case` in place of the one-clause `with` (cosmetic); a model ref check before the Core start (saves one Core start on a bad CLI call, not asked for).

Bounds sensor:

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Finding | Resolution |
| --- | --- | --- |
| Codex | Verdict approve, no findings. In-memory checks of session failure, TUI return, raise, throw, exit, and a failed Core start; the abort precedes the stop | none |
| Failure path | No defect reproduced. Probed through `run/1`: a bad model ref, a multibyte model ref of 100,000 characters, a resume with no saved session, a session that starts and a TUI that fails with no terminal, and a Core name already taken (the first Core stays alive). Not reached: a TUI that raises, a Core that dies while the TUI start traps exits, a stuck process group at quit | none |
| Standards | The new test starts Core under the global name `Helyx.Core` in an `async: true` module | Kept: no other async test uses the name, and the comment says so. The other two modules of the app are `async: false` and run after the async ones. A `name:` option is out of scope ("No new option") |
| Standards | The moved abort comment keeps a ticket reference | Kept: the text only moved |
| Spec | No test of the TUI path or a TUI raise | Kept: the TUI cannot be made to raise without a new option. The failure-path probe reached the TUI return path |
| Spec | The waits table has no row for the `Supervisor.stop/1` wait | Fixed: a row in `docs/features/coding-agent.md` states the `:infinity` timeout, the order after the abort, and the 30,000 ms shutdown bound of each session |

Round 1 reproduced no defect, so the loop ends.
