# 2026-10-17: agent self-knowledge (#470)

## Done

- Feature doc `docs/features/agent-self-knowledge.md`.
- `Helyx.ModelContext.Default` adds a docs section (the Helyx root from `__DIR__`, the paths of the README and the docs folders, a topic map) and a session section (cwd, model ref, session id, session directory) between the base prompt and the context files. Each value is one line of at most 4,096 bytes.
- Core passes `:model` and `:session_dir` to `build/2` and `compact/2`.
- The stale "Known debt" of `context-files.md` is deleted: since #651 the harness providers use the system prompt.

## What broke

- The account session limit stopped two review agents in round 2; round 3 ran them again.
- Review round 3 found that `Path.absname/1` in the session process raises when the node working directory is removed and `:sessions_dir` is relative. It is open: see `docs/reviews/2026-10-17-agent-self-knowledge.md`.

## Next

- Move the resolution of `:session_dir` into the prepare Task (the proposed fix in the review record), with a regression test.
- The wording findings of round 3.
