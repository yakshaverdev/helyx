# Tools run in a hands process, not in the session

Every session has a hands process that owns the working directory and runs tool calls. The session addresses it by pid. In local mode the hands live on the same node. The reason is distribution: a later product will run the session on one machine and the hands on another, such as a Docker container or a machine with a browser. Making that boundary a process from the first commit keeps tool calls and results as plain terms and keeps the tool set owned by the hands, so moving the hands to another node changes nothing in the session.

## Considered options

- Call tools as local functions inside the session process. Rejected: the boundary would have to be added later, and by then tool calls and results would carry pids and closures.

## Consequences

- Tool calls and results contain no pids, functions, or references.
- The set of available tools is reported by the hands, not configured on the session.
- Harness providers are also spawned on the hands side, because they are shell processes that act on the working directory.
- A tool holds each OS resource that it creates with the hands, as an opaque handle, before the external work starts. A Task alone never holds it. The tool that holds them releases them through its `release/3` callback (ADR 0004).

## Update 2026-10-12: the session owns the tool set

The consequence "The set of available tools is reported by the hands" no longer holds since #142 (af73030, `docs/reviews/2026-09-26-tool-specs.md`). `Helyx.Session` builds the tool set at the start and the resume of a session, checks it, and gives the hands the tool modules by name. The plugin table of a Core and the tool set of a session do not change after start. The tool set and the tool checks, such as the perl check of the bash tool, run on the node of the session. Remote hands, the reason for this ADR, would need both on their own node, so this part is decided again when remote hands come. A tool set that changes during a session is #473, open. Found by `docs/reviews/2026-10-12-domain-review.md`, A6.
