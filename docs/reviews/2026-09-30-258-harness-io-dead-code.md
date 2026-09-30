# Review: #258, the dead exit-wait code of `Helyx.HarnessIO`

Scope: `git diff origin/master` on `ticket/258-harness-io-dead-code` (base `751af90`). The change deletes `@exit_wait_ms`, `drain/1`, `arm_exit_wait/2`, `wait/1`, `remaining/1`, and `overdue?/1`, and the `deadline` and `done?` fields with every write of them. No production code read them. `HarnessIO.start/5`, `HarnessIO.lines/3`, and the two providers set the same `terminal` values as before.

## Simplify

- Reuse, efficiency, altitude: no findings.
- Simplification and altitude: the "Harness exit wait" row of `docs/features/coding-agent.md` and ADR 0005 still described the deleted wait. Fixed: the row says "None" and names what bounds each path, and ADR 0005 has a revision line for #258.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| Axis | Finding | Resolution |
|---|---|---|
| Standards | the doc row names `start/5`, and the test calls `start/4` (judgement call) | kept: the ticket and the code comments name the function as `start/5` |
| Standards | the Claude Code State comment lists the terminal as `:lost` or a line over the cap, and omits a program that did not start (older) | fixed in the comment |
| Standards | `start/5` has two near-identical `{:not_started, _}` branches (judgement call) | kept: two lines, different ports |
| Standards | the run state is a shared map shape, not a struct (older, judgement call) | kept: outside the ticket |
| Spec | the doc row's last column named only the close of the harness loop; a program that did not start never reaches it | fixed: the port closes when the harness process ends with the start error |
| Spec | the ADR line does not name the removed fields (optional) | kept |
| Failure path | no findings; no readers of the removed fields or functions remain; 170 tests of the three affected files pass | none |
| Codex | approve, no findings | none |

No code defect reproduced, so the loop ends after round 1. The fixes are a comment and Markdown only.
