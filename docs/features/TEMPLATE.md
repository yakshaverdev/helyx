# <Feature name>

Copy this file to `<slug>.md` and fill it in before the implementation. Review checks it against the diff (`docs/agents/review-checklist.md`, "Specs and bounds").

## Goal

What the feature does and why. A design decision that the tools research (`docs/research/coding-tools.md`, issue #17) covered cites it here, so review can check the design against how codex, opencode, and pi behave.

## Interface changes

The behaviours, public functions, and event shapes this feature adds or changes.

## Replaced mechanism

Fill this in when the feature replaces or merges a protocol, a state machine, or a code path. Otherwise write "none". Build it from the code and the tests, not from docs or summaries.

1. Every message, reply, state, rule, deadline, and bound of the old mechanism, each with its replacement, or its deletion and the reason.
2. For every reply that the change removes: the guarantee that it gave (order, completion, exactly once), and the code that gives it after the change. "Message order" is not enough by itself: name the one process that sees every message that the guarantee depends on.
3. Every test of the old mechanism, with the property it keeps, or why the property changes or is deleted.
4. Every property that users or clients see and that changes.
5. Every state with no bound, stated as such.

## Bounds

Every input, buffer, and wait, with its bound. A bound that does not exist yet is written as "unbounded, ticket #N", never left out. Each row names where the bound is enforced. Explain any additional checks required by transformations, accumulation, elapsed time, or rendering.

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| example: tool output | 2000 lines or 50 KB | cut on whole lines, the result says so |

Every numeric limit in this table gets a property test or, at minimum, tests at the limit, one under, one over, and a multibyte case. Every `ponytail:` marker in the implementation names a ticket.

## Ownership

Every external resource the feature touches (OS process, process group, port, file handle, socket, temp file) gets a row. A release cell that is a race is written as "open, ticket #N", the same vocabulary as an unbounded input, never left out (see ADR 0004).

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| example: command process group | bash tool launcher | hands | hands kill on delivery | hands kill on delivery of the crash result | hands kill on cancel |

A row whose holder is a Task is a design flag: the spec axis raises it before implementation, because a Task dies with its state and takes the only reference to the resource with it.

## Out of scope

What this feature deliberately does not do, and which ticket owns it.
