# Session instance

> The ADR 0006 revision of 2026-10-03 (#404) removes `contract_version`, and the TUI drops its `instance_id` and `seq` guards, because it subscribes once. The `instance_id` in events and the snapshot, and the rule of ADR 0006 section 3 for a client that reconnects, stay. The text below on the TUI guard and the contract version is history.

## Goal

A client can tell the events of one session instance from those of another instance with the same session id. Issue #204, split out of #188 (review record `docs/reviews/2026-09-27-188-session-not-found.md`, round 4).

User story: I keep a client subscribed to a session. The session ends and a resume starts it again with the same id. My client never applies events of the new instance against the snapshot of the old one, and a subscribe to a session with the same id in another Core never touches my events from the first Core.

Today an event and a snapshot carry the session id, but not the instance. Two cases break a client:

- **Resume.** A resume reuses the session id and starts `seq` at 0. The events Registry has the key `id`, so a subscriber that keeps its entry past the end of the old instance gets the events of the new one, and compares their `seq` with the old snapshot.
- **Two Cores.** Two Cores that resume one `sessions_dir` hold one id. A caller subscribed to both gets events with the same id and overlapping `seq` values from each. Both Cores write to the one session file, and each writes its own branch: the `parent_id` of an entry is the leaf of its own Core, and the reader follows `parent_id`, so the two conversations do not mix (#266, `docs/features/coding-agent.md`, "Session file").

## Decision

- Each start of a session process makes a new instance id, `Helyx.Session.Id.new/0` in `Helyx.Session.Server.init/1`: a start, and each resume. It is not written to the session file.
- Every event and every snapshot carry it as `instance_id`.
- **The client rule:** a client drops every event whose `instance_id` is not the one of its snapshot, and then every event with a `seq` at or below the snapshot's `seq`. `seq` increases by one per event within an instance.
- **No Core in the event.** The ticket names "an instance id (and the Core)". The instance id is random (72 bits) for each process start, so the instances of two Cores already differ, and the client rule needs nothing more. A Core name is a module atom of the server's configuration, which a remote client cannot use.
- **No mailbox drop at subscribe.** The ticket leaves open whether a subscribe drops queued events of other instances from the caller's mailbox. It does not: the client rule drops them at the client, for a local and a remote client alike, and a drop in `subscribe/1` matched the id and not the Core, which #188, round 4 found. #188 removed that drop, and this change does not bring it back.
- `contract_version` stays 1. The field is an addition, and the TUI, the only client of version 1, moves to the rule in this change. This is the same reason as #189 (`docs/features/end-signal.md`, "Out of scope").

## Interface changes

- `Helyx.Event` gets the enforced key `instance_id :: String.t()`.
- `Helyx.Session.Snapshot` gets the enforced key `instance_id :: String.t()`.
- `Helyx.TUI.ViewModel` gets the field `instance_id`. `from_snapshot/1` sets it, and `apply/2` drops an event of another instance before the `seq` check.
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
- Core, the resume case: a subscriber that keeps its entry across a stop and a resume gets the events of the new instance, and each has the new instance id, not the one of its old snapshot.
- Core, the two-Core case: two Cores resume one `sessions_dir`; one caller subscribes to both. A subscribe to the id in Core B leaves the events of Core A in the mailbox, and every event carries the instance id of the snapshot of its Core.
- TUI: a view model from a snapshot does not change for an event of another instance, also one with a higher `seq`; the TUI after a stop and a resume with the same id does not change its screen for an event of the new instance.

## Out of scope

- The end signal and the lost signal carry the session id only. The flush of an end or a lost signal in `subscribe/1` matches the id, not the Core, so a subscribe to the id in one Core can remove a signal of the caller's subscription in the other Core (`docs/features/end-signal.md`). A fix changes the shape of the end signal, a contract change that the ticket does not state: open, ticket #216.
- A `seq` that continues across a resume, and a session id that is unique in the node. Both were considered in #204 and not chosen.
