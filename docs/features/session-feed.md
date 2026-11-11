# Session feed

Ticket E.1, part of the server work of `docs/features/hub.md` and
`docs/features/server-management.md`.

## Goal

A product sees the lifecycle and the chosen events of every session of a Core
without a subscription to each one, and Core names no consumer. Before this, a
consumer that observes many sessions subscribed to each: one call and one
snapshot to join, one send for every event with the deltas, and one ack for each
1,024 events. Hub needs the session lifecycle and nothing else, and it held no
session subscription at all; a session that started outside Hub was invisible
to it (`hub.md`, old decision 8).

The feed is one duplicate-key `Registry` per Core. Each session sends its
`Helyx.Sessions.Live` at its open and at each change of status or model, and
each event to the watchers of its type. `Helyx.Event` stays data: Core names no
consumer, a type that no watcher names costs one ETS lookup, and the notice is
built only when its key changed.

User stories:

- Hub writes the record row of a session at its start and at each change of
  status or model, from a start through Hub and from a start with the session
  API too (`hub.md`, decisions 8 and 14).
- A search index observes `:message_end` of every session of the Core and
  rebuilds from `list_live/1` after a drop, with no subscription to each
  session (E.7).

## Interface changes

`Helyx.Sessions`:

- `watch(core, types)` registers the calling process and returns
  `{:ok, counter}` or `{:error, :invalid_types}`. A second `watch/2` by the
  same process replaces the first. A `core` that is not running raises
  `ArgumentError`, as `Registry.register/3` does.
- `unwatch(core)` ends the notices of the caller.
- `dropped(counter)` gives the number of notices that the feed dropped for the
  watch.
- `max_feed_queue()` is the mailbox length of a watcher at which the feed
  drops its notices.

The process that watches gets two message shapes, each from the session
process:

```text
{:helyx_feed, session_pid, %Helyx.Sessions.Live{}}
{:helyx_feed, session_pid, %Helyx.Event{}}   # a type that the watcher named
```

The order rules:

- Per session, the order is the send order. The first `Live` of an instance
  comes before every event of that instance, and a `Live` with a new status
  comes before the events of that status, such as `running` before
  `:turn_start`. Notices of two sessions have no order between them.
- There is no stop notice. A watcher monitors `session_pid`; the `:DOWN` comes
  after every end, a kill too, and `Helyx.Session.end_reason/1` maps its
  reason.
- A watcher that starts late or restarts calls `watch/2` first, then
  `list_live/1`. Notices that arrive during the list wait in the mailbox, and
  a notice for a pid always follows the register, so it wins over the list for
  that pid.

`Helyx.Event.types/0` gives every event type, the source of the check in
`watch/2`.

`Helyx.Sessions.Live` also carries `parent`: nil, or the session id and call
id of the tool call that started a child session
(`docs/features/agent-tool.md`). A start takes it from its `:parent` option,
and a resume from the `parent` of the session file's header; a link that does
not pass its check is dropped, so a damaged header link costs the session no
resume. `Helyx.Hub` writes it into the record of the session
(`hub.md`, decision 8). The wire `live_session` does not carry it.

`Helyx.Session.Server.State` gains `fed`, the key of the last `Live` that the
feed sent, or nil. It is internal.

`Helyx.Session.Server.Feed` is internal and runs in the session process:

- `sync/1` compares `{instance_id, idle?, model}` with `fed` and sends the
  `Live` when the key changed, so the compare builds no text. It runs before
  the event that a session emits and at the end of each callback, because a
  status can change with no event, as at the end of a wait.
- `event/2` sends the event to the watchers of its type.
- `live/1` builds the `Live` that `Calls.handle(:live, ...)` answers with, so
  the status has one definition.

`Helyx.Core.feed_registry/1` is the Registry of the feed of a Core. It is a
child of Core after the sessions Registry and before the session supervisor, so
the supervisor stops it after every session.

## Replaced mechanism

None in Core. The Core code path that lists sessions for one consumer
(`Helyx.Sessions.list_live/1`) stays, as the repair path and the seed.

The Hub changes are in `hub.md`: the rows that Hub writes at a start and at the
scan of `sessions.saved`, the live set that holds every session of the Core,
and the removal of `Hub.Records.derived_view/2`, `new_row/4`, `without_row/3`,
`Hub.Saved.merge/4`, and `Hub.Live.seed/2`. The feed itself changes neither
the wire nor the store schema; the record shape of the wire is E.2
(`hub.md`, `wire-protocol.md`, protocol 11).

## Bounds

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| the mailbox of one watcher | `Helyx.Sessions.max_feed_queue/0` notices: a watcher that runs behind by that many is stuck, and its notices stay under about 256 KiB | the session drops the notice and adds one to the counter of the watch; `dropped/1` reports it, and the watcher repairs its view with `list_live/1` | the session process |
| the notices of a watcher in flight | the bound above, plus at most one notice for each of the other sessions: the 64 sessions check and send with no lock between them, so the mailbox can pass the bound by at most 63 notices. Stated, not a defect | as above | the session processes |
| the watchers of a Core | unbounded: a product starts its own, and Hub starts one. Each costs one `Process.info/2` and one send for each notice that it watches | n/a | the product |
| the types of one watch | at most `length(Helyx.Event.types())` | `{:error, :invalid_types}` | `Helyx.Sessions.watch/2` |
| the cost of an event with no watcher of its type | one Registry lookup | n/a | the session process |
| a send of the feed | none: the session never waits for a watcher, and holds no state for one | n/a | `Helyx.Session.Server.Feed` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| an entry of the feed Registry | `watch/2` in the watcher | the Registry of the feed | `unwatch/1` | the Registry removes the entries of the process that exits | n/a |
| the counter of a watch | `watch/2` | the Registry entries of the watch, and the caller | garbage collected with the last reference | the same | n/a |
| the feed Registry | the Core | the Core | the stop of the Core | the stop of the Core | n/a |

## Out of scope

- `session_wait` and the search index on the feed: follow-ups.
- Idle unload of a session: its own ticket.
- A stop notice: the monitor of the session process gives the end.
- The `starters` actor semantics of `coordinator.md`, decision 3.
- A reconcile scan at the start of Hub: the seed and the repair path cover it.
- The record shape on the wire: `docs/features/hub.md` and
  `docs/features/wire-protocol.md`, protocol 11.
