# Every resource has a release path that works when its owner dies

Ticket #4 took six review rounds on PR #22 (`docs/reviews/2026-09-17-abort-cleanup.md`). The internal three-axis review found nothing; Greptile, Codex, and a human review then found five more windows of one weakness: the process group id lived only inside the tool Task. A Task dies with its state, so every path that killed the Task before delivery took the only reference to the group with it, and each patch left a sibling window open.

## Decision

Every resource has a release path that works when its owner dies. A holder alone is not enough: ticket #37 showed that any cleanup that lives in a BEAM process fails when that process dies first, so the death itself must cause the cleanup. Inside the VM, work is linked to its owner, and the owner traps exits so a crash below it stays a message; the chain is session, hands, Task. At the OS boundary, a command's life is tied to its port: the perl watchdog kills the command's process group when the port closes, which any death above it causes, down to a `kill -9` of the whole VM.

A process group, port, file handle, or other OS resource that a tool creates is still held with the hands before the external work starts, as an opaque handle, with `Helyx.Tool.hold/1`, because delivery and a cancel wait until the resource is gone, and that wait needs the handle. The tool that holds the handle releases it through its `release/3` callback; the hands call it and keep every handle that is not confirmed as released. The OS work lives in the plugin, never in Core. If the hold cannot complete, the external work does not start: either the hands hold the resource before the work runs, or the work never ran.

## Considered options

- Keep the resource in the tool Task and patch each window as a review finds it. Rejected: ticket #4 shows the windows are found one review at a time, and the class is unbounded.

## Consequences

- The bash launcher carries a handshake: the perl watchdog writes the group id, the tool (since #10, `Helyx.Watchdog.start/4` for it) holds it with `Helyx.Tool.hold/1`, and only then sends the go-ahead line that lets the command exec.
- Every feature doc lists its external resources in an ownership table (`docs/features/TEMPLATE.md`); a row whose release path dies with its owner is a design flag the spec axis raises before implementation.
- Harness providers that spawn processes follow the same rule: they are spawned on the hands side (ADR 0003), and their processes are held with the hands before use.
- perl is required for the bash tool; a system without it is a clear error at session start or resume (since #150, before the hands start).

## Revision

2026-09-18, ticket #37. The original decision, "OS resources are owned by long-lived processes, never by Tasks", was too broad: a long-lived holder still fails when the holder itself dies first. The rule is restated as above, and links plus the port watchdog replaced the port scan, the perl-less launcher mode, and the kill of late registrations.

2026-09-25, `docs/features/tool-resource-release.md`. The hands held process group ids and did the OS work to release them, so Core knew about signals, group kinds, and perl. The hold stays, but the handle is opaque, and the plugin that holds it releases it through `release/3`. The cleanup and refusal contract does not change.

2026-09-25, ticket #10. The Claude Code provider is the first harness provider. Its stream runs as a Task of the hands, so it can hold its groups with `Helyx.Tool.hold/1`, and the hands call the provider's `release/3` when the stream ends or its turn is aborted. The watchdog and the release moved from the bash tool to `Helyx.Watchdog`, which both plugins share (ADR 0005, revision of 2026-09-25). The watchdog can now give the command a counted input on stdin; the kill on a closed port does not change.

2026-09-25, ticket #11. The Codex provider is the second harness provider, with the same hold and release. Two changes serve it. The watchdog has an open input: the command reads what the owner writes until a NUL byte, so a JSON-RPC program can end by itself at end of file; the kill on a closed port does not change. The hands stop a harness stream Task with `Task.shutdown/2` and a 2,000 ms grace, not a brutal kill, so a stream that traps exits can ask its program to stop the turn before the release. The release still comes after the Task is gone, so an abort still returns only when the group is gone. Codex puts each command in a process group of its own, which Helyx cannot hold, and ends them itself on TERM; a KILL leaves them running. So for Codex the watchdog at the port close and the release both wait up to 5,000 ms after the TERM before the KILL, not 500 ms. Accepted hole, like the setsid limit above: a codex that does not exit within that wait is KILLed and can leave its commands running.

2026-10-17, ticket #651. A harness provider replaces its program at a prompt change, and a Claude provider also at a lost session. The release at the end of the provider process came too late for a replaced program: the hands held its handles until then, two per relaunch. Before a launch, the provider now releases the groups of the program before with its own `release/3`, and drops the confirmed handles with `Helyx.Tool.unhold/1`. A handle that the release does not confirm stays held, so the rule above does not change: the hands release every handle that the plugin did not prove gone.
