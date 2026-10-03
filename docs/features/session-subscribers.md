# The session holds its subscribers

## Goal

The session process keeps the list of its subscribers and sends each event to them (#297). The caller side of `subscribe/1`, its monitor ref and the end signal, is in `end-signal.md`.

## Design rules

**S1 Subscribe.** `subscribe/1` is one call to the session, `{:subscribe, pid}`. In one step, the session adds the caller to its subscriber map and returns the snapshot. Every event after the snapshot reaches the caller, because both happen in one message of the session.

**S2 One entry and one monitor per caller.** The map is keyed by pid. Its value is the session's monitor reference for that pid. A repeated subscribe from the same pid reuses the entry and its reference, and makes no new monitor (`Helyx.Session.Server.Events.subscribe/2`). So each event comes once. `{:unsubscribe, pid}` removes the entry and calls `Process.demonitor(ref, [:flush])` (`Events.unsubscribe/2`). For a pid with no entry, it changes nothing.

**S3 Events.** The session sends each event to each pid in the map.

**S4 A subscriber ends.** At a `:DOWN`, the session removes the entry of that pid only when the entry holds the same monitor reference (`Helyx.Session.Server.handle_info/2`).

## Bounds

| What | Bound | Over the bound |
|---|---|---|
| Subscribers of one session | unbounded, ticket #116 (flow control) | — |
| Monitors held by the session | one per subscriber pid (S2) | a repeated subscribe reuses the monitor |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes |
|---|---|---|---|---|
| The session's monitor of a subscriber | `{:subscribe, pid}` | the session | `{:unsubscribe, pid}`, demonitor with flush, or the subscriber's `:DOWN` | the session ends, so its monitors end |

## Out of scope

- Flow control for slow subscribers: #116.
- A server buffer that replays events after a `seq` (ADR 0006 §3).
