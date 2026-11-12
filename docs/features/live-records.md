# Live records

Ticket #957, slice 1. Part of `docs/features/hub.md` and
`docs/features/wire-protocol.md`; the server work builds on
`docs/features/session-feed.md`.

## Goal

A client gets the records of the sessions of its user as they change, and
never polls. A session that a client, a schedule, or a coordinator starts
appears in a sidebar at once. A turn that runs shows `"running"`. A tool that
asks a question shows `"waiting"` and moves to the top. An answer on another
device turns it back to `"running"`. A session that stops shows `"stopped"`.

The client asks once, gets the ordered list, and applies one event for each
change: new, changed, removed. This slice builds the server side, the wire
contract with its fixtures, and the fold in the Rust client core. The sidebar
views of the desktop app and of the iOS app are a later slice.

User stories:

- A user opens the desktop app and sees its sessions. Another client starts a
  session in the same Core, and the session is in the list before the next
  redraw.
- A session of the list asks a question. Its row says that it waits for the
  user and moves above the recent idle sessions, on every open client of that
  user.
- A phone answers the question, and the row of the desktop app leaves the
  waiting state.
- A session stops, and its row says `"stopped"`.

## Interface changes

### The wire

One new operation pair, `records.subscribe` and `records.unsubscribe`, on the
same connection. The subscription belongs to the user of the connection and
holds only the records that the user owns, as the sidebar of the user: unlike
`hub.records.search`, it does not carry the `"hub"` records of other users.

- `records.subscribe` takes no params and answers
  `{records: [record], more: bool}`. `records` is ordered: the sessions that
  wait for the user first, then by `active_at`, newest first, then by session
  id, ascending. `more` is true when the user owns more records than the
  reply holds.
- After the reply the server sends one frame for each change of a record:

  ```text
  {type: "record", change: {kind: "new" | "changed", record: record}}
  {type: "record", change: {kind: "removed", session: string}}
  ```

  A `"new"` event names a record that the client did not hold; `"changed"`
  gives the whole record, so the client replaces it in place. A client that
  gets a `"changed"` event for an id that it does not hold adds it.
- A slow client gets a full list again, so its state is correct with no gap:

  ```text
  {type: "records", records: [record], more: bool}
  ```

  The client replaces its list with it.
- The subscription ends without the client's unsubscribe when the Hub process
  that holds it ends, such as a restart of Hub under its supervisor: the
  server sends

  ```text
  {type: "records_end"}
  ```

  as the last frame of the feed, the connection holds no records subscription
  after it, and the client subscribes again. The rows that it holds stay until
  the new reply.
- A connection holds at most one records subscription. A second
  `records.subscribe` answers `too_many_subscriptions`.
- `records.unsubscribe` takes no params and answers `{}`. The connection holds
  no records subscription after it. An unsubscribe with none answers
  `unknown_sub`, as it does on a server with no Hub: a client that never
  subscribed has no subscription to end.
- The `record` shape is the one of `hub.records.*` (`docs/features/hub.md`,
  decision 8) with one change: `status` is `"idle" | "running" | "waiting" |
  "stopped"`. The shape stays one shape: every operation that returns a
  record carries `"waiting"` when a session has an open ask. `live_session`
  keeps its `"idle" | "running"`.
- A server with no Hub answers `records.subscribe` with `unknown_op`, as it
  answers every `hub.*` operation, and `records.unsubscribe` with
  `unknown_sub`. A transport whose authority exports no `records/3` callback
  answers `records.subscribe` with `unknown_op` too.

The order rule O7: the `records.subscribe` reply comes before every `record`,
`records`, and `records_end` frame of the connection, and no such frame comes
after the `records.unsubscribe` reply. `records_end` is the last frame of the
feed.

### The status `"waiting"`

The status is derived, never stored. A session with at least one open ask has
`"waiting"`; otherwise the live set gives `"idle"`, `"running"`, or
`"stopped"` (`Helyx.Hub.Live.status/2`).

