# Review: one scratch folder for each review agent (#784)

Scope: the working tree against the branch base `99e6e578`. Markdown only: `.claude/skills/ship/SKILL.md` and this record. A rule for agents, so `/ship` runs the Codex review only (no simplify, no agent axes, no bounds sensor: no `lib/` change).

Invariant: every review agent that writes throwaway files gets its own folder `.scratch/review-<role>-<round>/`, which its brief names with the round number filled in; the agent makes the folder and deletes only that folder at its end, and no brief in `.claude/skills` or `docs/agents` names a shared review folder.

Only the failure-path brief of `/ship` named the shared folder. `/orchestrate` and `docs/agents/` did not, so they stay as they are. The acceptance grep, `grep -rn "scratch/review" .claude/skills docs/agents`, shows only `review-failure-path-<round>/`, `review-<role>-<round>/`, and `review-failure-path-2/`.

## Round 1

Codex (`--scope working-tree`): approve, no material findings. Not checked by Codex: a live run of agents that follow the brief.

Round 1 reproduced no defect, so the loop ended.

Precommit (`HELYX_SLOW=1 .claude/skills/ship/precommit.sh`): passed. Root 758 tests, 0 failures; `apps/coding_agent` 82 tests, 0 failures; `plugins/bundled` 4 properties, 1043 tests, 0 failures (1 excluded); Dialyzer 0 errors in each project.
