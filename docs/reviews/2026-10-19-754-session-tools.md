# Review: Claude Code programs with no commands (#754)

Scope: the working tree against the branch base `46bdbf8b`. Code: `Helyx.Provider.ClaudeCode`, `ClaudeCode.Program`, `ClaudeCode.State`, and three test files. Docs: `docs/features/provider-parity.md`, `long-lived-harness.md`, `harness-compaction.md`, `docs/research/provider-parity.md`, ADR 0002.

Invariant: every Claude Code program that takes a model turn (a turn's `Program.ensure/3`, a prompt relaunch, the lost-session relaunch) launches with `--disable-slash-commands`; only the program of a compaction launches without it, because the flag also takes out `/compact`, and it resumes the same harness session with the same prompt; the next turn replaces it. The flag is not in the stored id's digest. Accepted holes, named limits in ADR 0002: a line whose first word is a built-in command name gets the program's fixed answer with no model call, and the turn ends `done` with no text; a skill name reaches the model after a program reminder; the Codex tools stay.

Deviation from the triage ("the flag is always on, with no option"): the probe showed that the flag takes out `/compact`, which the Claude Code compaction sends, and that no control request compacts. So the compaction's program has no flag. Only Helyx's own `/compact <instructions>` line reaches it: Core queues a steer during a compaction (`lib/helyx/session/server/steering.ex:88`). The spec reviewer judged this to keep the triage decision in spirit.

## Round 1 (full)

Simplify: one change, the format split of the `flags` line in `Program.start/2`.

Bounds sensor: `bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer`.

Codex (`--scope working-tree`): approve, no material findings. Not checked by Codex: a real Claude Code run, OS exit timing, precommit.

Failure path: no defect reproduced. Probes with the fake `claude`: three cycles of turn, compaction, turn (7 programs) left one command and one watchdog handle held; an old program that does not exit gives `{:error, :program_not_ended}` for `:compact` too, and the next prompt works; an abort of a compaction, then a prompt, runs in a new program with the flag; a lost session after a compaction relaunches with the flag; two compactions in a row keep the program. Not reached (needs the real program): the line shape of the fixed answer (the spec reviewer reran it, see below), a replay of an old `/` line, the cost mark over more resumes.

Spec and standards findings, and their resolution:

| # | Finding | Resolution |
| --- | --- | --- |
| 1 | No "Replaced mechanism" row for "a compaction keeps the running program" (standards, spec) | fixed: row added in `provider-parity.md` |
| 2 | Ownership cell "n/a: the relaunch is at a turn start" is false for a compaction relaunch | fixed: "at the start of a turn or a compaction" |
| 3 | "every program that takes a turn" conflicts with the compaction turn | fixed: "a model turn" in `provider-parity.md` and ADR 0002 |
| 4 | "another name reaches the model" is wider than the probe (only `/code-review`) | fixed: "a skill name such as `/code-review`" in ADR 0002 and `long-lived-harness.md` |
| 5 | Codex: `model_catalog_json` is a candidate key that the note did not name; "no config key removes them" is not proven | fixed: the research note names it as not tried and open; the feature docs and ADR 0002 say so |
| 6 | "The turn ends `done` with no text" for `/init` has no Helyx test | the spec reviewer reran the real program in the network sandbox: `command_lifecycle` `started`, an `assistant` line, a `result` with `is_error` false and `queued_turn_count` 0; with `turn.ex:91-104` that is `done` with no text. Added to the research note. No fake test: open |
| 7 | `compact_test.exs` "same prompt" assertion compares `""` with `""`, so it cannot fail | open: the prompt code is `state.system`, as on master; a test with a non-empty prompt is not added (time limit) |
| 8 | "A session stored before #754 is resumed" has no test that pins the digest | accepted: the diff does not change `@flags`, which is the only input of the digest; a literal digest in a test breaks at every flag change |
| 9 | The clause `program(%State{resume: nil, sent?: false}, :compact, _)` changes a case with no test (after a close of a fresh session) | kept: it is the same condition as the no-history clause of `write_turn/1`, so a compaction never launches a program to compact nothing; the failure-path reviewer probed two compactions in a row |
| 10 | The new comments in `program/3` and `start/2` give reasons | rejected: they state which program has the flag and why the digest leaves it out, at the lines that do it, as the comments around them do |
| 11 | Smells: the boolean argument of `ensure/3`, the name `commands?`, the `after_cut` assertion no longer depends on `reconnect?` | rejected: `commands?` names the state field that the clause matches; the program commands are the term of the docs; both paths of `after_cut` now resume in program 3, and the reconnect path still differs by its provider process |

Round 1 reproduced no defect, so the loop ended. The fixes after it are Markdown, and one comment: precommit failed on `Helyx.Credo.FileLength` (`claude_code.ex` had 508 lines, over the 507 of `.credo.exs`), so the comment above `program/3` went from six lines to five with the same content. No code changed after round 1.

Precommit (`HELYX_SLOW=1 .claude/skills/ship/precommit.sh`), first run: failed on that Credo check only. Root 766 tests, 0 failures; `apps/coding_agent` 82 tests, 0 failures; `plugins/bundled` 4 properties, 1044 tests, 0 failures (1 excluded); Dialyzer 0 errors in each project.

Second run, after the comment fix: passed. Credo found no issues; root 766 tests, 0 failures; `apps/coding_agent` 82 tests, 0 failures; `plugins/bundled` 4 properties, 1044 tests, 0 failures (1 excluded); Dialyzer 0 errors in each project.

Open: a fake test for the fixed answer of a built-in command name (finding 6), a test with a non-empty prompt for the compaction's prompt (finding 7), and whether a `model_catalog_json` catalog removes a Codex tool (finding 5).

## Finding 7: the compaction's prompt (orchestrator, 2026-10-19)

The orchestrator accepted the compaction design and asked for finding 7 to be fixed before the merge: a real prompt, a proof that the test fails when the compaction's program gets another prompt, and a name that says what the test proves. Test-only change, base `bd2c53b1`.

The compaction test of `compact_test.exs` now drives the provider at `ClaudeCode.request/3`, as `prompt_test.exs` does, with the prompt "Be brief." on the turn before the compaction.

### Round 2 (reduced: spec, failure path)

| # | Finding | Resolution |
| --- | --- | --- |
| 12 | Turns 1 and 3 had the same prompt, so a turn after a compaction that takes `state.system \|\| context.system` passed (both reviewers reproduced it) | fixed: turn 3 has "Be long.", and the test asserts `["Be brief.", "Be brief.", "Be long."]` |
| 13 | No test pins `--disable-slash-commands` on the lost-session relaunch: `Program.replace/2` with a default `commands?: true` passed | fixed: `turn_test.exs`, the lost-session test, asserts the flag on program 3 |
| 14 | The name said "the turn's prompt", but a compaction has no turn context | fixed: "a compaction's program has the running program's prompt, no --disable-slash-commands, and its session; the next turn's has its own prompt and the flag" |
| 15 | A line was not formatted | fixed: `mix format` |

Mutations of lib code, each restored at once (`git diff bd2c53b1 -- plugins/bundled/lib` is empty):

- The compaction's program gets `""`: the test failed, `left: ["Be brief.", "", "Be long."]`.
- A turn takes `state.system || context.system`: the test failed, `left: ["Be brief.", "Be brief.", "Be brief."]`.
- `Program.replace/2` keeps `commands?: true` by default: the lost-session test failed at `assert "--disable-slash-commands" in args(bin, 3)`.

### Round 3 (reduced: spec, failure path)

Both reviewers ran the three mutations above, in renamed copies, and each failed a test. 20 repeats of each changed test and 10 runs of both files gave 0 failures. They reproduced two gaps; the code passed their scratch tests:

| # | Finding | Resolution |
| --- | --- | --- |
| 16 | A turn after a compaction with the same prompt: no assertion shows that it gets a new program with the flag. A mutation of `Program.ensure/3` that reuses the compaction's program for a turn passes the compaction test; only timeouts of three cost tests catch it (no script for a second line in program 2) | open: the second finding on the turn step of one test (after 12), so the small-fix round of `/ship` does not apply. Proposed fix: run the test twice, with "Be brief." and with "Be long." as the third prompt, each with the full assertions |
| 17 | The prompt of the lost-session relaunch has no test: `relaunch/2` with `Program.start(fresh, "")` passes | open, not of this ticket: `relaunch/2` comes from #651 and the diff does not change it |
| 18 | A prompt relaunch (`prompt_test.exs:25`) does not assert the flag on program 2 | open, minor |

Round 3 is the last round. The commit holds the state that round 3 reviewed.

Precommit (`HELYX_SLOW=1 .claude/skills/ship/precommit.sh`): passed. Credo found no issues; root 766 tests, 0 failures; `apps/coding_agent` 82 tests, 0 failures; `plugins/bundled` 4 properties, 1044 tests, 0 failures (1 excluded); Dialyzer 0 errors in each project.
