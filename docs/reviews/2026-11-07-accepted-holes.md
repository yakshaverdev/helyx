# Accepted holes audit, 2026-11-07

Scope: the `## Accepted holes` sections of every feature doc, the two `## Current limits`
sections, and the devlogs that record an owner acceptance. Read-only audit; no code changed.
Decision: `docs/adr/0014-hole-proofing-invariants.md`.

## The test

A hole is acceptable when it is an OS limit, a trust boundary the user already controls, or a
resource cap. It is not acceptable when it does one of these:

- loses data, or lets a call run again after it was reported `aborted`;
- leaks a secret, even in an overlapping copy;
- turns a failed run into success;
- breaks a bound the docs promise on a legal input;
- has no workaround for a user action.

The "constructed input" argument is enough for a crash on a contract break. It is not enough
for data, a secret, a status, or a promised bound.

## Should not have accepted

1. **`print-mode` can exit 0 after a failed run.**
   `docs/features/print-mode.md`, "Open": a SIGQUIT or SIGUSR1 during the abort wait of a
   SIGTERM or SIGHUP halts the VM with the OTP status, so `143` becomes `0`. A script or a CI
   step reads success. The doc calls it a judgement of review round 7.
   Rule: invariant 6.

2. **A replay can drop the interrupted result.**
   `docs/features/interrupted-calls.md`, "Accepted holes": the 400,000-byte replay cut can
   leave out the last assistant message, its calls, and their results. One large `write` call
   is enough, and the model can run it again.
   Rule: invariant 3.

3. **An overlapping copy of the API key can reach an error text.**
   `docs/devlogs/2026-10-17-652-openai-compatible.md`, "Assumptions": three review rounds
   found new key paths, and the owner accepted an overlapping copy because no real provider was
   shown to echo it. A malicious or buggy gateway can echo a fragment; the cost is a credential
   leak.
   Rule: invariant 2.

4. **A legal 4 MiB text can close the TUI connection.**
   `docs/devlogs/2026-10-20-821-write-path.md` and `tui-attach.md`, "Accepted holes": a 4 MiB
   steer of `\u0001` becomes about 24 MiB of JSON, passes the server's 64 MiB outbound queue,
   and the server closes the client with `4408`. The documented text bound is 4 MiB, so this is
   a legal input that fails.
   Rule: invariant 1.

5. **A background run lives after its call got `aborted`.**
   `docs/features/print-background-wait.md`, "Accepted holes", and devlog #595: a background
   run whose start answer the hands took before the cleanup keeps running after its call got
   `aborted`, and delivers its end later. The model can run the call again; the side effects
   happen twice. The devlog names the fix as option 2 of #595.
   Rule: invariant 4.

## Accepted, but the cost is understated

6. **Hub has no folder isolation, and a revoke does not stop an existing subscription.**
   `docs/features/hub.md`, "Accepted holes": every user runs tools as the server OS user in any
   folder `start` admits; a connection that proved itself keeps its open subscriptions after a
   revoke until it closes. Hub is design-only today. Do not build multi-user before the
   per-user executor and the per-delivery grant.
   Rule: invariant 5.

7. **A resumed TUI shows only the last 200 messages, and nothing says the rest exist.**
   `tui-attach.md`, "Accepted holes" (slice 3): the client shows the tail and "no line says
   that they are there." A user with a long session can believe the history was lost.
   Rule: invariant 3.

8. **`server.log` has no size bound.**
   `tui-attach.md`, "Accepted holes" (#808): each server a client starts adds its output, and
   a long server adds its log, with no bound. A daemon can fill the disk.
   Rule: invariant 1.

9. **A switch stops the session for every other client.**
   `tui-attach.md`, "Accepted holes" (slice 3): two clients attach, but a `/new` or `/resume`
   in one stops the session and the other ends with `the session stopped`. A tmux user does not
   expect a new window to kill the other client.
   Rule: invariant 4.

10. **A session from a build two installs old can lose its files.**
    `docs/features/local-release.md`, "Accepted holes": the VM loads modules on demand, so a
    running session can fail when the next install deletes the old build. The two-build bound
    is a release policy, not a data guarantee.
    Rule: invariant 4.

## What stays accepted

SIGKILL leaving `server.json`; a fault signal to the supervisor leaving the VM; the FIFO
between the type check and the open; the `flock` removal; a plugin that links to the caller; a
`server.json` from another build; the 64-session cap; a `mix helyx` server that stops with its
TUI; a SIGKILL of the VM. These are OS limits, trust boundaries the user controls, or resource
caps. The invariants do not remove them.

## Resolution

Implemented on `deslop/2026-11-06`:

- **Invariant 6** (status owner): the print signal handler marks the stop and ignores every later
  signal, so a SIGQUIT or SIGUSR1 cannot turn 143 into 0.
- **Invariant 2** (secret): the OpenAI error text is built from the status and structured
  `type`/`code`; the body, `message`, and chunks never reach it. Content and tool-call deltas
  keep the exact mask, which is the remaining bound; a gateway that already holds the key is a
  different threat.
- **Invariant 1** (bounds): the 4 MiB text bound, the 25 MiB joined wire bound, and the 64 MiB
  outbound queue are distinct. A plain 4 MiB text and its parts form are accepted; a genuinely
  over-joined request is rejected at the composer; `server.log` rotates at 10 MiB. A slow client
  can still meet the 4408 queue policy; that is a read-pace bound, not an input rejection.
- **Invariant 3** (truncation): the replay cut keeps the open turn, its calls, and their results,
  or fails with `replay_over_limit`. The snapshot carries `older` and the TUI shows the notice.
  Pagination is not built, so the notice is inert; a `history` request is the follow-up. The
  `older` field is optional on decode; the wire schema doc and a protocol bump are still a
  parent decision.
- **Invariant 4** (leases): an abort or failed turn revokes its background runs; a switch
  detaches a client and the session runs on; a release keeps a build with a live VM marker.
- **Invariant 5** (authority): design only. Hub remains blocked on the per-user executor and the
  per-delivery grant.

The six questions are in `docs/agents/review-checklist.md`. The branch gate is
`mix precommit` with all three projects green.