`Helyx.Hub.RecordFeed` keeps the ids of the open asks of each live session from
the `:ask` and `:ask_end` events of the session feed. Hub names those two
types in its `Helyx.Sessions.watch/2` call. The `Helyx.Sessions.Live` notice
carries no ask, so the set is seeded from the session snapshot
(`Helyx.Session.subscribe/2` with `tail: 1`, then the task ends and the
session drops the subscriber):

- the read of the live sessions runs in one Task outside the Hub process, so
  a session that does not answer blocks the Task, never the Hub. The Hub
  starts it at its start and at a poll that finds a pending read or a new
  drop of the feed, and takes its result as a message. At most one read runs;
- the Task reads `Helyx.Sessions.list_live/1` under the seed bound, then one
  snapshot of each live session under the same bound, each session in a Task
  of its own. A snapshot that does not answer is `:error` for that session:
  the seed keeps its old set, and the read stays pending, so the next poll
  reads again;
- a read that fails or passes its bound keeps the live set, the ask sets, and
  the feed count, and stays pending; the next poll reads again. So the start
  path and the repair path are one mechanism;
- the snapshot is the baseline, and the `:ask` and `:ask_end` notices that
  wait in the mailbox of the Hub process are applied after the seed: adding or
  removing an ask id is idempotent, so the set is right without an epoch.

With no records subscription, Hub writes no record view and sends no frame.
It keeps the open-ask set from the feed: one map update for each `:ask` and
`:ask_end` that the feed sends it, and no store query.

### The server

- `Helyx.Hub.RecordFeed` (new, internal): the subscribers of the records
  feed in the state of the Hub process, the ordered list of a user, the change
  events, the full list of a slow subscriber, the open-ask sets, and the
  silent marks of the starts below. It is the only writer of `records`,
  `asks`, and `silent` in the Hub state.
- `Helyx.Hub.Server` calls `RecordFeed.changed/3` after each write or derived
  change of a record: the row of a `Live` of the feed, a start of a user who
  is not the default owner, a resume, a prompt, a steer, a follow-up, a record
  get that writes a row, a record update, a record delete, an `:ask`, an
  `:ask_end`, a wake-up that the session took, and the `:DOWN` of a session.
  A scan of `sessions.saved` and the scan of a `resume` of a folder send the
  full list to the default owner, since each can write 256 rows at once, and
  a project delete sends the full list to its owner, since its records lose
  the project. No one place wraps every write: the writes go through the
  `Helyx.Hub.Store` behaviour from `Helyx.Hub.Records`, `Helyx.Hub.Rules`,
  `Helyx.Hub.Wake`, and the server, and the feed needs the row before a
  delete, the two owners of a move, and whether a row existed for the kind of
  its change, which a store wrapper cannot give without reading the row on
  each write itself. Each write path names its change, and a test covers each
  one.
- **A start of another user.** A `start` of a user who is not the default
  owner holds a reserved place of `Helyx.Hub.Live` (`record?: true`), and the
  place names no session id. A `Live` of a session with no row while such a
  place is in flight cannot be told from that start, so its row is written
  and its first change is **silent**: no client is told. The `result` of the
  start knows the owner; it sends the record to that owner, and, if the row
  was the default owner's, the removal to the default owner's subscribers
  only. A silent row is in **no** list: the live frames and every full list
  (the first reply, a refresh, the poll) ask the same visibility rule, so the
  default owner never sees the id of another user's start. A removal never
  names the id to a user who could not have held the record: a record delete
  and a wake-up that loses its file tell the subscribers of the owner that the
  row had.
- `Helyx.Hub.LiveRead` (new, internal) reads the live sessions in a Task
  outside the Hub (`maybe_read/1`) and the Hub takes the result as a message,
  so a session that does not answer blocks the Task, never the Hub. `seed_pending`
  is the one mechanism of the start and the repair: a read that fails or is
  killed leaves it set, and the next poll starts a read. A per-session
  snapshot that does not answer is `:error`, which keeps that session's set
  and leaves the read pending.
