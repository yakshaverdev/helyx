---
name: ship
description: The only way to commit in this repo. Simplify, review on three axes, run precommit, then commit.
---

# Ship

Every commit goes through this skill. Run the steps in order. The only exemption: a change that touches nothing but Markdown skips steps 1 and 2. There is no diff-size exemption and no reviewed-by-hand path; a one-line code fix gets the same first round as a feature. Only a rerun round after a review fix is smaller, see step 2.

## 1. Simplify

Invoke `/simplify` on the working tree changes. Apply its fixes. Simplify is bug-blind by design, so anything it touches is reviewed again in step 2.

## 2. Review on three axes

Invoke `/mattpocock-skills:code-review` for the standards and spec axes.

- **Standards** covers only what Credo and Dialyzer cannot: naming, the AGENTS.md rules, and the smell baseline. Do not have it re-check style that `mix precommit` enforces.
- **Spec** checks the diff against the ticket and the feature doc, including the bounds table and the research citations (see `docs/agents/review-checklist.md`, "Specs and bounds").

Before you spawn the reviewers, run the bounds sensor with the same base the reviewers get for this round: `origin/master` in a first round, the commit or stash before the fix in a rerun round.

```bash
python3 .claude/skills/ship/bounds_sensor.py --diff <base>
```

It sends each changed or untracked function in any `lib/` directory that reads, buffers, waits, or queues to a classifier (TypeSafe, key in `TYPESAFE_API_KEY`) with three closed questions, and prints `SIZE` and `WAIT` flags at confidence 0.9 or more. A flag is a place to attack first, not a finding. No flag is not a pass. Measured on 2026-09-18 at `93c33e9`: 9 of 12 flags on master were true, the false ones had their cap in a caller, and it missed 3 of 9 known defects in history. Answers near the threshold can differ between runs.

It always exits 0. `bounds sensor skipped` means no key; a `bounds sensor failed` line means nothing was checked, and a `NO ANSWER` line means that function or file was not checked. Put the sensor's output in the review record as it is. It sends source to an outside service, so it runs only in this repo.

In the same message, start the **Codex adversarial review** in the background, on the working tree after simplify. It is the review that found the real bugs that four to six rounds of agents missed (#189, #199, #201), so it runs in the first round, not after the loop:

```bash
codex_dir=$(/bin/ls -d "$HOME"/.claude/plugins/cache/openai-codex/codex/*/ | sort -V | /usr/bin/tail -n 1)
node "${codex_dir}scripts/codex-companion.mjs" adversarial-review "--wait --base origin/master <the invariant of the change, one sentence>"
```

The sentence names the entry points, every accepted hole, every exception that the feature doc states, and every open hole that has a ticket. It contains no text that starts with `--` (#148). Judge each Codex finding as you judge the agents' findings: reproduce it or read the code.

In the same message, spawn a third agent for the **failure-path axis**. It gets the diff, the checklist, and the sensor's flag lines, and nothing else: no review record, no summary of earlier fixes, no author notes, so it is not anchored on the author's view of the change. The brief:

> Read the diff and `docs/agents/review-checklist.md`. The checklist names categories; you enumerate the concrete cases. For every new or changed operation, state transition, and error branch, work through each category: input shape, the boundary at every named limit (at it, one under, one over, multibyte), resource bounds for every read, buffer, and wait, concurrency between sibling operations, and adversarial arguments from the model. For code that crosses to the OS, the filesystem, or the network, build a state table: list the external states (not started, running, exited with the port open, exited with the port closed, stuck) and cross them with the BEAM events (spawn, register, abort, Task kill, delivery). Test the cells; suspending a Task with `:erlang.suspend_process/1` to hold a window open is a named technique. Write throwaway tests as `.scratch/review/<name>_test.exs` at the repository root, run them with `mise exec -- mix test .scratch/review/<name>_test.exs`, and delete them when done. `.scratch/` is ignored by git; never put a throwaway test under `test/`. Sensor flags, when given, name functions to attack first; they are hints from a classifier, not findings. Probe through a boundary. A reproduction that calls an inner function directly with a value that no caller can pass is not a finding; name the boundary that lets the value in, or drop the finding. Also report the opposite: a new check, fallback, or repair in inner code that duplicates a boundary check which still proves the same property. A documented safety check is not a duplicate. Report only findings you reproduced, each with the reproduction. Budget: at most 10 minutes of probes and at most 20 repeats of one test. No mutation run over a whole suite, and no CPU load generator (other worktrees run tests on this machine). Name what the budget did not reach. Under 300 words.

A review agent that dies or stalls is rerun. Never substitute any pass by hand, whatever the diff size.

Fix every confirmed finding. Record the findings and their resolution in `docs/reviews/YYYY-MM-DD-<scope>.md`.

If step 2 changed any code, review that change again. Review is always the last pass over the code. A rerun round is smaller than the first round:

- **Reduced round:** the spec and failure-path agents only. They found every real bug in the rerun rounds of PR #30; the simplify and standards agents found none.
- **Full round:** step 1, then all of step 2.

Count the fix from its diff, without test files and Markdown. The rerun is a full round when any one of these is true:

- it changes more than 15 lines, added plus removed
- it touches more than one code file
- it adds or removes a function, a module, a process, or a dependency
- it changes the arity, the return shape, or the spec of a function
- the two-findings rule below applies to it

Otherwise the rerun is a reduced round. If a line of this list is in doubt, the answer is a full round. The review record states the counts and the round type for each rerun.

The first round is always complete. No round is ever done by hand.

The loop ends by these rules, measured on the tickets of 2026-09-27: after round 2 the agents found almost only wording and judgement calls, and one ticket ran eight rounds over one test file.

- **A round that reproduces no defect ends the loop.** Fix its wording, doc, and judgement findings, record them, and run no further round for them. A "known ceiling" that the review record already states is not a defect.
- **At most three rounds.** If round 3 still reproduces a defect, commit nothing more, and report the defect and the state to the caller. The orchestrator parks the ticket.
- **At most 45 minutes of work for the ticket.** At the limit, finish the current step, commit only code whose last review round is done, and report what is open.

Two more rules govern the loop:

- **Fix reviews target the invariant, not the reproduction.** When the change fixes a review finding, every review brief names the invariant the fix restores and asks the agents to find another path that breaks the same invariant. The finding's reproduction is the first test the agents run, not the last.
- **Two findings on one mechanism stop the patching.** When a second finding lands on a mechanism a previous round already patched, the next round fixes the mechanism, not the path. First ask whether the mechanism needs to exist: a value that can be derived on read needs no write, and a deleted write has no races (#269: four rounds of races around a resume write, removed by deriving the results on read). See `docs/agents/review-checklist.md`, "Races and resource ownership".

## 3. Precommit

Run it once, after the last round. Between rounds, run only the test files of the change. Run `.claude/skills/ship/precommit.sh`, and search `precommit.log` as `AGENTS.md` says. With a host set (an ssh target in `HELYX_PRECOMMIT_HOST` or in `~/.config/helyx/precommit-host`), the script copies the worktree to that host with rsync, runs `mix precommit` there, writes the output to the local `precommit.log`, and copies back the files that the format step changed. Without it, the script runs `mix precommit` here. It must pass with no warnings. Never pipe it to `tail`, and never rerun it to read an error.

## 4. Commit

Conventional commit, `type(scope): message`, with `Refs #<ticket>`. No attribution trailers of any kind.
