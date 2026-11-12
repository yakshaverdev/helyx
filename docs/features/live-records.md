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
- A connection holds at most one records subscription. A second
  `records.subscribe` answers `too_many_subscriptions`.
- `records.unsubscribe` takes no params and answers `{}`. The connection holds
  no records subscription after it. An unsubscribe with none answers
  `unknown_sub`.
- The `record` shape is the one of `hub.records.*` (`docs/features/hub.md`,
  decision 8) with one change: `status` is `"idle" | "running" | "waiting" |
  "stopped"`. The shape stays one shape: every operation that returns a
  record carries `"waiting"` when a session has an open ask. `live_session`
  keeps its `"idle" | "running"`.
- A server with no Hub answers `records.subscribe` with `unknown_op`, as it
  answers every `hub.*` operation. A transport whose authority exports no
  `records/3` callback answers the same.

The order rule O7: the `records.subscribe` reply comes before every `record`
and `records` frame of the connection, and no such frame comes after the
`records.unsubscribe` reply.

### The status `"waiting"`

The status is derived, never stored. A session with at least one open ask has
`"waiting"`; otherwise the live set gives `"idle"`, `"running"`, or
`"stopped"` (`Helyx.Hub.Live.status/2`).

`Helyx.Hub.RecordFeed` keeps the ids of the open asks of each live session from
the `:ask` and `:ask_end` events of the session feed. Hub names those two
types in its `Helyx.Sessions.watch/2` call. The `Helyx.Sessions.Live` notice
carries no ask, so the set is seeded from the session snapshot
(`Helyx.Session.subscribe/2` with `tail: 1`, then the Task ends and the
session drops the subscriber):

- at the start of Hub, and at each repair of a dropped feed notice, one Task
  reads the live sessions and their snapshots, under the seed bound of
  `Helyx.Hub.Server` (5,000 ms);
- a seed replaces the set of a session only when no `:ask` or `:ask_end`
  notice of that session came while the seed ran. A session with a notice
  keeps the notices, which are newer; the epoch of the notices says which.

With no records subscription, Hub writes no record view and sends no frame.
It keeps the open-ask set from the feed: one map update for each `:ask` and
`:ask_end` that the feed sends it, and no store query.

### The server

- `Helyx.Hub.RecordFeed` (new, internal): the subscribers of the records
  feed in the state of the Hub process, the ordered list of a user, the change
  events, the full list of a slow subscriber, and the open-ask sets. It is
  the only writer of `records`, `asks`, and `ask_epoch` in the Hub state.
- `Helyx.Hub.Server` calls `RecordFeed.changed/3` after each write or derived
  change of a record: the row of a `Live` of the feed, a start of a user who
  is not the default owner, a resume, a prompt, a steer, a follow-up, a
  record update, a record delete, an `:ask`, an `:ask_end`, and the `:DOWN` of
  a session. A scan of `sessions.saved` sends the full list to the default
  owner, since it can write 256 rows at once.
- `Helyx.Hub.Store` gains `owned/3` (the rows of an owner, newest
  `active_at` first, at most a limit) and `rows/2` (the rows of a list of
  session ids). `Helyx.Hub.Store.SQLite` implements them.
- `Helyx.Hub.Records` gains `views/3` (the public form of its batch view) and
  `wire/1` (a record as the wire shows it), so every answer of a record uses
  one shape.
- `Helyx.Hub.Access` implements the optional authority callback
  `records/3`: it makes one Hub call and returns the reply of
  `records.subscribe`, or the error of the wire. The subscribe is one Hub
  call; a change is a message from the Hub process to the records process,
  which writes it.
  - The Hub process builds the record view and decides the subscribers.
- `Helyx.Transport.WebSocket.Authority` gains the optional callback
  `records/3` (`arg`, `auth`, the pid of the records process).
- `Helyx.Transport.WebSocket.Records` (new, internal): one process under the
  connection, like a session subscription. It calls the authority, replies
  with the list once, writes each change, and ends at the unsubscribe or with
  the connection.
- `Helyx.Transport.WebSocket.Connection` gains the two ops and the writer kind
  `{:records, req, unsub, slot}`. It holds at most one records writer that is
  not unsubscribing.
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
| records in the first reply, and in a full list | `Helyx.Hub.RecordFeed.page/0`, read from `record_page` of `test/fixtures/wire/bounds.json`: the newest in the order of "The wire", with every live record of the user of the reply included | the reply holds the newest page and `more: true`; the client learns that more exist from `more` and reads the rest with `hub.records.search` | Hub |
| change events that wait for one subscriber | `Helyx.Hub.RecordFeed.max_pending/0`, read from `record_pending` of `bounds.json`: the mailbox of the records process at that length | Hub drops the changes that wait and sends a full list at the next poll; the client is correct with no gap | Hub |
| a burst of changes of one record while its send waits | one change: the newest value is built when it goes | n/a | Hub |
| the full list after a drop | one frame of at most `page/0` records, sent at the next poll, `Helyx.Hub.Wake.poll_ms/0` (1,000 ms) after the client drains | the next poll tries again | Hub |
| records subscriptions of a Hub | `Helyx.Hub.RecordFeed.max_subscribers/0`, read from `record_subscribers` of `bounds.json`: the 64 connections of the transport, one subscription each | `busy` at the subscribe | Hub |
| open asks of a session | one for each call that waits; Core bounds the calls of a turn (the concurrency of its tools) | n/a | Core |
| the seed of the open-ask sets | one Task of `Helyx.Hub.Server`'s `@seed_ms` (5,000 ms) that reads `Helyx.Sessions.list_live/1` and one snapshot of each live session; past it the sets stay as they are | the repair at the next poll reads them again | Hub |
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
| a records subscription of a connection | `records.subscribe` in the connection | the connection, as a linked writer; a process of the transport | `records.unsubscribe`, or the end of the connection | the connection monitor of the writer; the connection ends | the connection kills its writers |
| a records subscriber of Hub | the Hub call of `records/3` | the Hub process, with a monitor of the records process | the `:DOWN` of the process | the `:DOWN` | n/a |
| the open-ask sets | the `:ask` and `:ask_end` notices, and the seed Task | the Hub process | the `:DOWN` of the session removes its set; the stop of Hub frees them | gone with Hub; the next start seeds them | n/a |
| the snapshot subscription of a seed | the seed Task | the Task | the Task ends, and the session drops the subscriber at its `:DOWN` | the Task dies, and the session drops the subscriber | the Task is killed at `@seed_ms` |
| the monitor of a records process | `RecordFeed.subscribe/3` | the Hub process | the `:DOWN` | the `:DOWN` | n/a |

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