- `Helyx.Hub.Store` gains `owned/3` (the rows of an owner, newest
  `active_at` first, at most a limit) and `rows/2` (the rows of a list of
  session ids). `Helyx.Hub.Store.SQLite` implements them.
- `Helyx.Hub.Records` gains `views/3` (the public form of its batch view) and
  `wire/1` (a record as the wire shows it), so every answer of a record uses
  one shape.
- `Helyx.Hub.Access` implements the optional authority callback
  `records/3`: it makes one Hub call, returns the reply of
  `records.subscribe` and the Hub process that it registered, or the error of
  the wire. The subscribe is one Hub call; a change is a message from the Hub
  process to the records process, which writes it. The Hub process builds the
  record view and decides the subscribers.
- `Helyx.Transport.WebSocket.Authority` gains the optional callback
  `records/3` (`arg`, `auth`, the pid of the records process).
- `Helyx.Transport.WebSocket.Records` (new, internal): one process under the
  connection, like a session subscription. It calls the authority, replies
  with the list once, writes each change, monitors the Hub process, and ends
  at the unsubscribe, at the end of its Hub (with `records_end`), or with the
  connection.
- `Helyx.Transport.WebSocket.Connection` gains the two ops and the writer kind
  `{:records, req, unsub, slot}`. It holds at most one records writer that is
  not unsubscribing. The unsubscribe reply removes the writer before it goes,
  and a `records_end` removes it before the frame goes, so a subscribe that
  follows either finds a free place.
- Core does not change: the feed already sends `Live`, `:ask`, and `:ask_end`,
  and the session snapshot already holds the open asks.

### The client core (Rust, `clients/rust/core`)

- `operation`: `Operation::records_subscribe()` and
  `Operation::records_unsubscribe()`, with `{}` params and the 6,000 ms
  deadline of every other operation.
- `frame`: `Reply::Records { records, more }` for the reply of
  `records.subscribe`, and `ServerFrame::Record(RecordFrame)` for the
  `record` and `records` frames. A record frame is checked by the schema; a
  `record` frame before the reply or after the unsubscribe is a break.
- `records` (new): `Record`, `User`, `Parent`, `Visibility`, `Status`,
  `Change`, and `Feed`. `Feed::subscribed` replaces the list;
  `Feed::applied` applies a change; `Feed::rows` gives the ordered rows with
  id, prompt, folder, model, status, parent link, and activity time.
- `client`: the reply replaces the feed, a `record` frame applies it, and a
  `records` frame replaces it again. `Client::records()` reads it. The host
  sends the subscribe after a welcome, as it sends any operation; a
  re-subscribe on a new connection is the host's call in this slice.
- `test/fixtures/wire/records.json` (new) holds the reply, the frames, and the
  folds. `clients/rust/core/tests/records.rs` runs them.

