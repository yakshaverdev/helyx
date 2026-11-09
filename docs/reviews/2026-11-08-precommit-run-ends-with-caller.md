# Review: a precommit run on the host ends with its caller

Base: `a99d0703`. No ticket: the owner asked for it in chat on 2026-11-07. Change: `.claude/skills/ship/precommit.sh`.

## Problem

When the local caller ended (a worker stopped by the orchestrator, a usage limit, a TaskStop), the local ssh died, but the run on the host went on. A run that waited for the lock kept its place in the queue, and a run that held the lock ran to its end. On 2026-11-06, seven such runs sat in the queue.

## Design

- **Local side.** The ssh of the run reads stdin from a FIFO. Its only writer is fd 3 of the script, and nothing writes to it. The script opens fd 3 read-write first, so the open does not wait for a reader; then it opens fd 4 read-only, which does not wait for a writer, and removes the FIFO at once. When the script ends, by any signal, the ssh's input ends. When the ssh ends, the channel closes.
- **Remote side.** The first process of the PID namespace, a root dash, sets a trap on HUP. It starts the run in the background with stdin on `/dev/null`, and a watcher `{ cat >/dev/null; kill -s HUP $$; }` on the channel's stdin, kept on fd 3. At the end of that input, the watcher sends HUP to the first process only (`$$` is 1 in the namespace). The trap exits it, and the end of the first process of a PID namespace ends every process in it. So the lock is free.
- **Signal dispositions.** `env --default-signal=HUP` runs before the first `sh`, so the trap works whatever the chain above passes. `env --default-signal=INT,QUIT` runs before the run, because dash starts a background job with those two signals ignored. No signal goes to -1, 0, a negative pid, or a group.
- **Candidate not taken.** A remote pty (`ssh -tt`), so that sshd sends SIGHUP on disconnect, was not taken. It would change the log (CRLF line ends, colour codes from a tty), and the sudo `use_pty` relay would add a layer. The stdin watcher needs one FIFO locally and one line remotely.
- **Accepted holes.**
  - A network loss with no close of the connection ends the run only when TCP gives up. Host settings read on 2026-11-08 (`sshd -T`, `sysctl`): `ClientAliveInterval 0`, `TCPKeepAlive yes`, keepalive 7200 s then 9 probes of 75 s (about 2 h 11 min for a run that writes nothing), `tcp_retries2 = 15` (about 15 min after the first unanswered write).
  - A kill between `mktemp -d` and `rm -r` leaves an empty FIFO in a temp folder. No ssh has started then.
  - A caller that dies while `precommit.sh` goes on (an orphaned script) leaves the run going, as the spec scopes it ("when the local `precommit.sh` (or its ssh) ends").

## Proof on the host

The probe harness was outside the repository. Each run was a throwaway git repo with a copy of the script under test, in which `sed` changed only the lock line (to a lock in a probe folder) and the command (to a stand-in). The probe printed the host process tree of each run before each kill: the sshd session, sudo, unshare, the first sh, flock, the watcher sh and cat. It then checked with `ps` that none of those pids was left with the same command name. Cleanup signalled only recorded pids of its own runs, each by its positive pid, and removed only its own folders. The final script gave these results:

| Stage | Event | Result |
|---|---|---|
| B waits (A holds) | local ssh SIGKILL | none of B's host processes left within 1 s; A still holds |
| C waits | local precommit.sh SIGKILL | none left within 1 s; the orphaned local ssh ended |
| A holds (D waits) | local ssh SIGKILL | none left within 1 s; D's flock then ran its command |
| D holds (E waits) | local precommit.sh SIGKILL | none left within 1 s; E: `flock: getting lock took 2.605761 seconds`, then `format changed on HOST and copied back: ./a.exs`, `passed`, local `a.exs` updated |
| F, the real `mix precommit` of this worktree with a probe lock | local precommit.sh SIGKILL, with 8 `beam.smp` and 8 `erl_child_setup` running | none left within 1 s; the next run: `flock: getting lock took 0.000005 seconds`, `passed` |
| A failed stand-in (`false`) | normal end | status 1, `failed`, log kept |
| The run's signals (`grep ^Sig /proc/self/status`) | normal end | `SigIgn 0`, `SigBlk 0`, the same as the script at `a99d0703` (round 1 before its fix: `SigIgn 0x6`) |
| B and C started under `nohup sudo …` (HUP ignored above) | local precommit.sh SIGKILL while waiting | with the env of HUP, the first process had `SigIgn 0` and B ended within 1 s; with that env removed, `SigIgn 0x1` and C stayed until the probe's cleanup |

