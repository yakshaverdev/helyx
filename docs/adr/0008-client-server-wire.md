# The client-server wire

One long-running Helyx server owns the sessions. The TUI, a web app, native apps, and bots are clients of that server through one wire contract. Local one-node mode is a step to this end state, not the end state. Ticket #656 (owner decisions of 2026-10-17).

User stories:

- A user opens the coding agent on the laptop, starts a long turn, closes the lid, and follows the same turn on the phone.
- A product author writes a client in another language from `docs/features/wire-protocol.md` alone, and a conformance client tells them whether it is right.

This ADR revises ADR 0006 §2, §3, §5 (as replaced on 2026-10-03), and §6, and AGENTS.md, which listed a Transport interface. The codec of every frame, the bounds with their enforcement, and the schema are in `docs/features/wire-protocol.md`.

## Context

- ADR 0006 §6 chose HTTP with Server-Sent Events as a Transport plugin. A client then needs two channels (requests and an event stream), and the server cannot see when a client has read an event.
- `Helyx.Session.subscribe/1` returns the whole transcript (`lib/helyx/session/server/events.ex:29-39`), and a reconnect takes a new full snapshot (ADR 0006 §3). A phone that joins a session of thousands of messages, or that wakes from sleep, gets all of it again.
- `Events.emit/4` sends each event with `send/2` and no bound (`lib/helyx/session/server/events.ex:66`). A subscriber that does not read grows its own mailbox without limit (#116).
- The version rule of 2026-10-03 compares a build id. Two builds with the same wire then refuse each other, and no test fails when the wire changes.

## Decision

### 1. The server, and no Transport interface

`helyx` attaches to a running server, or starts one in the background. Quitting the TUI leaves the sessions running (#661, #662).

A transport is a bundled module, `Helyx.Transport.WebSocket` (#660), not a Core interface. A product starts it in its own supervision tree. It uses only the public session API and the server-management API (#657). It reads no Registry name, no supervisor name, and no internal module. The extension surface is Provider, Tool, ModelContext, and Compaction.

Reason: a transport adds no behaviour that Core dispatches to. It is a client of Core in the same node, as the TUI is.

Push to an app that is closed is not in the transport. It belongs to a product client host.

### 2. Frames

WebSocket, one JSON object per text frame. The same objects can go over stdio, one object per line (LF): the encoder escapes every LF inside a string, so a raw LF is a frame boundary, and stdout then carries protocol frames only.

| Frame | Direction | Use |
|---|---|---|
| `hello` | client, first frame | the protocol number, and the token when the server has one |
| `welcome`, `refused` | server | the answer to `hello` |
| `req`, `res` | client, server | one operation and its one reply |
| `event` | server | one session event of a subscription |
| `session_end` | server | the end signal of a subscription |
| `ack` | client | the credits of a subscription |
| `part` | both | one piece of a frame over 1 MiB |

- A request `id` is a client string of 1 to 64 bytes, unique among the requests on the connection whose reply was not sent. It correlates a reply. It does not allow a retry: a lost reply keeps the rule of ADR 0006 §4. The result is unknown, the client subscribes again, and the user decides.
- An error is `{"code": C, "text": X}`. `code` is from a closed list (`wire-protocol.md`), and `text` is for a person. The start-error map of ADR 0006 §2 is built here.
- **Parts.** A frame whose JSON is over 1 MiB goes as `part` frames: each carries the base64 of the next piece of the JSON text of the whole frame, so that a piece can end inside a UTF-8 character and the part frame stays under 1 MiB, and the last part says so. The receiver joins the pieces in order and then reads the whole frame. A connection sends every part of one frame before any other frame. So every WebSocket frame is at most 1 MiB, and no content limit of Core has to fit a frame. Reason: a projection that cuts content to fit a frame cannot bound a legal message (a message of 8 MiB of control characters is 48 MiB of JSON, and a group of 1,024 tool results with a text block of 64 KiB each is 64 MiB), and it makes a client read content in a second step.
- An unknown `op` gets a `res` with `unknown_op`. Any other frame that the contract does not allow closes the connection with `4400`.

### 3. Operations

`sessions.live`, `sessions.saved`, `start`, `resume`, `subscribe`, `unsubscribe`, `history`, `prompt`, `steer`, `follow_up`, `abort`, `set_model`, `compact`, and `stop`. Their parameters, results, and errors are in `wire-protocol.md`.

- `resume` of a session that runs attaches to that instance (#657).
- A request runs outside the socket handler, so an `abort` that waits for its cleanup does not stop the events.
- Each operation has a deadline. Past it, the reply is `timeout`: the outcome is unknown. The request still counts against the requests in flight until its worker ends, and its late result is dropped. A `subscribe` counts against the subscriptions from its request, and against the requests in flight only until its reply.
- `abort` waits for its cleanup, as `Helyx.Session.abort/1` does, and replies `ok` also when the cleanup failed; the `notice` event "abort cleanup failed" tells the clients. `set_model` acts on the next turn.
- **Subscription owner.** Each subscription is one process under the connection. It calls `subscribe`, owns the Core subscription and its end monitor, encodes the events, and writes them to the socket in order: the `subscribe` reply first (a `timeout` too: it is the one writer of that reply), then the live events, then `session_end`. It ends at `unsubscribe`, before the `unsubscribe` reply, so no event of it follows that reply; at its `session_end`; and with the connection.
- **The end signal.** The session end is one `session_end` frame with the reason `stopped` or `crashed` (`Helyx.Session.end_reason/1`), after every event of the session. It ends that subscription; the connection stays open. A client that subscribes after the end gets `session_not_found` and shows the session as ended; the end reason is not kept. A connection that closes with no `session_end` is a lost connection.

### 4. Join and reconnect

- **Join.** `subscribe` returns a tail snapshot: the newest messages of the transcript (default 200, at most 1,000), plus the full current state: the turn partial, the model, the queue counts, `persisting`, `seq`, the usage totals, and the context-usage state (the context tokens, window, and model of the last usage, and the bytes added after it). A tail can leave out the last usage, so the totals and the context state are fields, not derived from the messages (#658).
- **Cut.** A tail holds at most `tail` messages and 16 MiB of message content. A cut is before a user or an assistant message, so an assistant message and its tool results stay together: the cut moves to newer messages until it is at such a message. When that leaves no message, the tail is the newest group alone (the last user or assistant message and the messages after it), whatever its size. So a legal session is always joinable, and a cut never fails and never drops content of the messages it holds. Parts carry any size.
- **Older pages.** `history` serves the live transcript, keyed by the message ids of #649, with the same cut. A page changes neither the totals nor the context state, does not count usage twice, and does not move the live cursor.
- **Credits.** The session counts the events that it sent to each subscriber and that the subscriber did not ack. Acks are cumulative: `ack` with `seq` acks every event up to it. Past 16,384 unacked events, the session ends that subscription with the fixed reason `:slow` and never waits (#659). The transport then closes the connection with `4408`. The client connects again and subscribes with `after`.
- **Reconnect.** `subscribe` with `after: {instance_id, seq}` returns the events after `seq` from the replay ring of the session, contiguous, and live events follow with no gap. When the instance changed, the interval is gone from the ring, or `seq` is in the future, it returns a tail snapshot instead. The client keeps the `seq` of the last event it applied, not of the last one it received. The ring records events also while no client is connected.

### 5. Bounds

Every bound has a number and the place that enforces it in `wire-protocol.md`, "Bounds". The main ones:

| Bound | Value |
|---|---|
| WebSocket frame, both ways | 1 MiB; a larger frame goes as `part` frames |
| One inbound frame joined from parts (the request size) | 25 MiB: a 4 MiB text in its worst JSON form (six bytes for each byte) plus 1 MiB for the other fields |
| Requests in flight per connection | 16; a `subscribe` until its reply |
| Subscriptions per connection | 16 |
| Connections per server | 64 |
| Live sessions per server | 64 |
| Auth wait (the `hello` frame) | 5,000 ms |
| Replay ring per session | 1,024 events and 4 MiB; 256 MiB for the server, through the live-session cap |
| Tail snapshot and page | 200 messages by default, at most 1,000, and 16 MiB of message content; or the newest group alone |
| Request results per connection | 1: a `subscribe`, `history`, or `sessions.saved` request takes the one encoder slot before it reads its data from Core, so a waiting request holds no result |
| Credits per subscriber | 16,384 unacked events; they count events only |
| Outbound queue per connection | 64 MiB: a writer adds a frame with no wait, and an add to a queue that already holds more than 64 MiB, not counting the frame that the socket writes now, closes the connection with `4408` |
| Text of `prompt`, `steer`, `follow_up`, `compact` | 4 MiB, refused by Core with `{:error, :text_too_large}` (#672) |
| Message at file read | 1,024 blocks and 8 MiB, as a live message (#673) |

The credit window is chosen above the 10,000 provider messages that the session can hold waiting (`lib/helyx/session/stream.ex:18`). That number bounds waiting messages, not events (the first delta of a message gives two events), so it is a heuristic: a burst test checks it with the ack trip to the session, not only the socket reads.

Core bounds what it admits (#672, #673). The byte bound of the events is in the transport: a subscription process encodes each event when it takes it, and the outbound queue closes the connection when it is full. The credits count events only. The memory of a connection follows from these bounds and the Core bounds of #672, #673, and the 8 MiB message (`Helyx.Session.Turn.max_message_bytes/0`); `wire-protocol.md` claims no single number for it.

### 6. Security

- The server binds to loopback by default. Any other bind refuses to start without a token. A configured token is needed from every connection, on loopback too, so a proxy on the same machine does not pass remote clients without it.
- The token is in the `hello` frame, never in the URL, and never in a log.
- A browser page on any site can open a WebSocket to loopback, so loopback alone does not authorize a browser. Before any frame, the server refuses the upgrade when an `Origin` header is present and is not in the configured list. An empty list allows no browser.
- TLS and remote access go through a proxy in front of the server.

### 7. Version

One protocol number, sent in `hello` and `welcome`. Equality, or the server sends `refused` with its number and closes with `4426`. No compatibility code. This replaces the build-id rule of the revision of 2026-10-03: a protocol number tells two builds apart only when their wire differs, which is what a client needs.

A test computes the SHA-256 of the schema in `wire-protocol.md` and compares it with a constant next to the protocol number. A schema change without a new number fails the test (#660). A schema cannot show an order rule, so `wire-protocol.md` lists the order rules, and a change of one of them needs a new number by review.

## Considered options

- **HTTP with Server-Sent Events** (ADR 0006 §6). Rejected: two channels per client, and no ack path for credits.
- **A Transport interface in Core.** Rejected: Core would dispatch nothing to it.
- **A projection that cuts large blocks so that a frame fits.** Rejected: no projection bounds a legal message (see Parts), and a client would read the cut content in a second step.
- **A byte limit on a tail snapshot that fails the join.** Rejected: a newest group over the limit would make a legal session unjoinable. The byte limit instead ends the tail, and the newest group always goes.
- **Close only the slow subscription.** Rejected by the owner: a fixed close code is one rule, and the client reconnects with `after`.
- **A compatibility range of protocol numbers.** Rejected: compatibility code for old clients, which a client that updates with its server does not need.

## Consequences

- AGENTS.md and README drop the Transport interface.
- ADR 0006 gets a revision note for §2, §3, §5, and §6. `docs/features/session-snapshot.md` and `docs/features/end-signal.md` state the revised rules.
- The TUI rule that it has no `seq` guard holds while the TUI subscribes in the node. With #662 the TUI attaches over the wire, reconnects with `after`, and keeps the `seq` of the last event it applied.
- The texts that an abort gives back (`queue_dropped`) reach only the subscribers that are connected at that moment. A client that reconnects later gets a tail snapshot, which does not hold them. The TUI does the same today: the texts go to the composer of the client that saw the event.
- Every subscriber in the node acks (#659): the TUI, print mode, and the test subscribers.
- The tickets are #657 to #662, on the Core bounds of #672 and #673. #116 closes with #659.
