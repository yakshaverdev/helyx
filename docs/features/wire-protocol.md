# Wire protocol

## Goal

One wire contract between the Helyx server and every client: the TUI, a web app, native apps, and bots. A client in another language is written from this doc alone, and the conformance client of #660 tells its author whether it is right. The decisions and their reasons are in ADR 0008 (#656). This doc holds the codec of every frame, operation, event, block kind, origin, error code, and status value, the bounds, the order rules, and the schema whose SHA-256 the protocol number test checks.

User stories:

- A user opens the coding agent on the laptop, starts a long turn, closes the lid, and follows the same turn on the phone. The phone joins with a tail snapshot; when it wakes from sleep, it gets the events it missed from the replay ring.
- A web page from another site tries to drive the local server. The server refuses the upgrade before any frame.

## Interface changes

### Connection

1. The client opens a WebSocket. The server checks the `Origin` header first: a header that is present and not in the configured list gets HTTP 403, and the 65th connection gets HTTP 503.
2. The client sends `hello` within 5,000 ms. The server needs a token when it binds to an address that is not loopback; a server that has a token configured needs it from every connection, on loopback too. A missing or wrong token where one is needed, or no `hello` in time, closes the connection with `4401`. A proxy that gives remote access to a server bound to loopback connects from loopback: such a server has a token configured, or the proxy authenticates the remote client itself. A protocol number that is not the server's gets `refused` and the close `4426`.
3. The server sends `welcome`. From then on, the client sends `req` and `ack` frames, and the server sends `res`, `event`, and `session_end` frames.

Over stdio, the same frames go one JSON object per line. The encoder escapes every LF inside a string, so a raw LF ends a frame, and stdout carries protocol frames only. Stdio has no `Origin` and no token: the process that starts the server owns it.

### Close codes

| Code | Meaning |
|---|---|
| `4400` | a frame that the contract does not allow: bad JSON, an unknown `type`, a frame before `welcome`, a part out of order, a request `id` whose reply was not sent, an `ack` of a `seq` that the subscription did not send |
| `4401` | no `hello` within 5,000 ms, or a missing or wrong token |
| `4408` | a slow client: a subscription passed its credits (`:slow`), the outbound queue held more than 64 MiB when a frame was added, or no inbound frame or pong for 45,000 ms |
| `4413` | an inbound WebSocket frame over 1 MiB, or an inbound frame joined from parts over 4 MiB |
| `4426` | a protocol number that is not the server's, after `refused` |

The server sends a WebSocket ping every 15,000 ms, so a connection whose peer is gone (a laptop lid that closed) ends within 45,000 ms. A ping is not an add to the outbound queue: the connection sends it between two frames, also between two parts of one frame.

### Parts

A frame whose JSON text is over 1,048,576 bytes goes as `part` frames. Part `n` (from 0) carries in `data` the base64 (RFC 4648, with padding) of the next piece of the JSON text, at most 786,000 bytes, and `last` is true on the final part. The base64 of a piece is at most 1,048,000 bytes, so a whole part frame stays under 1,048,576 bytes. A piece can end inside a UTF-8 character: base64 carries any bytes, and the receiver joins the decoded pieces as bytes, then decodes the whole text. The parts of one frame are consecutive. A receiver that gets a part with another `n` than the next, or another frame between two parts, closes with `4400`.

### Operations

Every `req` gets one `res`: `ok: true` with the result, or `ok: false` with an error. A `session` param is a session id. A request `id` must not be the `id` of a request whose reply the server has not sent; a duplicate closes the connection with `4400`, because its reply could not be told apart. After a `timeout` reply the `id` is free, though the worker still counts against the requests in flight. A `subscribe` counts against the 16 subscriptions from its `req`, and against the requests in flight only until its reply.

