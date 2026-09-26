# Review: the stdin cap of the watchdog (#196)

Base: `origin/master` at `494922f`. Three rounds: the first and complete round, then two reduced rounds.

## Change

The perl watchdog in `Helyx.Watchdog` gets a fifth argument, the cap of open input that the command has not read: 1,048,576 bytes (`@stdin_max_bytes`). After each read of its stdin for open input, when its buffer is over the cap, the watchdog stops the group as at the end of its stdin (TERM, up to the grace, KILL, reap) and exits as at the command's own end: a failed `exec` report first, else the command's status. The two stop paths share the perl subs `stop` and `finish`. Counted input has no cap: its count bounds it.

Invariant: for open input, the watchdog holds at most 1,048,576 bytes plus one read (65,536) that the command has not read before it stops the group. The entry point is the watchdog's read of its stdin, the only place that adds to its buffer. Accepted hole, documented in `coding-agent.md`: the cap counts bytes, not time, so one write larger than the cap stops even a command that reads, when the watchdog takes the write faster than the command reads it. A Claude Code prompt of about 600 KB or more, or a Codex prompt near 1 MiB, can stop the program. The prompt has no byte bound.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Four agents: reuse, simplification, efficiency, altitude.

- Fixed (efficiency): the test that counts unread bytes writes three half-cap parts, not four.
- Skipped (efficiency): the not-reading test writes twice the cap, not the cap plus one byte. The pipe takes up to 65,536 bytes first.
- Skipped (simplification): a comment on the argument of `finish`, the removal of "Public for the tests", and a local for the launcher arguments. Style only.

### Standards

- Fixed: the checklist asks for tests at the limit, one under, one over, and a multibyte case. Added: the cap alone (not stopped) and the cap plus 65,537 bytes (stopped), each with `x` and `é`.

### Spec

- Fixed (docs): the buffer can hold one read over the cap before the check (at most 1,114,112 bytes); the exit error applies unless a terminal came first (#167); the prompt limit differs for Claude Code (replay and prompt) and Codex (prompt alone).
- Reported, not fixed: the accepted hole has no ticket. A prompt of about 600 KB or more worked before this change. See "Open decision".

### Failure path

No reproduced findings. Probes: the exact limit (the cap plus the 65,536-byte pipe alive, one byte more stopped), `é` input, a NUL then 3 MiB, a command that ignores TERM with a background child, a command that exits 0 on TERM, a port close in the grace, a watchdog held with SIGSTOP during a stop.

## Round 2 (reduced)

Fix diff: 0 code lines (tests and Markdown only). Spec and failure-path agents, briefed on the invariant.

- Spec: 3 doc findings, fixed: the long-lived harness status line and comparison row still said #196 was open; "waits the grace" is "waits up to the grace"; the NUL end and the replay apply to Claude Code too.
- Failure path: 1 finding, fixed. The "0 over" limit tests assumed a 65,536-byte pipe. On macOS a new pipe gets 512 bytes when the pipe memory of the system is short (reproduced with 2,000 filled pipes), so the command was stopped. The tests now send the cap alone and the cap plus 65,537 bytes, which hold for any pipe of 65,536 bytes or less.

## Round 3 (reduced)

Fix diff: 0 code lines (tests and Markdown only). Spec and failure-path agents.

- Spec: 1 doc finding, fixed: the long-lived harness Bounds row now names the read and the pipe on top of the cap.
- Failure path: no findings. The pipe reproduction passed 10 repeats; probes of TERM, KILL, and background members found only the documented hole of a command that exits first.

## Open decision

The prompt has no byte bound, and a single write over the cap stops even a command that reads. The owner decides whether to bound the prompt at the client boundary, to give the watchdog back-pressure instead of a stop, or to accept the hole with a ticket.
