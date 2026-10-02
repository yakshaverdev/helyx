---
name: orchestrate
description: Take tickets from ready-for-agent to merged on master without the user. Worktree, /implement, Codex review until clean, rebase, merge, close. Parks anything that needs a human.
---

# Orchestrate

You are the orchestrator. You do not write ticket code. You manage worktrees, workers, reviews, merges, and the queue. The user is away; never ask a question in chat. A question goes on the ticket (see Park).

The user has given standing permission to merge to master when every gate in step 5 holds. That permission covers nothing else: no force push to master, no closing a ticket that did not merge, no label other than the triage vocabulary.

## 1. Build the queue

`gh issue list --label ready-for-agent --state open`. Read each ticket's "Blocked by". The frontier is every ticket whose blockers are closed. Skip a ticket that says it must run alone until no other branch is open, then run it alone.

At most five workers at one time. On 2026-09-27, five workers on 10 cores and 16 GiB made the load average pass 200, and wall-clock tests failed in other worktrees. Most of that load came from precommit runs and load generators; a worker that waits for a review uses almost no CPU. So precommit runs on the remote host in `~/.config/helyx/precommit-host` (see `/ship` step 3), and the local machine holds only the workers. Without that file, the limit is three.

The five-worker limit assumed that the host absorbs parallel precommit runs. On 2026-10-03, five parallel runs on the 8-core host made the load average reach 125. The merge gate then failed on test timeouts (#330). Now the host runs one precommit at a time, and the other runs wait in a queue. A run that waits writes its wait to `precommit.log`. A worker that waits for precommit is not broken.

## 2. Start a worker

One worker per ticket, as an Agent with `isolation: "worktree"` on branch `ticket/<n>-<slug>` from `origin/master`. Its brief: run `/implement <n>`, which ends in `/ship`; commit on the branch; do not push, open a PR, or merge; report the invariant of the change, the review counts per round, and anything it could not decide. A worker that cannot decide something stops and reports. It does not guess.

Every brief also says:

- Check that each item the ticket names (argument, function, option) exists before you build on it.
- Never print the machine environment (`System.get_env/0`, `env`, `printenv`) in a test, an assertion message, or a review probe. Put this rule in every review brief.
- Report a wider scope before the next review round when a fix passes 100 code lines.
- A bound that the docs state must also hold in the render path, not only at the entry points.
- Run precommit with `.claude/skills/ship/precommit.sh`, never `mix precommit` directly.
- The limits of `/ship`: at most three rounds, a round with no reproduced defect ends the loop, and at most 45 minutes of work. At the limit, commit only reviewed code and report what is open.
- No CPU load generator and no mutation run over a whole suite in any probe: other worktrees run tests on this machine. Put this rule in every review brief.

A worker that stopped before its final report (a usage limit, a wait for its own agents) is resumed with SendMessage. Do not start a second worker for the ticket.

## 3. Codex review

`/ship` already ran Codex in its first round. This run is the gate on the final code. In the worker's worktree, in the foreground:

```bash
codex_dir=$(/bin/ls -d "$HOME"/.claude/plugins/cache/openai-codex/codex/*/ | sort -V | /usr/bin/tail -n 1)
node "${codex_dir}scripts/codex-companion.mjs" adversarial-review "--wait --base origin/master <the invariant of the change, one sentence>"
```

The invariant sentence names the entry points it covers, every accepted hole, every exception that the feature doc already states (for example, the write-failure policy of the session file) and every open hole that has a ticket. A reviewer that does not know a documented exception reports it as a defect. Write no text that starts with `--` in the sentence (for example a switch name such as `--model`): the companion script reads it as its own option and fails (#148). Name the switch in words.

Judge every finding yourself. Reproduce it or read the code. A reviewer's claim is not a fact. Reject a finding whose reproduction enters below the boundary with a value no caller can pass; a fix for it would add defensive code. Record the rejection with the boundary that already covers the value. The invariant sentence also names the boundaries of the change, so the reviewer knows which checks are the designed ones.

- **Confirmed:** send it to the worker (SendMessage) with the reproduction. The worker fixes it through `/ship` rules: a code fix gets its rerun round. Then run the Codex review again.
- **Rejected:** record it in the review record with the reason.

The gate is a Codex round with no confirmed finding. Three rounds without that: park.

## 4. Record the escape

Every confirmed Codex finding is an escape: `/ship` should have caught it. Before the merge, in the same branch, fix the place that let it through:

- a missing invariant: `docs/agents/review-checklist.md`
- a missing rule: `AGENTS.md`
- a gap in the ticket: the ticket template or the `/implement` skill
- the same class of finding for the second time (check `docs/reviews/escapes.md`): a mechanical check, a test or a Credo check, not more prose

Add one row per ticket to `docs/reviews/escapes.md`: date, ticket, ship findings per round, Codex findings per round, what was changed so it does not recur. The target is zero Codex findings in round one.

## 5. Merge

Serial, one ticket at a time:

1. `git fetch`, rebase the branch on `origin/master`. A conflict that is not mechanical: park.
2. Precommit into the log, as `AGENTS.md` says, with the slow tests: `HELYX_SLOW=1 .claude/skills/ship/precommit.sh`. It must pass after the rebase, not before it. The same failure twice: park.
3. Push. `gh pr create` with a body that contains `Closes #<n>`. No attribution lines.
4. `gh pr merge --merge --delete-branch`. Confirm the issue closed; close it with a pointer to the PR when it did not.
5. Run each step only when the step before it passed (`&&`, not `;`): a failed `gh pr create` must not reach the cleanup. Before the push, `git diff origin/master | grep "^+.*icket pending"` must find nothing. Search the added lines, not the tree: old devlogs on master keep the phrase as history.
6. Remove the worktree. Recompute the frontier. Rebase the other live branch before its own gate. When the merge brought a change to a module that the live branch also changes, the worker runs a reduced round on the rebased branch before the gate: its first round saw the old base, not the new interaction.

## Park

Park when: three Codex rounds are not clean; a conflict is not mechanical; precommit fails twice for one cause; the ticket needs a design decision, an interface change, or an ADR it does not state; anything would need a destructive or irreversible step outside step 5.

To park: push the branch, keep the worktree, comment on the ticket, and swap the label to `ready-for-human`. The comment is what `/hitl` reads, so it has this exact shape:

```markdown
## Decision needed

**Question:** one sentence that ends with a question mark.

**Options:**
1. <option> (recommended): <consequence>
2. <option>: <consequence>

**State:** branch `<name>`, worktree `<path>`, what is done, what waits on the answer.
```

Then take the next ticket. One parked ticket never stops the queue, except a ticket that blocks all the rest.

## End of run

When the frontier is empty, write a devlog in `docs/devlogs/`: merged tickets, parked tickets with their question, the escapes table rows of the run, and what the system change was for each escape. That devlog goes in through its own small PR by the same merge rule.