After each run, 0 host processes held the probe token. The same probe against the script at `a99d0703` failed:
- B, C, D and E stayed on the host after their local side was killed.
- The stale B took the lock before D.
- C's orphaned local ssh did not end.

`flock --verbose` buffers its line: in a run whose holder D was killed, D's log had no `getting lock took` line 30 s after D's flock ran its command. E's line came at E's end.

OpenSSH: 10.3p1 locally, 9.6p1 on the host. coreutils on the host: 9.4.

Bounds sensor, round 1: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full: simplify, standards, spec, failure path, Codex)

Simplify: comments only. The spec and failure-path agents died at a usage limit, and were run again.

| # | Axis | Finding | Reproduced | Resolution |
|---|---|---|---|---|
| 1 | Standards, spec, failure path | The run is a background job of dash, so it starts with SIGINT and SIGQUIT ignored, unlike before. Tests send them | yes: `SigIgn 0x6` against `0x0` at `a99d0703` | Fixed: `env --default-signal=INT,QUIT` before the run; `SigIgn 0` |
| 2 | Spec | dash cannot trap a signal that it starts with ignored. If the chain ignored HUP, the end of input would not end the run | yes, locally; on the host with `nohup sudo` | Fixed: `env --default-signal=HUP` before the first `sh`; proved with and without it (table above) |
| 3 | Codex | The end of the ssh's stdin may not reach the remote command while the ssh lives | no | Rejected. Runs C and D killed only the local script, and their ssh ended its input: the run ended within 1 s and the orphaned ssh ended. The failure path's SIGTERM cell too |
| 4 | Spec, standards | The network-loss hole had no bound, and "accepted" was not in the checklist's words | n/a | The comment states the bound from the host settings; listed as an assumption in the report |
| 5 | Standards | Comments: the order of the two opens, why fd 3 holds the channel, long sentences, the name `keep`, one guarantee stated three times | n/a | Fixed: the opens and fd 3 are explained, `fifo_dir`, shorter sentences; the guarantee is stated once in the header, and the other comments describe the mechanism |
| 6 | Spec | The header line on flock's buffered wait line was not asked for | n/a | Kept: the probe found the old sentence false (see above) |

## Round 2 (reduced: spec, failure path)

The invariant of the fix: every process of the run starts with the signal dispositions it had before (none ignored, none blocked), and the HUP trap of the first process works whatever the chain above it passes.

| # | Axis | Finding | Reproduced | Resolution |
|---|---|---|---|---|
| 1 | Spec | A background job keeps the mask that the chain passes. With SIGCHLD blocked, `wait` would not return | locally (macOS dash, a chain that blocks the signal); not on the host | Rejected for the host: with HUP blocked above `sudo`, the first process had `SigBlk 0` (failure-path probe), so sudo or unshare clears the mask; the run has `SigBlk 0` |
| 2 | Failure path | A kill between `mktemp -d` and `rm -r` leaves an empty folder with the FIFO | yes, with the window widened by a slow `mkfifo` | Stated as a hole in the comment: no ssh has started, nothing runs on the host |
| 3 | Spec | No real `mix precommit` ran to `passed` under the new script | n/a | The precommit of this commit is that run |

Round 2 reproduced no defect that a path on the host can reach, so the loop ends. Its wording fix gets no further round.

## Precommit

`.claude/skills/ship/precommit.sh` with this change, so the run itself ran under the new first process:
- **First run: failed.** One test of the root project: `Helyx.Session.HooksTest` "a hook killed at its limit gets a cancel release" (`test/helyx/session/hooks_test.exs:443`, no matching message after 30000 ms).
  - The test runs inside the BEAM only: a hook Task holds a handle and is killed at its limit. No OS process, signal or stdin is involved.
  - Locally it passed 8 of 8 alone, and the root suite passed with the seed of the failed run (108090, `863 tests, 0 failures`).
  - Recorded as a flake under load, not caused by this change.
- **Second run: passed.** Its log ends with `flock: getting lock took 55.345739 seconds`, which is the buffered line.
