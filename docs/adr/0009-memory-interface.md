# A Memory interface: recall and sync

Ticket #650 (decided by the owner, 2026-10-17). Design: `docs/features/memory.md`.

## Context

A product that wanted memory wrote its own ModelContext and its own fence for untrusted recall. A ModelContext runs before compaction, so its recall went into a summary, or nothing was recalled after compaction. A subscriber gets the messages, but not whether each one was saved, and no path brings a missed message back after a restart. Each product would build the same fence, the same order, and the same replay.

## Decision

The extension surface gets a fifth interface, `Helyx.Memory`, mode `:single`, with two callbacks:

- `recall(query, opts)` returns records `%{id, source, text}`. Core calls it before each model call, after the ModelContext and the Compaction plugin, in a Task with a limit. Core checks the records, escapes them, and adds one fenced user message at the end of the context of that call only.
- `sync(messages, opts)` gets every message that joins the transcript, with its id, origin, stop reason, and whether its append to the session file succeeded. Core calls it off the session process, in order for one session instance: a replay of the file at a resume, then one batch at each turn end.

Core owns recall and sync: the fence, the bounds, the order, and the replay. The plugin owns its storage, its query policy, and what it skips. It removes duplicates by message id. A memory tool is a `Helyx.Tool` in the same module. There is no hook before compaction and none at the session end.

## Consequences

- `AGENTS.md` and the README list Memory with Provider, Tool, ModelContext, and Compaction.
- A slow or failing recall does not fail the turn; a return of a wrong shape does.
- Every persisted message reaches `sync/2` at least once if the session resumes later. A file that is never resumed is never replayed.
- A change to `:multi` keeps the callbacks; the rules to combine several plugins are decided then.
- The bundled reference plugin is `Helyx.Memory.Markdown`, a folder of markdown files.
