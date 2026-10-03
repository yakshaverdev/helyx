# Session instance

## Goal

A client can tell the events of one session instance from those of another instance with the same session id. Issue #204, split out of #188 (review record `docs/reviews/2026-09-27-188-session-not-found.md`, round 4).

Without an instance id, two cases break a client:

- **Resume.** A resume reuses the session id and starts `seq` at 0. Its subscribers are new, so a client subscribes again, and events of the old instance can still be in its mailbox.
- **Two Cores.** Two Cores that resume one `sessions_dir` hold one id. A caller subscribed to both gets events with the same id and overlapping `seq` values from each. Both Cores write to the one session file, and each writes its own branch: the `parent_id` of an entry is the leaf of its own Core, and the reader follows `parent_id`, so the two conversations do not mix (#266, `docs/features/coding-agent.md`, "Session file").

## Decision

- Each start of a session process makes a new instance id, `Helyx.Session.Id.new/0` in `Helyx.Session.Server.init/1`: a start, and each resume. It is not written to the session file.
- Every event and every snapshot carry it as `instance_id`.
- **The client rule:** a client that reconnects drops every event whose `instance_id` is not the one of its snapshot, and then every event with a `seq` at or below the snapshot's `seq`. `seq` increases by one per event within an instance.
- **No Core in the event.** The instance id is random (72 bits) for each process start, so the instances of two Cores already differ, and the client rule needs nothing more. A Core name is a module atom of the server's configuration, which a remote client cannot use.
- **No mailbox drop at subscribe.** A subscribe does not drop queued events of other instances from the caller's mailbox: the client rule drops them at the client, for a local and a remote client alike.
- The TUI does not apply the client rule: it subscribes once (ADR 0006, revision of 2026-10-03).

## Interface changes

- `Helyx.Event` gets the enforced key `instance_id :: String.t()`.
- `Helyx.Session.Snapshot` gets the enforced key `instance_id :: String.t()`.
- ADR 0006, section 3 states the client rule.

## Bounds

| What | Bound | Where enforced | Over the bound |
| --- | --- | --- | --- |
| `instance_id` | 12 bytes, URL-safe Base64 of 9 random bytes | `Helyx.Session.Id.new/0` | n/a: the server makes it |

No new input, buffer, or wait. The TUI renders no instance id.

## Ownership

No external resource.

## Tests

- Core: a start and a resume of the same id give different instance ids, and each event of an instance carries the instance id of its snapshot.
- Core, the two-Core case: two Cores resume one `sessions_dir`; one caller subscribes to both. A subscribe to the id in Core B leaves the events of Core A in the mailbox, and every event carries the instance id of the snapshot of its Core.

## Out of scope

- The end signal: since #434 it is the `:DOWN` of the caller's own monitor ref (`docs/features/end-signal.md`), so a subscribe in one Core touches no signal of a session in another Core.
- A `seq` that continues across a resume, and a session id that is unique in the node. Both were considered in #204 and not chosen.