| `op` | `params` | `result` | errors |
|---|---|---|---|
| `sessions.live` | `{}` | `{sessions: [live_session]}`, at most 64 | |
| `sessions.saved` | `{cwd?, after?, limit?}`: `cwd` is a folder, or absent for every folder; `after` is the `next` of the page before; `limit` from 1 to 256, default 50 | `{items: [saved_session], next}`, newest first; `next` is null on the last page | `bad_params` |
| `start` | `{cwd, model?}`; no `model` takes the default of the server | `{session}` | `invalid_cwd`, `invalid_model_ref`, `unknown_provider`, `too_many_sessions`, `start_failed` |
| `resume` | `{id}`, or `{cwd}` for the newest session of the folder | `{session}`; a session that runs is attached, not started again | `invalid_cwd`, `not_found`, `invalid_model_ref`, `unknown_provider`, `too_many_sessions`, `start_failed` |
| `subscribe` | `{session, tail?, after?}`: `tail` from 1 to 1,000, default 200; `after` is `{instance_id, seq}` | `{sub, replay: [event]}` or `{sub, snapshot}` | `session_not_found`, `too_many_subscriptions` |
| `unsubscribe` | `{sub}` | `{}` | `unknown_sub` |
| `history` | `{session, instance_id, before, limit?}`: `before` is a message id; `limit` from 1 to 1,000, default 200 | `{messages: [message], more}`, oldest first, all older than `before` | `session_not_found`, `instance_changed`, `unknown_message` |
| `prompt`, `steer`, `follow_up` | `{session, text, origin?}`; `origin` is `{kind: "product", id}` | `{}` | `session_not_found`, `invalid_utf8`, `invalid_origin`, `queue_full`, and for `prompt` also `turn_running` |
| `abort` | `{session}` | `{}`; a failed cleanup still gives `{}`, and the `notice` event "abort cleanup failed" tells the clients | `session_not_found` |
| `set_model` | `{session, model}` | `{}`; the next turn uses it, a running turn keeps its model | `session_not_found`, `invalid_model_ref`, `unknown_provider` |
| `compact` | `{session, text?}`: the instructions, default `""` | `{}`; a provider that keeps no history gives a `notice` event | `session_not_found`, `invalid_utf8`, `turn_running` |
| `stop` | `{session}` | `{}` after the session ended: a running turn aborts first, as at `abort`, then the session stops and every subscription of it gets `session_end` with `stopped`. A stopped session frees its place in the live-session cap and can be resumed from its file | `session_not_found` |

Every operation can also answer `unknown_op`, `bad_params`, `busy`, `timeout`, and `failed`.

- `live_session` is `{id, instance_id, cwd, model, status}`. `status` is `"idle"` when the session has no turn and no wait, else `"running"`.
- `saved_session` is `{id, cwd, model, mtime, prompt}`: `mtime` in POSIX seconds, `model` from the header, `prompt` the first user text in the head of the file (`docs/features/session-list.md`). The texts come from the file: a client cleans them before it shows them.
- `start_failed` is any other start error of ADR 0006 §2, a lock that another OS process holds too. Its `text` is `Helyx.Reason.text/1` of the term; the log gets the term.
- `bad_params` is a missing key, a key of the wrong type, a value out of its range, or a key that the operation does not name. The server checks every param at its entry.

### Deadlines

Past its deadline, an operation answers `timeout`: the outcome is unknown. The client does not send it again on its own (ADR 0006 §4). The worker of the request still counts against the 16 requests in flight until it ends, and its late result is dropped; a `subscribe` stops counting at its reply. A deadline covers the work of the request up to its result, not the encode and the write of the reply. One process writes each reply: the worker of the request, or for `subscribe` its subscription process. That process answers `timeout` itself when the Core call exits at its timeout, and `Helyx.Session.subscribe/1` then leaves no subscription and no monitor (`lib/helyx/session.ex:222-235`); the process ends after the reply, so a `subscribe` that answers `timeout` leaves no subscription.

