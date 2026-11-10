# Review: a local precommit run takes the host lock and the host umask

Change: `.claude/skills/ship/precommit.sh` (local branch) and `.claude/skills/ship/precommit-run.sh`. Base `137bb859`.

Cause: on the precommit host, a run from a local shell (umask 002) made 66 Hub tests fail with `:unsafe_folder`; remote runs start under `sudo`, whose default umask 0022 gives 022 (checked: `sudo -n sh -c umask` prints 0022, the shell 0002). A local run also took no lock, so it could overlap a remote run.

Bounds sensor: `0 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full)

- Simplify: shared the remote `lock`/`announce` strings through `eval`. Rejected: the explicit block is clearer, and `eval` of a built string is riskier than two repeated words.
- Standards and spec: no defect. The umask comment named pam_umask as the cause; wrong (the cause is sudo), fixed. The wait-line race comment of the remote path applies to the local block too (accepted, the line is only a hint; flock's verbose line gives the real wait).
- Codex: approve, no findings.
- Failure path: (1) a script killed while it waits left a `flock` that later took the lock and ran; (2) a script killed while the run runs left the lock held; (3) an unopenable lock file stops the run. Fixed 1 and 2 (setsid group, trap). 3 accepted: the remote path does the same.

## Round 2 (reduced)

- Spec: the run's children started with SIGINT ignored (a background job); the host clears it with `env --default-signal=INT,QUIT`. Fixed the same way.
- Failure path: a signal between the fork and the trap left the run; a run child that handles TERM slowly kept the lock. Fixed: the trap is set before the fork and reads `$!`; it sends SIGKILL, as the end of the namespace does on the host.

## Round 3 (reduced)

- Both agents: a signal after the fork but before the child calls `setsid` found no group to kill (10 of 10 with an injected kill; 2 of 123 by timing). Fixed in a small-fix change: the trap also kills the pid `$!`. Also: `$!` before any fork is unbound under `set -u` (exit 1, not 143); fixed with `${!:-}`.
- Probe after the fix: a TERM right after the fork, 10 of 10 runs: exit 143, lock free.
- No further round, by the owner's call on 2026-11-10 (the review loop took 17 minutes for a 20-line script change).

## Accepted

A SIGKILL of the script leaves the group running. A run child that calls `setsid` itself escapes the group. Without flock (macOS) a local run has no queue. Signals other than TERM, INT and HUP end the script with no kill of the group.
