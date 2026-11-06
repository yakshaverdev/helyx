# Review: test time in the agent workflow (2026-11-06)

Scope: `/ship` step 3 (`mix test --stale` between rounds, precommit without slow tests), `/orchestrate` step 5.2, `AGENTS.md`, the comments of `precommit.sh` and the three `test_helper.exs`, and the devlog `docs/devlogs/2026-11-06-precommit-time.md`. Owner request in chat, no ticket. Base `b67f4ea2`.

Bounds sensor, round 1:

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

## Round 1 (full: simplify, standards and spec, failure-path, Codex)

Simplify: split the step 3 paragraph; found that the rebase exception of `/orchestrate` 5.2 let a `/ship` precommit without slow tests stand at the gate, and narrowed it to a precommit with the slow tests. Two of its cuts were put back: config read at run time is a miss of `--stale` (the owner's list), and a Core change can still rerun a test through a recompiled module, so "runs no test there" became "a test that calls Core directly does not run".

| # | Source | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | Codex | The added rule "a change to a slow test runs that file with `HELYX_SLOW=1` between rounds" contradicts the owner decision that only the merge gate runs slow tests. | Fixed: rule removed. |
| 2 | Codex | `test/test_helper.exs`, `apps/coding_agent/test/test_helper.exs`, `plugins/bundled/test/test_helper.exs` still say `/ship` runs the slow tests. | Fixed: they name the merge gate of `/orchestrate`. |
| 3 | Failure path, reproduced | A `mix test --stale` run without `HELYX_SLOW=1` writes the stale manifest with the slow test left out; a later `HELYX_SLOW=1 mix test --stale` prints `No stale tests` for a broken slow test (throwaway project; Mix `test.ex:103`). | Fixed: step 3 says a run without the flag records the slow test as run, and to run a slow test file by its path. |
| 4 | Failure path | Work merged outside `/orchestrate` (such as this owner-chat change) would reach master with no slow-test run. | Fixed: step 3 says such a merge runs `HELYX_SLOW=1 .claude/skills/ship/precommit.sh` first. |
| 5 | Spec | `config/runtime.exs` does not force a stale run (`loadconfig.ex` registers it with no files). | Fixed: "a Mix config file read at compile time (not `config/runtime.exs`)". |
| 6 | Spec | `/orchestrate` 5.2 says "as step 3 does"; step 3 of that list is Push. | Fixed: "section 3". |
| 7 | Spec | 5.2 does not say how a fixed branch comes back. | Fixed: the fix goes through the Codex review of section 3 again, then 5.2. |
| 8 | Failure path | A different slow failure on each pass has no cap of its own at the gate. | Not changed: each pass goes through the Codex rounds of section 3, capped at three, then park. |

Spec guarantee table (from the spec agent): every claim about `--stale` has a line in the Mix 1.19.5 source (`compilers/test.ex` 127–129, 141–144, 237–261; `project_stack.ex`; `loadconfig.ex`); the path-dependency miss and the `test/support` rerun were also probed by the failure-path agent in a throwaway project. Registration-entry and computed-module misses rest on the tracer recording only literal aliases (`code.ex:142`), with no probe. The devlog numbers match `Finished in` and `tests,` lines of the two logged runs.

Not reached in round 1: compile-time references from a path dependency that recompile modules of the dependent project; a helper reached only through config.

## Round 2 (reduced: spec, failure path)

Invariant of the fix: one consistent workflow in which only the merge gate (or the precommit before a merge outside `/orchestrate`) runs the slow tests, and every `--stale` claim matches the Mix source.

| # | Source | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | Failure path, reproduced | "Run a slow test file by its path" runs nothing: without the flag, `mix test test/s_test.exs` printed `0 tests, 0 failures (1 excluded)`. Spec agent read the same in Mix `tasks/test.ex` 930–941. | Fixed: `HELYX_SLOW=1 mix test <path>`, and the sentence no longer asks for a slow run between rounds. |
| 2 | Failure path, reproduced | An edit of a test file during a passing `--stale` run gives a false pass: the next `--stale` printed `No stale tests`, a run by path gave `1 failure`. | Fixed: step 3 says nothing may edit the worktree while `--stale` runs. |
| 3 | Spec | `AGENTS.md` says only the merge gate sets `HELYX_SLOW=1`; step 3 names the precommit before a merge outside `/orchestrate`. | Fixed: both `AGENTS.md` lines name it. |
| 4 | Spec | The devlog still said any Mix config file forces a full run. | Fixed: compile-time config only; the manifest is written only after a run with no failures. |
| 5 | Failure path, read | The gate loop has no bound when each fix breaks a different slow test. | Fixed: a second slow-test failure of the branch, of any test, parks it. |

Not reached in round 2: a rebase that brings older mtimes, a fixture with `@external_resource`, a module that only a slow test calls, a precommit on the remote host reused at the gate.

## Round 3 (reduced: spec, failure path)

The failure-path agent stopped at a usage limit of the model account and was run again on the text with the spec fixes of this round. It left `.scratch/review-failure-path-3/`, which was not deleted; the rerun worked in `.scratch/review-failure-path-3b/`.

| # | Source | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | Spec | The between-rounds paragraph still ended with an instruction to run a slow test with `HELYX_SLOW=1 mix test <path>`. | Fixed: a plain fact, "a later `HELYX_SLOW=1 mix test --stale` does not run it". |
| 2 | Spec | Step 3 says "Only the merge gate" runs the slow tests, then names the precommit before a merge outside `/orchestrate`. | Fixed: "The merge gate of `/orchestrate` runs them". |
| 3 | Spec, wording | The "Park when" list of `/orchestrate` lacks the new park rule of 5.2. | Fixed: added. |
| 4 | Failure path, read | A commit made on master itself is not a merge, so no rule runs the slow tests before it reaches master; before this change `/ship` ran them. | Fixed: step 3 and both `AGENTS.md` lines name work that reaches master outside `/orchestrate`, by a merge or by a commit on master. |
| 5 | Failure path, reproduced, wording | An edit during a passing `--stale` run hides a change also in a test file that the run did not run: the manifest time covers every file. | Fixed: "marks every test file as tested at its end". |
| 6 | Failure path, read | The rebase exception of 5.2 lets a pre-rebase precommit stand when master adds a slow test for a module that the branch changes. | Rejected: such a test is in a part that the branch touches, so the exception does not apply; the text predates this change. |

Probes of round 3 confirmed: a passing run without the flag, then `PSLOW=1 mix test --stale` printed `No stale tests` and a full run `3 tests, 1 failure`; a touch of `config/runtime.exs` gave `No stale tests`, of `config/config.exs` a full run; `precommit.sh` forwards `HELYX_SLOW` to the host.

Not reached: a host precommit with `HELYX_SLOW=1`; mtimes of files that the format step copies back; whether the Codex round count of section 3 restarts after a slow-test send-back.

Round 3 found a defect (#4), so one small-fix round follows: a Markdown fix of a few words, no code.

## Small-fix round (reduced: spec, failure path)

This round found defects. By the loop rules of `/ship`, the reviewed text is committed as it is, and these findings stay open for the owner. None of them is fixed in this commit.

| # | Source | Finding | State |
| --- | --- | --- | --- |
| 1 | Spec, read | "The perl lock holder" is not a file that is not Elixir: it is `@program` in `lib/helyx/session/lock.ex:23`, so a change recompiles `Helyx.Session.Lock` and `--stale` follows it. `watchdog.pl` is an `@external_resource` (`plugins/bundled/lib/helyx/watchdog.ex:68`), so it is followed too. The example came from the owner's brief. | Open: drop the example or name a file that no module reads at compile time. |
| 2 | Spec, read | "runs a test file only when the file reaches a changed module" (`/ship` step 3, `AGENTS.md` Commands) leaves out that `--stale` also runs a new or changed test file (Mix `compilers/test.ex` 141–150). | Open: wording. |
| 3 | Spec, read | The devlog says only the merge gate sets `HELYX_SLOW=1`; step 3 and `AGENTS.md` also name the precommit before work reaches master outside `/orchestrate`. | Open. |
| 4 | Failure path, read | `/orchestrate` 5.2: "then this step" can be read to skip the rebase of 5.1, so a branch could merge on a master that no slow run saw. | Open: "then step 1 and this step". |
| 5 | Failure path, read | The rule for work outside `/orchestrate` does not say that the slow precommit runs on the tree that lands (after a rebase), and a fast-forward push is not named. | Open. |
| 6 | Failure path, reproduced | A renamed or deleted module: `--stale` printed `No stale tests`, `mix test` printed `2 tests, 1 failure`. | Open: one more item in the list of what `--stale` misses. |
| 7 | Failure path, reproduced | Mix compares mtimes in whole seconds: an edit in the same second as the manifest write was missed in 5 of 6 runs, and the run that missed it rewrote the manifest, so it stays hidden. | Open: one more item in the list. |
| 8 | Failure path, read | Fast-test failures at 5.2 with a new cause each time have no count. | Not in scope: the text predates this change. |

Precommit, once after this round, with `HELYX_SLOW=1 .claude/skills/ship/precommit.sh`, on the host: passed. The test steps: root `839 tests, 0 failures` (49.9 s); `apps/coding_agent` `149 tests, 0 failures`, `Finished in 121.1 seconds (30.4s async, 90.6s sync)`; `plugins/bundled` `4 properties, 1179 tests, 0 failures (1 excluded)` (154.2 s). The 3 `PrintTest` failures of the local runs do not occur there.

Left on disk: `.scratch/review-failure-path-3/` of the round 3 agent that stopped at the usage limit. No probe of this work created it, so none deleted it.

Round counts: round 1 (full): 8 findings, 7 fixed, 1 not changed. Round 2 (reduced): 5, all fixed. Round 3 (reduced): 6, 5 fixed, 1 rejected. Small-fix round (reduced): 8, 7 open, 1 out of scope.

## Owner decisions on the open findings (2026-11-06)

The owner decided the seven open findings of the small-fix round. They are text fixes; by the owner's decision they get no review round, and the Codex gate follows.

| # | Decision | Change |
| --- | --- | --- |
| 1 | Drop the perl lock holder; keep only examples that were reproduced or read in the Mix source. | `/ship` step 3: the misses are a list, each with its evidence. The wire schema is dropped too (not checked). A fixture stays, qualified: missed unless a module names it in `@external_resource` (`compilers/test.ex` compares only the test file, its external resources, and the beams). |
| 2 | `--stale` also runs a new or changed test file. | `/ship` step 3 and the `AGENTS.md` Commands line. |
| 3 | The devlog matches the rules. | The devlog names both places that set `HELYX_SLOW=1`, and the new or changed test file. |
| 4 | "then step 1 and this step". | `/orchestrate` 5.2. |
| 5 | The slow precommit runs on the rebased tree that lands; a fast-forward push reaches master. | `/ship` step 3 and `AGENTS.md`. |
| 6, 7 | State both as limits in `/ship`, with the reproductions, and what a worker does. | `/ship` step 3: the two items, and "after a rename or a delete of a module, or when in doubt, run the full test files of the change; the full precommit before the commit stays the gate". |

One more correction from a probe of this follow-up, in a throwaway project: a plugin in a literal list (`def plugins, do: [P]`) was followed by `--stale` (the test ran and failed after a change of `P`); a module reached by `Module.concat(["Q"])` and `apply` was missed (`--stale` ran `1 test, 1 failure`, `mix test` gave `2 tests, 2 failures`). So the miss "a plugin resolved by its registration entry" became "a module that a test reaches only by a name that is not a literal in code, from config or computed".