## Bounds

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| records in the first reply, and in a full list | `Helyx.Hub.RecordFeed.max_reply/0`: the page of `page/0` read from `record_page` of `test/fixtures/wire/bounds.json`, plus the live records of the user outside it, at most `max_live/0` read from `record_live` (64, the Core cap) | the reply holds the page and every live record of the user, and `more: true` when the user owns more than the page; the client learns that more exist from `more` and reads the rest with `hub.records.search` | Hub |
| change events that wait for one subscriber | `Helyx.Hub.RecordFeed.max_pending/0`, read from `record_pending` of `bounds.json`: the mailbox of the records process at that length | Hub drops the changes that wait and sends a full list at the next poll; the client is correct with no gap | Hub |
| a burst of changes of one record while its send waits | one change: the newest value is built when it goes | n/a | Hub |
| the full list after a drop, and the first list after a `records_end` | one frame of at most `max_reply/0` records, sent at the next poll, `Helyx.Hub.Wake.poll_ms/0` (1,000 ms) after the client drains | the next poll tries again | Hub |
| records subscriptions of a Hub | `Helyx.Hub.RecordFeed.max_subscribers/0`, read from `record_subscribers` of `bounds.json`: the 64 connections of the transport, one subscription each | `busy` at the subscribe | Hub |
| open asks of a session | one for each call that waits; Core bounds the calls of a turn (the concurrency of its tools) | n/a | Core |
| the read of the live sessions | one Task at a time, outside the Hub: `Helyx.Hub.LiveRead`'s `@seed_ms` for `Helyx.Sessions.list_live/1` and `@seed_ms` for its snapshots, `@read_ms` in all, and the Hub kills it at `@read_ms` + `@kill_margin_ms` | the Hub never waits for it; a killed or failed read stays pending, and the next poll reads again | Hub |
| the snapshot of one session | its own Task for `@seed_ms`; one that does not answer is `:error` in the seed | the set of that session stays, and the read stays pending, so the next poll reads again | Hub |
| the rows in a seed snapshot | `tail: 1`, so one message; the asks are the snapshot's | n/a | Core |
| the reply of `records.subscribe` | the 6,000 ms of every other operation: one Hub call of 5,000 ms | `timeout` | the transport, Hub |
| records in the fold of the client | `records`'s `MAX_ROWS`: the first page plus the changes, and when a change passes it the fold drops the oldest stopped record, then the oldest record that does not wait | the fold stays at `MAX_ROWS` rows | the client core |
| the cost with no records subscription | no store query, no record view, no frame; one map update for each `:ask` and `:ask_end` of the feed, which the feed sends to the Hub's watcher | n/a | Hub |

A send to a records subscriber never blocks the Hub: it reads the mailbox of
the process, sends a message, or drops the change for the full list. The
outbound queue of the connection keeps its own bound of 64 MiB, over which
the transport closes with `4408` (`docs/features/wire-protocol.md`,
"Bounds"); a slow client costs one full list at a poll and no store work in
the Hub for its changes.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| a records subscription of a connection | `records.subscribe` in the connection | the connection, as a linked writer; a process of the transport | `records.unsubscribe`, `records_end`, or the end of the connection | the connection monitor of the writer; the connection ends | the connection kills its writers |
| a records subscriber of Hub | the Hub call of `records/3` | the Hub process, with a monitor of the records process | the `:DOWN` of the process | the `:DOWN` | n/a |
| the monitor of the Hub by a records process | `Process.monitor/1` in the records process | the records process | the `records_end` that the `:DOWN` sends; the process ends | the process ends | the connection kills it |
| the open-ask sets and the silent marks | the `:ask` and `:ask_end` notices, the read Task, and a `Live` of a start in flight | the Hub process | the `:DOWN` of the session removes its set; the stop of Hub frees them | gone with Hub; the next start seeds the sets | n/a |
| the read Task of the live sessions | `Helyx.Hub.LiveRead.maybe_read/1` | the wake supervisor of Hub, with a timer | its result message; the Hub kills it at `@read_ms` + `@kill_margin_ms` | its snapshot Tasks die with it, and the next poll reads again | the stop of Hub, and the kill of its timer |
| the snapshot subscription of a read | the read Task, one for each live session | the snapshot Task | the Task ends, and the session drops the subscriber at its `:DOWN` | the Task dies, and the session drops the subscriber | the read Task is killed, and its Tasks die with it |

## Replaced mechanism

None. `hub.records.search` and `sessions.saved` stay for a page, a query, and
the older sessions of the user; the new feed neither pages nor filters.

## Out of scope

- The sidebar views of the desktop app and of the iOS app.
- Push notifications (ticket #916 uses the same "waits for the user" fact).
- A subscription to the records of other users, of a team, or of the `"hub"`
  sessions of other users.
- A title of a session other than its first prompt.
- A durable feed: a connection that ends subscribes again and gets the list,
  and Hub holds no history of changes.
- A page of the records feed beyond the first: a client that needs the
  records past `more` reads `hub.records.search`.
