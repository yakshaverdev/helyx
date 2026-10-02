# 2026-10-02: one set of cell rules in the TUI (#305)

## Done

- The owner decided to show the closed cell in both paths. The live fold now gives a result with no open cell to its call in the last assistant message, as a closed cell. `tool_cell/2` makes every tool cell in both paths.
- ADR 0006, section 3: the "Accepted limit" bullet is removed, with a revision note. `docs/features/session-snapshot.md` states the new rule.
- Tests: the dangling connected turn and a new abort of three local calls compare the full live fold with a snapshot at the same `seq`. The second-client abort test drops its accepted-difference helper.
- `view_model.ex` is at 400 lines, and its `.credo.exs` entry is gone.

## Broke

Nothing. One review round, no reproduced defect (`docs/reviews/2026-10-02-305-tui-cell-rules.md`).

## Next

- The file is at the limit: the next change to `view_model.ex` needs a split or a new entry.
