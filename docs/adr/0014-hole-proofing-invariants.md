# Hole-proofing invariants

Review: `docs/reviews/2026-11-07-accepted-holes.md` (the audit that found the holes).
This ADR is the decision that follows it. It is not a feature.

## Context

The docs and devlogs hold many accepted holes. Most are honest: an OS signal the VM cannot
own, a stale file that the next start replaces, a FIFO inside the trust boundary, a plugin
linked to its caller. Five are not. One leaks a secret, one loses the interrupted result of a
call, one turns a failed run into exit status 0, one closes the connection on a legal input at
the documented bound, and one lets a background run continue after its call got `aborted`.
The Hub design adds two more: no folder isolation between users, and a revoked connection that
keeps its subscriptions until it closes.

These are not separate defects. They share one shape: a bound, a lifetime, or an authority is
applied at the wrong layer, or not owned at all. The accepted-hole sentence usually says "a
constructed input" or "a person decides." For a crash that is a fair rule. For data loss, a
secret, a wrong exit status, or a promised bound, it is not.

## Decision

Six invariants. A design or a change that breaks one is a finding, not a trade.

1. **A bound is measured at the boundary that enforces it.** A text bound is in the bytes of
   the encoded frame, not the source text. A log bound is at the sink, not at each writer. A
   value that is legal under the documented bound cannot fail a later bound in the same path.

2. **A secret is never a string in a text path.** The key does not enter an error body, a log
   line, or a client text, even as an overlapping copy. A post-hoc mask is not proof: the
   secret must not be in the string space that the formatter can reach. If a body cannot be
   proven redacted, the text is generic.

3. **Truncation is semantic and announced.** A replay cut keeps the open turn, its calls, and
   their results. It cuts only closed history. If the open turn alone exceeds the bound, the
   answer is a typed error, not a silent drop. A client that sees a tail knows that older
   messages exist and can ask for them.

4. **A lifecycle has an explicit lease.** A background run holds a lease from its turn; an
   abort revokes it and cancels the run. A session holds a lease from its subscribers; a
   switch detaches, it does not stop the session for another client. A build holds a lease
   from each running VM; a release deletes only a build with no lease. No one outlives the
   holder silently.

5. **Authority is checked on every delivery.** A subscription carries a grant, and a revoke
   removes the grant from the live set, so existing subscriptions stop. The executor of a user
   is not the server's OS user in every folder. A multi-user product does not ship before the
   per-user executor and the per-delivery grant exist.

6. **One status owner per run.** The first owned signal sets the result; a later signal cannot
   overwrite it. The halt reads the status, not the last signal or the last writer.

## Consequences

- `print-mode.md`: the exit status is one value. A SIGQUIT or SIGUSR1 during the abort wait
  cannot turn 143 into 0.
- `interrupted-calls.md`: the replay bound applies to closed history. The open turn and its
  interrupted result always travel, or the resume/print fails with a typed error.
- `openai-compatible.md`: the provider error text is built from a redacted value, not a masked
  string. The key is not in the formatter's input.
- `tui-attach.md`: the 4 MiB text rule becomes a wire-frame rule. The worst JSON form of a
  legal text is either accepted or rejected at the composer with a reason. The TUI tail carries
  `has_more` and an "N older messages" notice.
- `print-background-wait.md`: a background run has a lease. The #595 hole closes by cancel, not
  by waiting.
- `hub.md`: multi-user is blocked on the per-user executor and the per-delivery grant. The two
  holes are design conditions, not accepted limits.
- `local-release.md`: the release keeps a build with a live lease, or each VM runs from its own
  generation.
- `server.log`: one bounded sink with rotation.

The code changes are small for invariants 1, 2, 4 (run), and 6. Invariant 3 is a snapshot field
and a cut rule. Invariant 4 (session, build) is a lifetime decision. Invariant 5 is an ADR of
its own, because it changes the product boundary.

## What this ADR does not decide

- The numbers: the frame bound, the log size, the session grace, the build retention.
- Whether Hub is built at all.
- The storage of a grant, the OS identity of an executor, or the release layout.

Those are decisions of the feature or the ADR that implements each invariant.