| Operation | Deadline | Why |
|---|---|---|
| `abort` | 46,000 ms | the hands release of the cancel, at most 20,000 ms (`Hands.State.release_ms/0`, `lib/helyx/session/hands.ex:66`, the call at `:225`); then the delivery of the provider process, which releases its handles in the same hands process, at most 20,000 ms more (`hands.ex:279`, `:292`); an abort that comes during an idle close also waits for the armed kill of the close, 5,000 ms (`State.provider_close_ms/0`, `lib/helyx/session/server/state.ex:37`, `turn_loop.ex:104-109`); and a margin of 1,000 ms. `Helyx.Session.abort/1` itself waits with no timeout (`lib/helyx/session.ex:378`). A test of the transport compares the constant with the two functions. A hands process with more releases queued takes longer: the client gets `timeout`, accepted |
| `stop` | 47,000 ms | the `abort` deadline, then the stop of the session process, which has the 1,000 ms release bound of the lock (`Helyx.Session.Lock.release_ms/0`, `lib/helyx/session/lock.ex:38`); the Core call is part of the server-management API (#657) |
| `start`, `resume` | 30,000 ms | the tool checks in the caller (`Helyx.Tool.check_available/1`, no timeout of its own), then the open in the session process: the lock, whose answer has 5,000 ms (`lib/helyx/session/lock.ex:33`), and the load of a file of at most 64 MiB (`lib/helyx/session/file.ex:21`). `Server.start/3` waits for the open with no timeout of its own (`lib/helyx/session/server.ex:38-50`). A longer start answers `timeout`, and the session can still start: the client sees it in `sessions.live` |
| `sessions.saved` | 10,000 ms | a scan of at most 256 file heads of 64 KiB (`lib/helyx/session/file/scan.ex:4`, `:8`) |
| `subscribe` | the call timeout of 5,000 ms (`lib/helyx/session.ex:39`) | the subscription process answers the exit as `timeout` |
| every other operation | 6,000 ms | an operation on one session is one session call with the call timeout of 5,000 ms, whose exit the worker answers as `timeout`; `sessions.live` (#657) answers within the same deadline; the 1,000 ms margin is for load |

### Subscriptions

- A subscription is one process under the connection. It calls `Helyx.Session.subscribe`, owns the Core subscription and its end monitor, encodes the events, and writes them to the socket in order.
- The server makes the `sub` id. It is unique on the connection.
- The session counts each event that it sends to the subscription, a replayed event too, and the `ack` frames of the client lower the count. `ack` with `seq` acks every event of that subscription up to `seq`. An `ack` lower than an earlier one changes nothing. An `ack` for a `sub` that the connection does not hold (it ended) is ignored. An `ack` above the last `seq` that the subscription sent closes the connection with `4400`.
- Past 16,384 unacked events, the session ends the subscription with `:slow`, and the transport closes the connection with `4408`. The client connects again and subscribes with `after`. A client acks at least every few thousand events; the server does not check the cadence, the bound decides.
- `session_end` ends the subscription. The connection stays open. A connection that closes with no `session_end` for a subscription is a lost connection: the session may still run, and the client subscribes again with `after`.
- A client that applies the snapshot keeps its `seq` and `instance_id`. After a reconnect it subscribes with `after: {instance_id, seq}` of the last event that it applied.

### Join, pages, and replay

- **Tail snapshot.** The newest messages of the transcript, at most `tail` of them and at most 16,777,216 bytes of message content, each message counted by `:erlang.external_size/1`. Then the cut moves to newer messages until the first message is a user or an assistant message, so an assistant message and its tool results stay together. When that leaves no message, the tail is the newest group alone: the last user or assistant message and the messages after it, whatever their count and size. `more` is true when older messages exist.
- **The state in the snapshot.** The snapshot has the full current state, whatever its tail: `turn` with its partial, `model`, `queue`, `persisting`, `seq`, `usage`, and `context`. `usage` and `context` count every message of the transcript, not only the tail. The client then adds each message that a later `message_end` or `tool_execution_end` carries, with the rule of `docs/features/usage-and-limits.md`, "The footer". It adds no message of a `history` page: a page changes neither `usage` nor `context`, and it does not move `seq`.
- **The rule of ADR 0006 §3, revised.** The snapshot at `seq` equals the loaded suffix of the transcript folded from every event up to `seq`, plus the full current state. The notices stay out, as before: "aborted", "error: …", harness notices, "resumed session". `persisting: false` still makes the not-saved text.
- **History.** `history` serves the live transcript of the session, not the file, so it holds the unsaved messages and the interrupted results of a resume. It returns the messages before `before`, with the limits and the cut of the tail, `limit` in place of `tail`. `instance_changed` means that the session started again: the client subscribes again for a new snapshot.
- **Replay.** `subscribe` with `after` returns the events after `seq` from the replay ring, contiguous, then the live events follow with no gap and no duplicate. When `instance_id` is not the current instance, the events after `seq` are no longer all in the ring, or `seq` is above the last event, the result is a tail snapshot instead, with `tail` of the request.

### Codec

Every value is JSON. An atom is its name as a string. A message has the shape of a message entry of the session file without its `type` key (`lib/helyx/session/file/codec.ex:9-27`): a key whose value is nil or false is left out, but for `is_error`, which a tool result always has. A reader takes a missing key as null or false.

A client is a tolerant reader (ADR 0006, revisions of 2026-10-03 and 2026-10-16): it dispatches on the `type` of an event first, ignores an event type that it does not know and a key that it does not know, and shows a placeholder for a block kind that it does not know. A known type with a broken shape is a contract break.

The wire leaves out two fields of Core events: `texts` of `queue_dropped` and `text` of `steer_unconfirmed`. The messages carry the same texts, so the frame is half the size.

The schema below is the contract. The test of #660 computes the SHA-256 of the lines between the two markers and compares it with the constant next to the protocol number.

<!-- wire-schema:start -->
```text
protocol 1

notation: {k: T} an object; k? may be absent (absent = null or false);
  T | U either; [T] a list; "x" that string; int a JSON integer >= 0;
  number a JSON number >= 0; id a string of 1 to 64 bytes;
  base64 a string of RFC 4648 base64 of at most 786,000 bytes

# client to server
hello   = {type: "hello", protocol: int, token?: string}
req     = {type: "req", id: id, op: op, params: object}
ack     = {type: "ack", sub: string, seq: int}
part    = {type: "part", n: int, last: bool, data: base64}

# server to client
welcome     = {type: "welcome", protocol: int}
refused     = {type: "refused", code: "protocol", server_protocol: int}
res         = {type: "res", id: id, ok: true, result: object}
            | {type: "res", id: id, ok: false, error: error}
event_frame = {type: "event", sub: string, event: event}
session_end = {type: "session_end", sub: string, reason: "stopped" | "crashed"}
part        (as above)

error      = {code: error_code, text: string}
error_code = "unknown_op" | "bad_params" | "busy" | "timeout" | "failed"
           | "session_not_found" | "too_many_sessions" | "too_many_subscriptions"
           | "unknown_sub" | "instance_changed" | "unknown_message"
           | "invalid_cwd" | "invalid_model_ref" | "unknown_provider"
           | "not_found" | "start_failed"
           | "invalid_utf8" | "invalid_origin" | "queue_full" | "turn_running"

op = "sessions.live" | "sessions.saved" | "start" | "resume" | "subscribe"
   | "unsubscribe" | "history" | "prompt" | "steer" | "follow_up"
   | "abort" | "set_model" | "compact" | "stop"

params.sessions.live   = {}
params.sessions.saved  = {cwd?: string, after?: string, limit?: int}
params.start           = {cwd: string, model?: string}
params.resume          = {id: string} | {cwd: string}
params.subscribe       = {session: string, tail?: int,
                          after?: {instance_id: string, seq: int}}
params.unsubscribe     = {sub: string}
params.history         = {session: string, instance_id: string,
                          before: string, limit?: int}
params.prompt          = {session: string, text: string, origin?: product_origin}
params.steer           = params.prompt
params.follow_up       = params.prompt
params.abort           = {session: string}
params.set_model       = {session: string, model: string}
params.compact         = {session: string, text?: string}
params.stop            = {session: string}
product_origin         = {kind: "product", id: string}

result.sessions.live  = {sessions: [live_session]}
result.sessions.saved = {items: [saved_session], next: string | null}
result.start          = {session: string}
result.resume         = {session: string}
result.subscribe      = {sub: string, replay: [event]} | {sub: string, snapshot: snapshot}
result.history        = {messages: [message], more: bool}
result.unsubscribe, result.prompt, result.steer, result.follow_up,
result.abort, result.set_model, result.compact, result.stop = {}

live_session  = {id: string, instance_id: string, cwd: string, model: string,
                 status: "idle" | "running"}
saved_session = {id: string, cwd: string, model: string, mtime: int, prompt: string}

snapshot = {instance_id: string, seq: int, messages: [message], more: bool,
            turn: turn | null, model: string, queue: queue, persisting: bool,
            usage: totals, context: context | null}
turn     = {id: string, partial: message | null, elapsed_ms: int}
queue    = {steers: int, follow_ups: int, running: int, held: int, waiting: int}
totals   = {input: int, output: int, cache_read: int, cache_write: int,
            cost: number | null, unknown: bool, list: bool}
context  = {tokens: int | null, window: int | null, model: string | null, bytes: int}

event = {type: event_type, session_id: string, instance_id: string,
         turn_id: string | null, seq: int, data: data}
event_type = "turn_start" | "message_start" | "message_update" | "message_end"
           | "tool_execution_end" | "turn_end" | "queue_update" | "queue_dropped"
           | "model_change" | "resume_id" | "steer_unconfirmed" | "compaction"
           | "notice"
data.turn_start         = {origin?: "provider" | "compaction"}
data.message_start      = {message: message}
data.message_update     = {text_delta: string} | {thinking_delta: string}
                        | {tool_call: tool_call}
data.message_end        = {message: message, error?: {kind: "aborted"}
                                                    | {kind: "failed", text: string}}
data.tool_execution_end = {message: message}
data.turn_end           = {outcome: "done" | "aborted"} | {outcome: "error", error: string}
data.queue_update       = queue
data.queue_dropped      = {messages: [message]}
data.model_change       = {model: string}
data.resume_id          = {provider: string, resume_id: string, lost: bool, cut: int}
data.steer_unconfirmed  = {message: message}
data.compaction         = {trigger: "manual" | "auto", tokens_before: int | null,
                           tokens_after: int | null}
data.notice             = {text: string}

message = {id: string, role: "user" | "assistant" | "tool_result",
           content: [block], origin?: origin, model?: string,
           stop_reason?: stop_reason, tool_call_id?: string, tool_name?: string,
           is_error?: bool, usage?: usage}
block     = {type: "text", text: string} | {type: "thinking", thinking: string}
          | tool_call
tool_call = {type: "tool_call", id: string, name: string, arguments: object}
origin    = {kind: "user" | "background" | "product" | "unknown", id: string | null}
stop_reason = "end_turn" | "tool_use" | "max_tokens" | "refused" | "aborted" | "error"
usage = {input: int, output: int, cache_read: int, cache_write: int,
         cost?: number, cost_kind?: "list" | "billed",
         context_tokens?: int, context_window?: int}

# order rules (a schema cannot show them; a change needs a new protocol number)
O1 hello is the first client frame; the server sends nothing but welcome or
   refused before it, and the client sends nothing else before welcome.
O2 each req gets exactly one res, also at timeout; none after the close.
O3 the parts of one frame are consecutive, n from 0, last on the final one.
O4 per subscription: the subscribe res, which carries the replayed events,
   then its live events in seq order with no gap and no duplicate after the
   replay, then at most one session_end, last. No frame of a sub follows its unsubscribe res.
O5 session_end comes after every event of the session.
O6 frames of two subscriptions, and a res and an event, have no order
   between them.
```
<!-- wire-schema:end -->

Notes on the codec:

- `origin` `"unknown"` is a user message of a session file from before #649. `id` is null for `"user"` and `"unknown"` (`docs/features/message-identity.md`).
- `error` of `message_end`: `{kind: "aborted"}` for an aborted turn, `{kind: "failed", text}` for a failed one, where `text` is the error text of the turn (ADR 0006 §2). The two are kept apart, because a failure text can be the word "aborted".
- `turn_end` `error` and `notice` `text` are text for a person; a client shows them as they are.
- `arguments` of a tool call is a JSON object whose integers have at most 100 digits (`Helyx.Message.cap_integers/1`).
- A `cost` is in USD. `elapsed_ms` is by the clock of the session; a client starts its busy clock at that age.

## Replaced mechanism

1. **The full snapshot of every subscribe** (`Events.snapshot/1`, `lib/helyx/session/server/events.ex:29-39`). A wire subscribe gets a tail snapshot with the usage totals and the context state as fields (#658). `Helyx.Session.subscribe/1` with no `tail` keeps the full snapshot for a client in the node until #662.
2. **Reconnect with a new full snapshot** (ADR 0006 §3). Replaced by the replay ring and `after` (#659). The new snapshot still replaces all client state when the ring cannot serve the interval.
3. **The end signal as a `:DOWN`** (`docs/features/end-signal.md`). It stays for a client in the node. On the wire, the subscription process turns the `:DOWN` into `session_end`; it is the one process that sees both the events of the session and the `:DOWN`, and the session sends its last event before it dies, so `session_end` comes last (O5).
4. **`send/2` with no bound** (`events.ex:66`). Replaced by the credits (#659); the `:slow` end is a new item of the closed list of ADR 0006 §2.
5. **The build-id rule** of ADR 0006 (revision of 2026-10-03). Replaced by the protocol number and its schema test.
6. **HTTP and SSE as a Transport plugin** (ADR 0006 §6). Replaced by `Helyx.Transport.WebSocket`, a bundled module with no Core interface.
7. Tests: no test of the old remote plan exists. `test/helyx/session/end_signal_test.exs` keeps its properties for the local end signal.

## Bounds

| What | Bound | Over the bound | Where enforced |
|---|---|---|---|
| WebSocket frame, both ways | 1,048,576 bytes of JSON text; a larger frame goes as parts | an inbound frame over it: close `4413` | transport |
| one inbound frame joined from parts (the request size) | 4,194,304 bytes | close `4413`; the parts are dropped as they come | transport |
| requests in flight per connection | 16, from the `req` to the end of its worker; a `subscribe` from the `req` to its reply | `res` with `busy` | transport |
| requests in flight per server | 1,024: 64 connections of 16 | as above | transport |
| subscriptions per connection | 16 | `res` with `too_many_subscriptions` | transport |
| connections per server | 64 | HTTP 503 at the upgrade | transport |
| live sessions per server | 64 | `start` or `resume` gets `too_many_sessions` | server API (#657) |
| auth wait | 5,000 ms from the upgrade to `hello` | close `4401` | transport |
| a peer that is gone | a ping every 15,000 ms; 45,000 ms with no inbound frame or pong | close `4408` | transport |
| replay ring per session | 1,024 events and 4,194,304 bytes, each event counted by `:erlang.external_size/1`. A message is in the ring twice, as its deltas and as its `message_end`, so the ring holds about 2 MiB of new text | the oldest events go; an event over 4 MiB empties the ring and marks a gap, so a replay over it gives a snapshot | session (#659) |
| replay rings of the server | 268,435,456 bytes: 64 live sessions of 4 MiB. No accounting across sessions is needed | as above | the live-session cap |
| tail snapshot and page, count | default 200, at most 1,000; or the newest group alone | a value over 1,000: `bad_params` | session (#658) |
| tail snapshot and page, bytes | 16,777,216 bytes of message content (`:erlang.external_size/1`); or the newest group alone. A group is one assistant message of at most 8 MiB and 1,024 blocks, live by `Helyx.Session.Turn` (`lib/helyx/session/turn.ex:69`, `:74`, `:94`) and at file read by #673, with at most one tool result for each call (at read, `Helyx.Session.Transcript.repair/1` drops a second one, `lib/helyx/session/transcript.ex:52-58`), each text block of a result at most 64 KiB (`lib/helyx/data/message.ex:184`, and at read `Codec.decode/1` cuts each block, `lib/helyx/session/file/codec.ex`); a result has no total bound of its own beyond the blocks of its message. The snapshot also carries the turn partial, at most 8 MiB | the tail ends; it goes as parts | session (#658) |
| request results per connection | 1: a `subscribe`, `history`, or `sessions.saved` request takes the one encoder slot of the connection before it reads its data from Core, and holds it until its reply is in the outbound queue. So at most one snapshot or page result exists per connection, and a waiting request holds no result. The wait for the slot is not in the deadline of the request; the request counts against the requests in flight while it waits. Another operation has a small result and takes no slot, and an event takes no slot: its subscription process encodes it | | transport |
| credits per subscriber | 16,384 unacked events, a replayed event too. The count is chosen above the 10,000 provider messages that the session can hold waiting (`lib/helyx/session/stream.ex:18`), a heuristic: that number bounds messages, not events, and the burst test checks it. The credits count events only: the byte bound is the outbound queue | the subscription ends with `:slow`; close `4408` | session (#659) |
| outbound queue per connection | 67,108,864 bytes of frames added and not yet taken by the socket. A subscription process encodes each event when it takes it, and a writer adds each frame with a call that the connection process answers at once, with no wait for room. Before each add, one add at a time, the connection checks the bytes of the queue without the frame that the socket writes now, so one large frame does not close the connection at the next add | the queue holds more than 64 MiB at an add: close `4408` | transport |
| text of `prompt`, `steer`, `follow_up`, `compact` | 4,194,304 bytes, the request size: Core refuses a longer text from any caller with `{:error, :text_too_large}` (#672), so the wire refuses no text that Core admits | no wire request meets it: the JSON of the text is in a frame of at most 4 MiB, so the request size closes `4413` first | Core (#672) |
| `queue_dropped` | 64 messages (32 steers, 32 follow-ups, `lib/helyx/session/queue.ex:49`), each of one text of at most 4 MiB (#672). It reaches only the subscribers that are connected when the session emits it; a client that connects later gets a tail snapshot, which does not hold the texts | goes as parts | Core |
| request `id` | 1 to 64 bytes | `bad_params`; with no readable `id`, close `4400` | transport |
| `sessions.saved` page | 1 to 256 items, default 50 | `bad_params` | transport |
| live list | 64 items | | the live-session cap |

The memory of a connection follows from these bounds and the Core bounds of #672, #673, and the 8 MiB message (`Helyx.Session.Turn.max_message_bytes/0`); this doc claims no single number for it.

Each numeric limit gets tests at the limit, one under, and one over, and the frame limits a multibyte case at the edge of a part (#660).

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
|---|---|---|---|---|---|
| socket | the upgrade | the connection process | the close of either side | the socket closes with its owner | n/a |
| request worker | a `req` | the connection process (linked) | its `res` | it dies with the connection | n/a: an `abort` request is one worker |
| subscription process | `subscribe` | the connection process (linked) | `unsubscribe`, `session_end` | it dies with the connection; its Core subscription ends at the session's `:DOWN` of it (`session-subscribers.md`, S4) | n/a |
| Core subscription and end monitor | the subscription process | the subscription process | the end of the subscription process: the session drops the entry at its `:DOWN` | the session drops the entry at its `:DOWN` | n/a |
| replay ring | the session | the session process | ends with the session | ends with the session | n/a |

## Out of scope

- Code: #657 to #662, and the Core bounds that they build on: #672 (a text of at most 4 MiB) and #673 (at file read, a message of at most 1,024 blocks and 8 MiB).
- Push to an app that is closed: a product client host.
- A browser client.
- Paging inside one message body: parts carry any size (#658).
- stdio framing code: same frames, a later ticket when a client needs it (#660).
