# Review: the stdin cap of the watchdog (#196)

Base: `origin/master` at `494922f`. Four rounds: the first and complete round, then three reduced rounds. Round 4 follows the owner decision on the cap.

## Change

The perl watchdog in `Helyx.Watchdog` gets a fifth argument, the cap of open input that the command has not read: 16,777,216 bytes (`@stdin_max_bytes`, 16 MiB, the same as the harness stdout line cap). After each read of its stdin for open input, when its buffer is over the cap, the watchdog stops the group as at the end of its stdin (TERM, up to the grace, KILL, reap) and exits as at the command's own end: a failed `exec` report first, else the command's status. The two stop paths share the perl subs `stop` and `finish`. Counted input has no cap: its count bounds it.

Invariant: for open input, the watchdog holds at most 16,777,216 bytes plus one read (65,536) that the command has not read before it stops the group. The entry point is the watchdog's read of its stdin, the only place that adds to its buffer. Accepted hole, documented in `coding-agent.md`: a single write over 16 MiB of unread input stops the program, even one that reads. Only a stuck program or a prompt near 16 MiB reaches it (the prompt has no byte bound), and the turn then fails with the exit error.

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

- Fixed (docs): the buffer can hold one read over the cap before the check (at most 1,114,112 bytes with the first cap of 1 MiB); the exit error applies unless a terminal came first (#167); the prompt limit differs for Claude Code (replay and prompt) and Codex (prompt alone).
- Reported, not fixed: the accepted hole has no ticket. A prompt of about 600 KB or more worked before this change. See "Owner decision".

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

## Owner decision

After round 3 the first cap, 1 MiB, could stop Claude Code at a prompt of about 600 KB, which worked before. The owner raised the cap to 16 MiB, the same as the harness stdout line cap: a real prompt and the resume replay (up to 400 KB, more after JSON escaping) must fit with room.

## Round 4 (reduced)

Fix diff: 1 code line in one file (the cap constant), no new function, no spec change. Tests: the echo test waits by byte count (`await_bytes/2`), because the split of a growing binary took 8.8 s at 16 MiB; the file runs in 4.6 s again, so the cap needs no option. Spec and failure-path agents, briefed on the invariant.

- Spec: 1 finding, fixed: this record still stated 1 MiB and an open decision. Note, not fixed: the "cap and 0 bytes" tests wait 500 ms; the failure-path agent measured the stop at about 60 ms with a smaller cap, so the window is wide enough.
- Failure path: no findings. The stop over the cap came in 59 to 64 ms; the perl buffer has no quadratic cost (`cat` with 64 parts of 1 MiB: 35 ms); `await_bytes/2` cannot hang or pass falsely. Not measured: memory; a 16 MiB buffer can reach about 32 MiB in perl during a realloc.
