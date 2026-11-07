# Hole-proofing invariants

Review: `docs/reviews/2026-11-07-accepted-holes.md`.

## Context

The docs hold many accepted holes. Most are honest: an OS signal, a stale file, a FIFO inside
the trust boundary, a plugin linked to its caller. Five are not. One leaks a secret, one loses
an interrupted result, one turns a failed run into exit status 0, one closes the connection on a
legal input, one lets a background run continue after its call got `aborted`. The Hub design
adds two: no folder isolation, and a revoked connection that keeps its subscriptions.

They share one shape: a bound, a lifetime, or an authority is at the wrong layer, or unowned.
The accepted-hole sentence usually says "a constructed input" or "a person decides." That is
fair for a crash. It is not fair for data, a secret, a status, or a promised bound.

## Decision

1. **A bound is measured at the boundary that enforces it.** A text bound is in encoded-frame
   bytes, a log bound is at the sink. A value legal at the documented bound cannot fail a later
   bound in the same path.
2. **A secret is never a string in a text path.** The key does not enter an error body, log, or
   client text, even as an overlapping copy. A post-hoc mask is not proof.
3. **Truncation is semantic and announced.** The cut keeps the open turn, its calls, and their
   results; closed history may go. If the open turn alone is over the bound, return a typed
   error. A client that sees a tail knows that older messages exist.
4. **A lifecycle has an explicit lease.** A run holds a lease from its turn, a session from its
   server, a build from each running VM. No one outlives the holder silently. An abort revokes
   the run; a switch detaches a client; a release keeps a build in use.
5. **Authority is checked on every delivery.** A subscription carries a grant; a revoke removes
   it from the live set. A multi-user product has a per-user executor, not the server's OS user
   in every folder.
6. **One status owner per run.** The first owned signal sets the result; a later signal cannot
   overwrite it. The halt reads the status.

## Consequences

- `print-mode.md`: SIGQUIT/SIGUSR1 during the abort wait cannot turn 143/129 into 0.
- `interrupted-calls.md`: the replay keeps the open turn and its result, or fails.
- `openai-compatible.md`: the error text is status plus structured type/code, not a masked body.
- `tui-attach.md`: the text, joined-wire, and outbound-queue bounds are distinct; the tail
  carries `has_more` and a notice.
- `print-background-wait.md`: an abort cancels the turn's background runs (#595).
- `hub.md`: multi-user is blocked on the per-user executor and the per-delivery grant.
- `local-release.md`: a release keeps a build with a live lease.
- `server.log`: one bounded sink with rotation.

Small changes: invariants 1, 2, 6, and the run lease. Medium: the tail notice and the build
lease. Large: the session lease and Hub. Hub is a design condition, not a patch.

## Not decided

The numbers, whether Hub is built, the lease storage, the executor identity, and the release
layout. Those belong to the feature or ADR that implements each invariant.
