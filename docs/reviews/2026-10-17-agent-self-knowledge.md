# Review: agent self-knowledge (#470)

Scope: the docs and session sections of `Helyx.ModelContext.Default`, the `:model` and `:session_dir` opts that `TurnLoop.prepare/1` passes, and `docs/features/agent-self-knowledge.md`. Base: `c0ed3692` (the branch base; `origin/master` moved during the work).

Bounds sensor, every round: `bounds sensor: 5 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full)

Simplify: four agents. Applied: `docs_section` as a heredoc, `line/2` as a `do` block, the topic map rendered at compile time, the magic count in the map test removed. Skipped: drop the three derived docs paths and move the map to Markdown (the ticket decision asks for both); a switch to turn the docs block off (no second product registers `Default` yet).

| Finding | Source | Resolution |
| --- | --- | --- |
| A relative `:sessions_dir` gives a relative session directory | Codex | fixed: Core made the path absolute; regression test with a relative `:sessions_dir` |
| U+2028, U+2029, NEL, VT, FF stay in a value, so a value can add lines | failure path, reproduced | fixed: `~r/\R/u`; test with each line break |
| No test at the 4,096-byte bound, one under, one over, multibyte | spec, standards | fixed: three tests |
| No test for `not saved` after a write failure | standards | fixed: integration test |
| "They go only to `build/2`" is false: `compact/2` gets the same opts | spec | fixed in the feature doc |
| Prompt stability left out a README that appears or goes away | standards | fixed in the feature doc |
| The context-file headings keep their raw path | failure path | accepted, pre-existing; stated in the feature doc |
| `__DIR__` of a copy under `deps/` points at the host project | spec | accepted; stated in the feature doc |
| The cap of the model value duplicates `ModelRef.parse/1` | failure path | kept: one render rule for all values |

## Round 2 (full: two code files, a function removed)

Simplify: two agents, nothing applied (the multibyte test stays, the checklist asks for it). The spec and failure-path agents died at the account session limit ("You've hit your session limit"); round 3 ran them again over the fixed code.

| Finding | Source | Resolution |
| --- | --- | --- |
| A `:sessions_dir` with invalid UTF-8 makes the `\R` regex raise, so every turn fails | Codex, standards | fixed: the cap runs first and drops invalid UTF-8; test |
| `Path.expand` expands `~`, the file writer does not | Codex | fixed: `Path.absname/1` |
| No test that the session section holds exactly four values | standards | fixed: exact equality of the section |

## Round 3 (full: two code files)

Simplify: one agent; four redundant asserts removed.

| Finding | Source | Resolution |
| --- | --- | --- |
| `Path.absname/1` calls `File.cwd!/0` in the session process, outside the prepare Task. With a relative `:sessions_dir` and a removed node working directory, a relative write still lands and the next prepare crashes the session | Codex, spec; reproduced on macOS (relative write `:ok`, `Path.absname` raises `File.Error` `:enoent`) | **open**. Third finding on the resolution of `:session_dir`, so `/ship` allows no small-fix round. Proposed fix of the mechanism: Core passes `Path.dirname(state.file.path)` as it holds it (a pure string operation), and `Default` makes it absolute inside the prepare Task, where a raise fails only the turn |
| The `Default` moduledoc names the old order (line breaks, then the cap) | standards, spec | open, wording |
| "The system prompt is the same for the turns of one session" leaves out an edit of a context file | standards | open, wording |
| No test tells `Path.absname` from `Path.expand` (a `~` path) | standards | open; probe only |
| No test that the new opts do not reach the provider process | spec | open; code read (`turn_loop.ex:195`) |
| The user story shows `~/.helyx/...`, the section shows the absolute path | spec | open, wording |

The loop stopped at the limit of `/ship`: round 3 reproduced a defect, and its fix is not a small fix (two code files, a repeat finding on one mechanism). The commit holds the code of round 3, which was the last code reviewed.
