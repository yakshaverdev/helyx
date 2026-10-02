# Review: #323 move the codec and branch rules out of file.ex

Scope: `lib/helyx/session/file.ex`, the new `lib/helyx/session/file/codec.ex` and `lib/helyx/session/file/branch.ex`, `.credo.exs`, and one sentence of `docs/features/coding-agent.md`.

Invariant: `Helyx.Session.File.resume/3` and `append_message/2` behave as on master. The rescue of `load/3` in the heap-capped process still catches every raise of `Codec` and `Branch`. The stop-reason atoms stay interned by compile-time clauses in `Codec`. The fork scan is still the last use of `entries`. The new modules do no I/O.

Line counts: `file.ex` 643 before, 385 after. `codec.ex` 114, `branch.ex` 169. `file.ex` is under 400, so `Resumed` stays in it and its `.credo.exs` entry is removed.

## Round 1 (full)

Bounds sensor (`--diff origin/master`):

```text
bounds sensor: 9 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Findings | Resolution |
|------|----------|------------|
| Simplify | `@spec` only on `Branch.newest/1`; the Codec comment named the private `load/3` vaguely | Removed the single `@spec` so the internal module is consistent; comment names `load/3` of `Helyx.Session.File` |
| Standards | No hard violation. Judgement: `current_model/2` and `harness_sessions/2` depend on the checked branch by call order | The Branch header comment states that the other public functions take the checked branch |
| Spec | No missing requirement, no scope creep. The comment "`entries` is not used after this" stood above its last use (as on master) | Comment now says that the fork scan is the last use of `entries` |
| Failure path | No reproduced defect. A multiset compare of removed and added lines shows only the renames, aliases, and comments | None |
| Codex adversarial | Approve, no material findings | None |

The round reproduced no defect, so the loop ends.
