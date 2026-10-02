# Review: queue the precommit runs on the host (#330)

Base: `origin/master` at `9defa53`.

## Change

`.claude/skills/ship/precommit.sh` takes a host-wide `flock` on `~/.helyx-precommit.lock` in the remote command, around the isolated `mix precommit`. A run that must wait writes `precommit: waiting for the host lock` to `precommit.log`, and `precommit: waited N s for the host lock` when the wait ends. A local run does not change. The `/orchestrate` skill, step 1, says that the five-worker limit assumed that the host absorbs parallel runs, and that the runs now wait in a queue.

Invariant: while the isolated `mix precommit` of a run executes on the host, that run holds the host-wide lock, so no two runs execute at once, and the lock is freed when the run ends in any way.

The host has `flock` (util-linux 2.39.3), so the stop condition of the ticket did not apply.

## Bounds sensor

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

(Each round: the change is not in a `lib/` directory.)

## Round 1 (full)

Simplify: the reuse and efficiency agents found nothing. Skipped: removing the wait line and shortening the comment (the ticket asks for both). The altitude agent noted that a waiting ssh session sends no keepalive; this went to the review, see "Open".

Standards (0 hard, 4 judgement): wording of the bound changed to "unbounded, and accepted" (review checklist); long sentences split in the comment and in the skill; the queue text has its own paragraph in `/orchestrate`. Not changed: the name `queue` (it matches the nearby `isolate`).

Spec (3 findings): fixed: the wait now prints a line when it starts and a line with the seconds when it ends; the `/orchestrate` text now says that the five-worker limit assumed that the host absorbs parallel runs; the run gets descriptor 9 closed (`9>&-`), so a `sudoers` setting that keeps descriptors cannot hold the lock after the shell. Not changed: a `command -v flock` check in the script (the ticket asks the implementer to stop and report, and the host has `flock`; without it the run fails with status 127 and does not run unqueued).

Codex: approve, no findings.

Failure path (1 defect, reproduced): the round's own `9>&-` fix made the lock free early under dash. Dash replaces itself with the last command of a `-c` string, and `9>&-` then closed the only copy of descriptor 9. Reproduction: under `/bin/dash`, a second run waited 0.0 s in 3 of 3 trials; under bash 3.2 and bash 5 it waited 2.5 s. Fix: a trailing `; exit $?`, so the run is never the last command and the shell keeps the lock. Proved on the host with two short runs under the login shell (bash) and under dash: the second run waited 2 s each time, and the lock was free after the runs.

## Round 2 (full)

The fix is the second finding on one mechanism (the life of descriptor 9), so round 2 is full.

Simplify: one sentence in `/ship` step 3 repeated the queue text, and the ticket does not ask for it, so it is removed. Skipped: the `flock -o FILE cmd` form. It removes `9>&-` and the trailing `exit`, but the "waited" line then needs another nested shell inside the quoting of `isolate`, or prints only after the run.

Standards (0 hard, 5 judgement): the bound now says that a hung compile or Dialyzer step of the holder blocks the queue (the test timeouts do not bound those steps); long sentences split; "slow, not broken" made plain. Not changed: the name `queue`, and the five-worker limit (the ticket does not ask to change it).

Spec (0 missing, 1 edge): a SIGKILL of the outer shell frees the lock while the run continues. Codex reported the same, see below.

Codex (1 high, reproduced locally by Codex): the outer shell holds the lock, and the run gets descriptor 9 closed. A SIGKILL of the outer shell frees the lock while sudo, unshare, and the run continue, so a waiting run starts beside it.

Failure path (1 defect, reproduced): the round 1 fix holds in dash, zsh, `/bin/sh`, and bash 5. But SIGTERM or SIGHUP to the outer shell alone frees the lock while the run continues (dash and bash, exit 143 or 129, a probe got the lock at 1.0 s).

Fix (the mechanism, by the two-findings rule): three findings landed on one mechanism, a lock on a descriptor of the outer shell. The mechanism is removed. `flock --verbose ~/.helyx-precommit.lock` now runs inside the PID namespace, after `setpriv`, in front of `mise exec -- mix precommit`. The run inherits the lock, so flock, mise, and the Mix VM hold it, and the end of the namespace ends them all. A check before the namespace (`flock -n LOCK true`) writes the waiting line and holds nothing. `--verbose` writes `flock: getting lock took N seconds`. The descriptor 9 code, `9>&-`, and the trailing `exit` are deleted. Proved on the host with the real `isolate` string and `sleep` in place of mix: in case 1, the second run waited 1.9 s; in case 2, the outer shell of the holder got SIGKILL at 1 s, and the second run still waited 3.5 s, until the holder's run ended. The lock was free after the runs.

## Round 3 (full)

Simplify: no changes. `--verbose` writes only when the lock is got, so the check is the only line before a wait. The comment at the top states the contract, and the comment at the command states the mechanism.

Standards (0 hard, 4 judgement): sentences split; "kill -1" named; the comment says that the waiting line can be wrong under a race. Not changed: the two comment blocks (contract and mechanism), the lock path in the comment and in `lock=`, and the evidence in `/orchestrate`.

Spec (0 missing, 0 wrong): the waiting line has no time, and the time comes from `--verbose` on every run; accepted as the reading of step 2. Paths that exist before this change are under "Open".

Failure path (0 defects): SIGKILL, SIGTERM, and SIGHUP to the outer shell, and SIGKILL to `flock` while mix lives, all keep the lock until the run ends (perl shim of `flock(2)`; `sudo`, `unshare`, and `setpriv` reasoned).

Codex (1 high, not reproduced, read in the code): if the Mix VM gets SIGKILL while a `System.cmd/3` child runs, `flock` exits and frees the lock. The BEAM children do not hold the descriptor. Then pid1 exits, and the kernel kills the namespace. A waiting run can get the lock in that gap. Judgement: a known ceiling, not a defect. The gap lasts from the exit of `flock` until the kernel kills the namespace, and it opens only when the Mix VM is killed. The overlap is a few milliseconds of dying processes, against a new run that starts with a compile.

Round 3 reproduced no defect, so the loop ends.

Precommit: passed with `HELYX_SLOW=1`. The run went through the new queue, and its log has `flock: getting lock took 0.000002 seconds`. The line is at the end of the log, because ssh carries stderr on its own channel.

## Open

- A queued ssh session is silent and sets no `ServerAliveInterval`. An idle NAT or firewall can drop it during a long wait. No reviewer reproduced this.
- A run whose local ssh is killed goes on on the host, holds the lock, and blocks the queue until its run ends. This was true of the run before this change too, except for the queue.
- Two runs from one worktree share one directory on the host. The rsync and `.before` of the second run change the files of the first. This existed before this change, but the queue makes the window longer. `/orchestrate` runs one worker per worktree.
- A deleted `~/.helyx-precommit.lock` lets the next run lock a new file. Nothing in the repository deletes it.
