# The session holds its subscribers

## Goal

The session process keeps the list of its subscribers and sends each event to them (#297). The caller side of `subscribe/1`, its monitor ref and the end signal, is in `end-signal.md`.

## Design rules

**S1 Subscribe.** `subscribe/2` is one call to the session, `{:subscribe, pid, ref, tail, after}`, with a nil `tail` for the full snapshot and a nil `after` for no replay. In one step, the session adds the caller to its subscriber map and returns the snapshot, or the events after `after` from the replay ring (`replay-ring.md`). Every event after the reply reaches the caller, because both happen in one message of the session.

**S2 One entry and one monitor per caller.** The map is keyed by pid. Its value is `{monitor, ref, acked}`: the session's monitor reference for that pid, the caller's `ref` of its last subscribe, and the `seq` up to which the caller acked. A repeated subscribe from the same pid reuses the entry and its monitor, takes the new `ref` and fresh credits (`replay-ring.md`), and makes no new monitor (`Helyx.Session.Server.Events.subscribe/5`). So each live event comes once; a replay can repeat events that the caller has, and the caller drops each event at or below the `seq` that it applied, after it passes the event to `ack/2`. `{:unsubscribe, pid}` removes the entry and calls `Process.demonitor(monitor, [:flush])` (`Events.unsubscribe/2`). For a pid with no entry, it changes nothing.

**S3 Events.** The session sends each event to each pid in the map that has credits. Past 16,384 unacked events it sends `{:helyx_end, ref, :slow}` in place of the event and removes the entry with its monitor (`replay-ring.md`).

**S4 A subscriber ends.** At a `:DOWN`, the session removes the entry of that pid only when the entry holds the same monitor reference (`Helyx.Session.Server.handle_info/2`).

## Bounds

| What | Bound | Over the bound |
|---|---|---|
| Subscribers of one session | no count bound; each has a credit bound of 16,384 unacked events (ADR 0008, `replay-ring.md`) | the session ends that subscription with `:slow` |
| Monitors held by the session | one per subscriber pid (S2) | a repeated subscribe reuses the monitor |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes |
|---|---|---|---|---|
| The session's monitor of a subscriber | `{:subscribe, pid, ref, tail, after}` | the session | `{:unsubscribe, pid}`, demonitor with flush, the slow end, or the subscriber's `:DOWN` | the session ends, so its monitors end |

## Out of scope

- None left of #659: the credits and the replay ring are in `replay-ring.md`.
