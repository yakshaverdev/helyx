# Wire protocol

## Goal

One wire contract between the Helyx server and every client: the TUI, a web app, native apps, and bots. A client in another language is written from this doc alone, and the conformance client of #660 tells its author whether it is right. The decisions and their reasons are in ADR 0008 (#656). This doc holds the codec of every frame, operation, event, block kind, origin, error code, and status value, the bounds, the order rules, and the schema whose SHA-256 the protocol number test checks.

User stories:

- A user opens the coding agent on the laptop, starts a long turn, closes the lid, and follows the same turn on the phone. The phone joins with a tail snapshot; when it wakes from sleep, it gets the events it missed from the replay ring.
- A web page from another site tries to drive the local server. The server refuses the upgrade before any frame.

## Interface changes

### Connection

1. The client opens a WebSocket. The server checks the `Origin` header first: a header that is present and not in the configured list gets HTTP 403, and the 65th connection gets HTTP 503.
2. The server sends `challenge` at once. Its `nonce` is the base64 of 32 random bytes, a new one for each connection. The client sends `hello` within 5,000 ms of the upgrade.
   - **Token.** The server needs a token when it binds to an address that is not loopback. A server that has a token configured needs the proof of it from every connection, on loopback too. A server with no token takes any `hello` and does not read its `proof`.
   - **Proof.** The `proof` in `hello` is the base64 of HMAC-SHA256 with the key over the 32 bytes of the nonce. The key is the SHA-256 of the token. The server compares the proof in constant time. A missing or wrong proof where one is needed, or no `hello` in time, closes the connection with `4401`.
   - **No secret in a frame.** No frame holds the token. A proof is good for its one nonce, and the nonce for its one connection. So a `hello` in a log gives no access (ADR 0008, revision of 2026-10-18).
   - **No secret in a term.** The key is in a closure in the plug options and in the state of every process of the transport. `child_spec/1` puts the token in a closure in the child spec that the supervisor of the product keeps. `inspect/1` of a closure does not print what it holds. So a log of the options, of a process state, or of a crash report holds neither the token nor the key. A product that writes its own child spec, not through `child_spec/1`, keeps its options there as it wrote them.
   - **The logs of the WebSocket server.** Three logs of the WebSocket server hold frame bytes, `conn`, or the plug options, and none of them holds a secret now. The first is the crash report of a socket error that comes as a message (`:tcp_error`, such as `:etimedout`), with the fragment buffer. The second is the log of an exception in the handshake (a bad `Sec-WebSocket-Extensions` header), with `conn` in its metadata. The third is the warning for a TLS packet on a clear channel, with the plug options. A test captures each one on a loopback socket. Where the log holds a frame, the frame has a mask of zero, so the log holds the text of the frame.
   - **Other logs.** A stop on a bad frame or a closed socket logs no crash report, and an HTTP or WebSocket protocol error logs nothing. The server speaks only HTTP/1.1 and closes any other protocol. A refused upgrade (`403`, `503`, or a bad handshake) closes the connection at once, so the server does not read the bytes after it as the next HTTP request.
   - **Parts.** A `hello` comes in one frame: a part before `welcome` closes the connection with `4400`. So a client that did not give its proof gets no buffer of parts.
   - **Proxy.** A proxy that gives remote access to a server bound to loopback connects from loopback. Such a server has a token configured, or the proxy authenticates the remote client itself.
   - **Protocol.** A protocol number that is not the server's gets `refused` and the close `4426`. The server checks the protocol number before the proof, so a client of another protocol learns that it must update. `refused` holds only the protocol number of the server.
   - **Authority.** A server under a Hub has an authority in place of the one token (`docs/features/hub.md`, decisions 3 and 5): the `hello` names the `token` id of a user with the proof of that token, or no `token` with the proof of the server token, and the authority checks each later request but `unsubscribe`, and each subscription. A `token` that is not an id of 1 to 64 bytes, unknown, or revoked, closes with `4401`. A server with no authority does not read `token`, and answers a `hub.*` op and `records.subscribe` with `unknown_op`, and `records.unsubscribe` with `unknown_sub` (no subscription exists).
3. The server sends `welcome`. From then on, the client sends `req` and `ack` frames, and the server sends `res`, `event`, and `session_end` frames.

Over stdio, the same frames go one JSON object per line. The encoder escapes every LF inside a string, so a raw LF ends a frame, and stdout carries protocol frames only. Stdio has no `Origin` and no token: the process that starts the server owns it.

### Webhook endpoint

The same listener serves the webhook of an event subscription: `POST /hooks/<id>` (`docs/features/hub.md`, decision 17). It is not a frame and not a WebSocket upgrade: the server reads the body (at most 1,048,576 bytes), gives it to the authority of the transport, and answers the HTTP status that the authority decides. A transport with no authority, or with an authority that does not export `webhook/3`, answers 404 on every path under `/hooks`. The endpoint has no `Origin` check and no `hello`: the HMAC of the body with the secret of the subscription is its check, and the path itself is a secret.

### Close codes

| Code | Meaning |
|---|---|
| `4400` | a frame that the contract does not allow: a text that the server cannot decode (bad JSON, a text that is not UTF-8, a float out of range, or a text over the decode bounds, see "Bounds"), an unknown `type`, a frame or a part before `welcome`, a `hello` whose `protocol` is not an integer of 0 or more, a part out of order, a request `id` whose reply was not sent, an `ack` of a `seq` that the subscription did not send |
| `4401` | no `hello` within 5,000 ms, or a missing or wrong proof; under a Hub also a `token` that is not an id, unknown, or revoked |
| `4408` | a slow client: a subscription passed its credits (`:slow`), the outbound queue held more than 64 MiB when a frame was added, or no inbound frame or pong for 45,000 ms |
| `4413` | an inbound frame joined from parts over 25 MiB |
| `1002`, `1008` | a WebSocket frame that RFC 6455 does not allow, such as a continuation with no frame before it (`1002`) or an empty continuation that is not the last (`1008`): the WebSocket server closes |
| `1011` | a crash of the connection process from a bug: the WebSocket server closes |
| `1009` | an inbound WebSocket frame over 1 MiB: the WebSocket server closes with the code of RFC 6455 before it reads the payload, so the frame takes no memory |
| `4426` | a protocol number that is not the server's, after `refused` |
| `4403` | under a Hub: the access of the user changed (a revoked token, a removed user, a record change that takes read access), at once or at the next request or subscription (`docs/features/hub.md`, decision 13) |
| `4503` | under a Hub: the authority gave no answer to the `hello` (its Hub call exited or got `busy`); the client connects again later |
| `1000` | the stop of the transport: the WebSocket server closes (see "Bounds") |

At each of these closes the connection process ends: the server handles no later frame of the client, and the writers of the connection end with it. A close that a subscription or a writer decides (a full outbound queue, `:slow`, an `ack` above the `seq` that the subscription sent) reaches the connection as a message, so the frames that the connection took before it run first.

The server sends a WebSocket ping every 15,000 ms, so a connection whose peer is gone (a laptop lid that closed) ends within 45,000 ms. A ping is not an add to the outbound queue: the connection sends it between two frames. The parts of one frame go out together, so a ping waits for the last part.

### Parts

A frame whose JSON text is over 1,048,576 bytes goes as `part` frames. Part `n` (from 0) carries in `data` the base64 (RFC 4648, with padding) of the next piece of the JSON text, at most 786,000 bytes, and `last` is true on the final part. The base64 of a piece is at most 1,048,000 bytes, so a whole part frame stays under 1,048,576 bytes. A piece can end inside a UTF-8 character: base64 carries any bytes, and the receiver joins the decoded pieces as bytes, then decodes the whole text. The parts of one frame are consecutive. A receiver that gets a part with another `n` than the next, or another frame between two parts, closes with `4400`.

### Operations

Every `req` gets one `res`: `ok: true` with the result, or `ok: false` with an error. A `session` param is a session id. A request `id` must not be the `id` of a request whose reply the server has not sent; a duplicate closes the connection with `4400`, because its reply could not be told apart. After a `timeout` reply the `id` is free, though the worker still counts against the requests in flight. A `subscribe` counts against the 16 subscriptions from its `req`, and against the requests in flight only until its reply.

| `op` | `params` | `result` | errors |
|---|---|---|---|
| `sessions.live` | `{}` | `{sessions: [live_session]}`, at most 64 | |
| `sessions.saved` | `{cwd?, after?, limit?}`: `cwd` is a folder, or absent for every folder; `after` is the `next` of the page before; `limit` from 1 to 256, default 50 | `{items: [saved_session], next}`, newest first; `next` is null on the last page | `bad_params` |
| `start` | `{cwd, model?}`; no `model` takes the default of the server | `{session}` | `invalid_cwd`, `invalid_model_ref`, `unknown_provider`, `too_many_sessions`, `start_failed`, and under a Hub `too_many_records` |
| `resume` | `{id}`, or `{cwd}` for the newest session of the folder | `{session}`; a session that runs is attached, not started again | `invalid_cwd`, `not_found`, `invalid_model_ref`, `unknown_provider`, `too_many_sessions`, `start_failed` |
| `subscribe` | `{session, tail?, after?, answers?}`: `tail` from 1 to 1,000, default 200; `after` is `{instance_id, seq}`; `answers: true` says that this client answers asks (`docs/features/question-tool.md`) | `{sub, replay: [event]}` or `{sub, snapshot}` | `session_not_found`, `too_many_subscriptions` |
| `unsubscribe` | `{sub}` | `{}` | `unknown_sub` |
| `history` | `{session, instance_id, before, limit?}`: `before` is a message id; `limit` from 1 to 1,000, default 200 | `{messages: [message], older, next}`, oldest first, all older than `before`; `next` is the `before` of the page before it, null when `older` is 0 | `session_not_found`, `instance_changed`, `unknown_message` |
| `prompt`, `steer`, `follow_up` | `{session, text, origin?}`; `origin` is `{kind: "product", id}` | `{}` | `session_not_found`, `text_too_large`, `invalid_utf8`, `invalid_origin`, `queue_full`, and for `prompt` also `turn_running`, and under a Hub `forbidden` |
| `abort` | `{session}` | `{}`; a failed cleanup still gives `{}`, and the `notice` event "abort cleanup failed" tells the clients. The events that the session sent before the abort still come to each subscription, then `turn_end` with `aborted`; no event of the turn follows it. The `{}` and these events have no order (O6) | `session_not_found`, and under a Hub `forbidden` |
| `set_model` | `{session, model}` | `{}`; the next turn uses it, a running turn keeps its model | `session_not_found`, `invalid_model_ref`, `unknown_provider`, and under a Hub `forbidden` |
| `compact` | `{session, text?}`: the instructions, default `""` | `{}`; a provider that keeps no history gives a `notice` event | `session_not_found`, `text_too_large`, `invalid_utf8`, `turn_running`, and under a Hub `forbidden` |
| `answer` | `{session, ask_id, answer}`: `ask_id` is the id of an `ask` event; `answer` is a JSON object of at most 16,384 bytes; a frame over the decode bounds ("Bounds") closes with `4400` before the op is known | `{}`; the first answer to an open ask goes to its call, and every client gets `ask_end`; an id that is not open gets `not_waiting` | `session_not_found`, `invalid_answer`, `not_waiting`, and under a Hub `forbidden` |
| `stop` | `{session}` | `{}` after the session ended: a running turn aborts first, as at `abort`, then the session stops and every subscription of it gets `session_end` with `stopped`. A stopped session frees its place in the live-session cap and can be resumed from its file. The answer is `{}` also when a handle of the session was not released: the wire does not carry the stop report of `Helyx.Sessions.stop/1` (#752) | `session_not_found`, and under a Hub `forbidden` |
| `records.subscribe` | `{}` | `{records: [record], more}`, ordered: the sessions that wait for the user first, then by `active_at`, newest first, then by session id; the page and every live record beside it, at most `Helyx.Hub.RecordFeed.max_reply/0`, and `more` says that the user owns more | `unknown_op` on a server with no Hub, `too_many_subscriptions` for a second subscription on the connection |
| `records.unsubscribe` | `{}` | `{}` | `unknown_sub` |

Every operation can also answer `unknown_op`, `bad_params`, `busy`, `timeout`, and `failed`.

A `prompt`, `steer`, or `follow_up` to a session that a stop unloaded loads it first from its file, with the bound of a `resume`, before the deadline of the operation: the text goes to a session, not to an id. A missing file answers `session_not_found`, and any other load error answers `failed` (`docs/features/idle-unload.md`). A `subscribe` is no load: a session that does not run answers `session_not_found`.

Under a Hub, the `hub.*` operations and their errors are in `docs/features/hub.md`, "Wire schema additions", and their bounds in its "Bounds". The session operations reach only the sessions that the user may read: a session of another user that the user may not read answers as one that does not exist, a write to a shared session that the user does not own answers `forbidden`, and a `start` over the records of the user answers `too_many_records` (`docs/features/hub.md`, decisions 6 and 7). The records feed is in `docs/features/live-records.md`.

- `live_session` is `{id, instance_id, cwd, model, status}`. `status` is `"idle"` when the session has no turn and no wait, else `"running"`.
- `record.status` is `"waiting"` while the session has an open ask, else the status of its live session (`"idle"` or `"running"`), or `"stopped"` when no process runs it (`docs/features/live-records.md`).
- `records_end` is the last frame of a records feed: the Hub behind it ended, the connection holds no records subscription after it, and the client subscribes again. A `record` or `records` frame after it is a contract break. An `records.unsubscribe` that is in flight when the feed ends still gets its `res`, `{}`; one that the connection reads after `records_ended` answers `unknown_sub`, as one with no subscription.
- A `removed` change names its session only to the subscribers of the owner that the record had. The server never tells a user the id of another user's start (`docs/features/live-records.md`, "A start of another user").
- A `records` full list holds the rows that the live frames would send: a row of another user's start while its place is in flight (a silent row) is in neither, and the owner learns it when the start's result names the owner.
- `saved_session` is `{id, cwd, model, mtime, prompt}`: `mtime` in POSIX seconds, 0 for a file time before 1970, `model` from the header, `prompt` the first user text in the head of the file (`docs/features/session-list.md`). The texts come from the file: a client cleans them before it shows them.
- An `ask` event is a tool call that waits for a user: a client that subscribed with `answers: true` shows `request` and sends `answer` with its `ask_id`. The session makes the id, a new random id for each ask; one call can ask more than once, and each ask has its own id. The `request` and the `answer` of the bundled `question` tool are in `docs/features/question-tool.md`. A `request` with the key `kind` is an input UI block (`docs/features/ui-blocks.md`): it has the envelope of a UI block (`kind`, `text`, and `cut` when present), and one with `kind` and another envelope is a contract break. A client picks the renderer of an ask by its `kind`, and by the tool name for a request with no `kind`. A client that does not know the kind, or cannot read its fields, shows its `text` and gives no answer; the ask stays open for another client. `ask_end` ends the ask for every client: `answered` when an answer went to the call, `ended` when the call or the turn ended first. The snapshot `asks` holds the asks that wait, oldest first.
- A UI block (ADR 0011, `docs/features/ui-blocks.md`) is a JSON object that a client shows: its `kind`, its fallback `text`, `cut` when it was cut, and the fields of its kind, each at most 65,536 bytes of JSON with integers of at most 100 digits. It comes in two carriers. A tool result `message` has `ui_blocks`, at most 8 blocks, left out when it has none; a client that joins later gets them with the message. A `ui_block` event shows a block during a running call (`call_id`) or a turn (`call_id` null): a later one with the same `call_id` and `key` replaces it in place, and the others show side by side. A client drops the blocks of a call at its `tool_execution_end` and every block at `turn_end`; they are not in the transcript. The snapshot `ui_blocks` holds the newest block of each `call_id` and `key` of the running turn, in the order of the first event of each pair, as the data of its event.
- `start_failed` is any other start error of ADR 0006 §2, a lock that another OS process holds too. Its `text` is `Helyx.Reason.text/1` of the term; the log gets the term.
- `bad_params` is a missing key, a key of the wrong type, a value out of its range, or a key that the operation does not name. The server checks every param at its entry.

### Deadlines

Past its deadline, an operation answers `timeout`: the outcome is unknown. The client does not send it again on its own (ADR 0006 §4). The worker of the request still counts against the 16 requests in flight until it ends, and its late result is dropped. The deadline timer ends with its worker, so a connection holds at most 16 timers; a `subscribe` stops counting at its reply. A deadline covers the work of the request up to its result, not the encode and the write of the reply. One process writes each reply: the worker of the request, or for `subscribe` its subscription process. That process answers `timeout` itself when the Core call exits at its timeout, and `Helyx.Session.subscribe/1` then leaves no subscription and no monitor (`lib/helyx/session/call.ex`, `subscribe/3`); the process ends after the reply, so a `subscribe` that answers `timeout` leaves no subscription.

| Operation | Deadline | Why |
|---|---|---|
| `abort` | 46,000 ms | the hands release of the cancel, at most 20,000 ms (`Helyx.Session.Hands.State.release_ms/0`, `lib/helyx/session/hands/state.ex`, `@release_ms`); then the delivery of the provider process, which releases its handles in the same hands process, at most 20,000 ms more (`hands.ex:297`); an abort that comes during an idle close also waits for the armed kill of the close, 5,000 ms (`State.provider_close_ms/0`, `lib/helyx/session/server/state.ex`, `@provider_close_ms`); and a margin of 1,000 ms. `Helyx.Session.abort/1` itself waits with no timeout (`lib/helyx/session.ex`, `abort/1`). A test of the transport compares the constant with the two functions. A hands process with more releases queued takes longer: the client gets `timeout`, accepted |
| `stop` | 77,000 ms | the `abort` deadline, then the stop of the session process, at most `Stop.shutdown_ms/0`, 30,000 ms (`lib/helyx/session/server/stop.ex`, `shutdown_ms/0`): the close of a provider process that is left (5,000 ms), the stop of the hands, which can finish one release (22,000 ms), and 3,000 ms for load. The wire deadline is 1,000 ms above the sum. The stop of Core adds the release of `core.lock` (1,000 ms, `Helyx.Session.Lock.release_ms/0`) after the sessions. The test of the `abort` deadline compares this constant with `Stop.shutdown_ms/0` too. The Core call is `Helyx.Sessions.stop/1` (#657) |
| `start`, `resume` | none (#834, decision of the owner of 2026-11-06) | the open is bounded in the server, by the deadlines of the session: the lock take, `deadline_ms.open` (25,000 ms), and the load, which grows with the file (`docs/features/session-lock.md`, row "wait of the caller"; `docs/features/coding-agent.md`, row "Session file on resume"). A fixed deadline here would answer `timeout` for a large file while the session still opens. So the worker waits for the Core call, `Helyx.Sessions.start/2` or `resume/2`, and the client waits for the answer while the connection lives (`docs/features/tui-attach.md`, decision 17). Before the open, the tool checks run in the worker (`Helyx.Tool.check_available/1`, no timeout of its own): accepted hole, a check that blocks holds the request until the connection closes, as it held the worker before #834. The worker counts against the 16 requests in flight until it ends. A close of the connection kills the workers, which are linked to it; a session whose caller ended during its open stops after the open (`docs/features/session-lock.md`, row "the caller dies during the open"). The protocol number does not change: a client of the same protocol that keeps a deadline of its own gives `timeout` and drops the late reply, as before, and this client gets `timeout` from an older server, an error code it knows |
| `sessions.saved` | 10,000 ms; under a Hub 15,000 ms | a scan of at most 256 file heads of 64 KiB (`lib/helyx/session/file/scan.ex`, `@max_header_bytes` and `@max_scanned_files`); under a Hub the scan and one Hub call of 5,000 ms (`docs/features/hub.md`, decision 7) |
| `subscribe` | the call timeout of 5,000 ms (`lib/helyx/session.ex`, `@call_timeout_ms`) | the subscription process answers the exit as `timeout` |
| every other operation | 6,000 ms | an operation on one session is one session call with the call timeout of 5,000 ms, whose exit the worker answers as `timeout`; `sessions.live` (`Helyx.Sessions.list_live/1`, #657) answers within the same deadline; the 1,000 ms margin is for load |

Under a Hub, a `hub.*` operation has the deadline of every other operation, 6,000 ms, which holds its one Hub call. The `check` before an operation and the `result` after it have their own bound beside the deadline: one Hub call of 5,000 ms each, and in the `check` before that call the existence check of a session with no record, a search of the data folder of at most 5,000 ms, or for a `resume` of a folder the scan of `sessions.saved`, 10,000 ms (`docs/features/hub.md`, decisions 5 and 8, and its "Bounds").

### Subscriptions

- A subscription is one process under the connection. It calls `Helyx.Session.subscribe`, owns the Core subscription and its end monitor, encodes the events, and writes them to the socket in order.
- The server makes the `sub` id. It is unique on the connection.
- The session counts each event that it sends to the subscription, a replayed event too, and the `ack` frames of the client lower the count. `ack` with `seq` acks every event of that subscription up to `seq`. An `ack` lower than an earlier one changes nothing. An `ack` for a `sub` that the connection does not hold (it ended) is ignored. An `ack` above the last `seq` that the subscription sent when it takes the `ack` closes the connection with `4400`. The connection keeps the highest `ack` of each subscription and gives it to the subscription process one at a time, and none before the `subscribe` reply went. So the acks of a client hold one entry in the connection and at most one message in the subscription process, however many the client sends. The subscription sends the session only an `ack` above its credit base: the `seq` of the snapshot, or the `seq` of `after`.
- Past 16,384 unacked events, the session ends the subscription with `:slow`, and the transport closes the connection with `4408`. The client connects again and subscribes with `after`. A client acks at least every few thousand events; the server does not check the cadence, the bound decides.
- `session_end` ends the subscription. The connection stays open. A connection that closes with no `session_end` for a subscription is a lost connection: the session may still run, and the client subscribes again with `after`.
- A client that applies the snapshot keeps its `seq` and `instance_id`. After a reconnect it subscribes with `after: {instance_id, seq}` of the last event that it applied.

### Join, pages, and replay

- **Tail snapshot.** The newest messages of the transcript, at most `tail` of them and at most 16,777,216 bytes of message content, each message counted by `:erlang.external_size/1`. Then the cut moves to newer messages until the first message is a user or an assistant message, so an assistant message and its tool results stay together. When that leaves no message, the tail is the newest group alone: the last user or assistant message and the messages after it, whatever their count and size. `older` is the count of the older messages that the tail leaves out.
- **The state in the snapshot.** The snapshot has the full current state, whatever its tail: `turn` with its partial, `model`, `queue`, `persisting`, `seq`, `usage`, and `context`. `usage` and `context` count every message of the transcript, not only the tail. The client then adds each message that a later `message_end` or `tool_execution_end` carries, with the rule of `docs/features/usage-and-limits.md`, "The footer". It adds no message of a `history` page: a page changes neither `usage` nor `context`, and it does not move `seq`.
- **The rule of ADR 0006 §3, revised.** The snapshot at `seq` equals the loaded suffix of the transcript folded from every event up to `seq`, plus the full current state. The notices stay out, as before: "aborted", "error: …", harness notices, "resumed session". `persisting: false` still makes the not-saved text.
- **History.** `history` serves the live transcript of the session, not the file, so it holds the unsaved messages and the interrupted results of a resume. It returns the messages before `before`, with the limits and the cut of the tail, `limit` in place of `tail`, and the explicit cursor `next`: the id of the first message of the page while `older` is above 0, else null. The cursor of the tail snapshot is the id of its first message. `instance_changed` means that the session started again: the client subscribes again for a new snapshot.
- **Replay.** `subscribe` with `after` returns the events after `seq` from the replay ring, contiguous, then the live events follow with no gap and no duplicate. When `instance_id` is not the current instance, the events after `seq` are no longer all in the ring, or `seq` is above the last event, the result is a tail snapshot instead, with `tail` of the request.

### Codec

Every value is JSON. An atom is its name as a string. A message has the shape of a message entry of the session file without its `type` key (`lib/helyx/data/message/json.ex`): a key whose value is nil or false is left out, but for `is_error`, which a tool result always has. `ui_blocks` is on a tool result that has blocks, and left out when it has none. A reader takes a missing key as null or false, and a missing `ui_blocks` as no blocks.

A client is a tolerant reader (ADR 0006, revisions of 2026-10-03 and 2026-10-16): it dispatches on the `type` of an event first, ignores an event type that it does not know and a key that it does not know, and shows a placeholder for a block kind that it does not know. A client shows the `text` of a UI block of a kind that it does not know, or whose fields it cannot read, with a mark when `cut` is true: the schema has the envelope of a UI block and no kind, so a new kind needs no new protocol number (ADR 0011 §5). A known type with a broken shape is a contract break.

The wire leaves out two fields of Core events: `texts` of `queue_dropped` and `text` of `steer_unconfirmed`. The messages carry the same texts, so the frame is half the size.

The schema below is the contract. The test of #660 computes the SHA-256 of the lines between the two markers and compares it with the constant next to the protocol number.

<!-- wire-schema:start -->
```text
protocol 13

notation: {k: T} an object; k? may be absent (absent = null or false);
  T | U either; [T] a list; "x" that string; int a JSON integer >= 0;
  number a JSON number >= 0; id a string of 1 to 64 bytes;
  base64 a string of RFC 4648 base64 of at most 786,000 bytes;
  name a string of 1 to 64 bytes of a-z, 0-9, and _; json any JSON value

# client to server
hello   = {type: "hello", protocol: int, proof?: base64, token?: id}
req     = {type: "req", id: id, op: op, params: object}
ack     = {type: "ack", sub: string, seq: int}
part    = {type: "part", n: int, last: bool, data: base64}

# server to client
challenge   = {type: "challenge", nonce: base64}
welcome     = {type: "welcome", protocol: int}
refused     = {type: "refused", code: "protocol", server_protocol: int}
res         = {type: "res", id: id, ok: true, result: object}
            | {type: "res", id: id, ok: false, error: error}
event_frame = {type: "event", sub: string, event: event}
session_end = {type: "session_end", sub: string, reason: "stopped" | "crashed"}
record_frame  = {type: "record", change: record_change}
records_frame = {type: "records", records: [record], more: bool}
records_end   = {type: "records_end"}
part        (as above)

error      = {code: error_code, text: string}
error_code = "unknown_op" | "bad_params" | "busy" | "timeout" | "failed"
           | "session_not_found" | "too_many_sessions" | "too_many_subscriptions"
           | "unknown_sub" | "instance_changed" | "unknown_message"
           | "invalid_cwd" | "invalid_model_ref" | "unknown_provider"
           | "not_found" | "start_failed"
           | "invalid_utf8" | "invalid_origin" | "queue_full" | "turn_running"
           | "text_too_large" | "invalid_answer" | "not_waiting"
           | "forbidden" | "too_many_records" | "too_many_projects"
           | "unknown_project" | "unknown_token"
           | "too_many_schedules" | "unknown_schedule"
           | "too_many_event_subscriptions" | "unknown_subscription"

op = "sessions.live" | "sessions.saved" | "start" | "resume" | "subscribe"
   | "unsubscribe" | "history" | "prompt" | "steer" | "follow_up"
   | "abort" | "set_model" | "compact" | "stop" | "answer"
   | "hub.me" | "hub.records.get" | "hub.records.update" | "hub.records.delete"
   | "hub.records.search" | "hub.projects.list" | "hub.projects.create"
   | "hub.projects.update" | "hub.projects.delete" | "hub.tokens.list"
   | "hub.tokens.revoke"
   | "hub.schedules.list" | "hub.schedules.create" | "hub.schedules.delete"
   | "hub.subscriptions.list" | "hub.subscriptions.create" | "hub.subscriptions.delete"
   | "records.subscribe" | "records.unsubscribe"

params.sessions.live   = {}
params.sessions.saved  = {cwd?: string, after?: string, limit?: int}
params.start           = {cwd: string, model?: string}
params.resume          = {id: string} | {cwd: string}
params.subscribe       = {session: string, tail?: int,
                          after?: {instance_id: string, seq: int}, answers?: bool}
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
params.answer          = {session: string, ask_id: string, answer: object}
product_origin         = {kind: "product", id: string}
params.hub.me              = {}
params.hub.records.get     = {session: string}
params.hub.records.update  = {session: string, title?: string, labels?: [string],
                              visibility?: "private" | "hub", project?: string | null,
                              archived?: bool}
params.hub.records.delete  = {session: string}
params.hub.records.search  = {query?: string, labels?: [string], project?: string,
                              archived?: bool, mine?: bool, after?: string, limit?: int}
params.hub.projects.list   = {}
params.hub.projects.create = {name: string}
params.hub.projects.update = {project: string, name: string}
params.hub.projects.delete = {project: string}
params.hub.tokens.list     = {}
params.hub.tokens.revoke   = {token: string}
params.hub.schedules.list   = {session?: string}
params.hub.schedules.create = {session: string, at: int, every?: int, prompt: string}
params.hub.schedules.delete = {schedule: string}
params.hub.subscriptions.list   = {session?: string}
params.hub.subscriptions.create = {session: string, prompt: string, label?: string}
params.hub.subscriptions.delete = {subscription: string}
params.records.subscribe    = {}
params.records.unsubscribe  = {}

result.sessions.live  = {sessions: [live_session]}
result.sessions.saved = {items: [saved_session], next: string | null}
result.start          = {session: string}
result.resume         = {session: string}
result.subscribe      = {sub: string, replay: [event]} | {sub: string, snapshot: snapshot}
result.history        = {messages: [message], older: int, next: string | null}
result.unsubscribe, result.prompt, result.steer, result.follow_up,
result.abort, result.set_model, result.compact, result.stop, result.answer = {}
result.hub.me              = {user: user}
result.hub.records.get, result.hub.records.update = {record: record}
result.hub.records.search  = {items: [record], next: string | null}
result.hub.projects.list   = {projects: [project]}
result.hub.projects.create, result.hub.projects.update = {project: project}
result.hub.tokens.list     = {tokens: [token]}
result.hub.records.delete, result.hub.projects.delete, result.hub.tokens.revoke = {}
result.hub.schedules.list   = {schedules: [schedule]}
result.hub.schedules.create = {schedule: schedule}
result.hub.schedules.delete = {}
result.hub.subscriptions.list   = {subscriptions: [subscription]}
result.hub.subscriptions.create = {subscription: subscription, secret: string, path: string}
result.hub.subscriptions.delete = {}
result.records.subscribe   = {records: [record], more: bool}
result.records.unsubscribe = {}

live_session  = {id: string, instance_id: string, cwd: string, model: string,
                 status: "idle" | "running"}
saved_session = {id: string, cwd: string, model: string, mtime: int, prompt: string}

user     = {id: string, name: string}
# project: null for a user who does not own the record (the project is the owner's)
record   = {session: string, owner: user, project: string | null, title: string,
            labels: [string], visibility: "private" | "hub", archived: bool,
            created_at: int, updated_at: int, cwd: string, model: string,
            prompt: string, active_at: int, parent: parent | null,
            status: "idle" | "running" | "waiting" | "stopped"}
# the link of a child to the call that started it, or of a thread to its session
parent   = {session: string, kind: "child" | "thread"}
record_change = {kind: "new" | "changed", record: record}
              | {kind: "removed", session: string}
project  = {id: string, name: string, created_at: int}
token    = {id: string, name: string, created_at: int}
schedule = {id: string, session: string, at: int, every: int | null, prompt: string,
            pending: bool, last_at: int | null,
            last_outcome: "delivered" | "missed" | "refused" | "unconfirmed" | null}
# an event subscription: `path` is `/hooks/<id>`; no item of a list holds its secret
subscription = {id: string, session: string, label: string, template: string,
                created_at: int, pending: bool, last_at: int | null,
                last_outcome: "delivered" | "missed" | "refused" | "unconfirmed" | null,
                path: string}

snapshot = {instance_id: string, seq: int, messages: [message], older: int,
            turn: turn | null, model: string, queue: queue, persisting: bool,
            usage: totals, context: context | null, asks: [ask],
            ui_blocks: [shown_block], activated: [string]}
ask      = {ask_id: string, call_id: string, tool: string, request: object}
shown_block = {call_id: string | null, key: string, block: ui_block}
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
           | "notice" | "ask" | "ask_end" | "ui_block" | "tools_change"
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
data.ask                = ask
data.ask_end            = {ask_id: string, outcome: "answered" | "ended"}
data.ui_block           = shown_block
data.tools_change       = {activated: [string]}

message = {id: string, role: "user" | "assistant" | "tool_result",
           content: [block], origin?: origin, model?: string,
           stop_reason?: stop_reason, tool_call_id?: string, tool_name?: string,
           is_error?: bool, usage?: usage, ui_blocks?: [ui_block]}
block     = {type: "text", text: string} | {type: "thinking", thinking: string}
          | tool_call
tool_call = {type: "tool_call", id: string, name: string, arguments: object}
origin    = {kind: "user" | "background" | "product" | "hook",
             id: string | null}
stop_reason = "end_turn" | "tool_use" | "max_tokens" | "refused" | "aborted" | "error"
usage = {input: int, output: int, cache_read: int, cache_write: int,
         cost?: number, cost_kind?: "list" | "billed",
         context_tokens?: int, context_window?: int}
# the envelope of a UI block; each other key is a field of its kind
ui_block = {kind: name, text: string, cut?: bool, *: json}

# order rules (a schema cannot show them; a change needs a new protocol number)
O1 challenge is the first server frame, once; hello is the first client
   frame; the server sends nothing but challenge before hello and nothing but
   welcome or refused after it, and the client sends nothing else before
   welcome. proof = base64(HMAC-SHA256(SHA-256(token), the 32 bytes of nonce)).
O2 each req gets exactly one res, also at timeout; none after the close.
O3 the parts of one frame are consecutive, n from 0, last on the final one.
O4 per subscription: the subscribe res, which carries the replayed events,
   then its live events in seq order with no gap and no duplicate after the
   replay, then at most one session_end, last. No frame of a sub follows its unsubscribe res.
O5 session_end comes after every event of the session.
O6 frames of two subscriptions, and a res and an event, have no order
   between them.
O7 the records.subscribe res comes before every record, records, and
   records_end frame of the connection; no such frame comes after the
   records.unsubscribe res, and records_end is the last frame of the feed.
```
<!-- wire-schema:end -->

Notes on the codec:

- `origin`: `id` is null for `"user"` (`docs/features/message-identity.md`). `"hook"` is the user message of a continue of a `before_settle` hook, with the name of the hook module as its `id` (`docs/features/before-settle.md`); a client cannot send it, as it cannot send `"user"`. Protocol 4 added it (#880).
- `error` of `message_end`: `{kind: "aborted"}` for an aborted turn, `{kind: "failed", text}` for a failed one, where `text` is the error text of the turn (ADR 0006 §2). The two are kept apart, because a failure text can be the word "aborted".
- `turn_end` `error` and `notice` `text` are text for a person; a client shows them as they are.
- `arguments` of a tool call is a JSON object whose integers have at most 100 digits (`Helyx.Message.cap_integers/1`). The schema does not bound them, and a client takes any integer (#860).
- A `cost` is in USD. `elapsed_ms` is by the clock of the session; a client starts its busy clock at that age.
- The session that a tool call starts with a parent link, such as a child of the `agent` tool, has an id that a client derives from the session id and the call id: the first 9 bytes of SHA-256 of the session id followed by the call id, as URL-safe Base64 with no padding (`Helyx.Sessions.child_id/2`, `docs/features/agent-tool.md`). No frame carries it.

## Conformance fixtures

`test/fixtures/wire/` holds fixtures of protocol 13 as plain JSON (#855): the frames that a client sends, each with the frames and the close code of the server; the frames that a server sends, each valid, ignored, or a contract break for a client; and folds, event sequences with the state that a client holds after them. Its `README.md` states what a conforming client or server must pass and which rules are in prose only. The transport tests run the client frames against the server, the TUI tests run the server frames and the folds against the client and its view model, and the Rust client core runs `records.json`, so the fixtures and the code cannot drift.

What this doc does not pin down for an implementation that does not run on the BEAM. Each is open, not decided here:

- **The size of a message.** The byte bounds of the tail snapshot, of a `history` page, and of the replay ring count each message or event with `:erlang.external_size/1`, the size of the term in the external format of Erlang. A server on another runtime cannot compute it, and a client cannot predict where a tail ends. A portable admission rule, such as a count over the JSON text, would be a protocol change.
- **Replay.** The replay ring is in the memory of one session instance and bounded (1,024 events and 4 MiB). A restart of the session, a new `instance_id`, or a gap in the ring gives a tail snapshot, not the missed events. Replay is not durable; a durable replay would revise ADR 0008.
- **The form of a model ref.** The schema gives `model` as a string. A server of this build sends a model ref, `provider/model` with no whitespace or control character (`Helyx.ModelRef`), and answers `invalid_model_ref` to another string in a request; the client of the TUI takes any string and shows it cut and cleaned (#860).
- **A session id.** The schema gives `id` as a string. A `resume` of an id that is not 12 URL-safe characters gets `start_failed`, not `not_found`.
- **A request id over its bound.** A `req` whose `id` is a string of more than 64 bytes gets `bad_params` ("Bounds"), and that `res` carries the same `id`, though the schema gives the `id` of a `res` as 1 to 64 bytes.

## Replaced mechanism

1. **The full snapshot of every subscribe** (`Events.snapshot/1` before #658). A wire subscribe gets a tail snapshot with the usage totals and the context state as fields (#658). `Helyx.Session.subscribe/1` with no `tail` keeps the full snapshot for a client in the node. From #809 the TUI subscribes only over the wire; the callers in the node with no `tail` are print mode (`CodingAgent.Print`), which reads the queue and `persisting` of the snapshot, the agent tool (`Helyx.Tool.Agent`), which reads none of it, the dev task `mix helyx.graph` (`apps/coding_agent/dev`), which reads none of it, and tests. No caller needs the transcript of the snapshot, and the rule stays: a print run that resumes a long session copies its transcript once.
2. **Reconnect with a new full snapshot** (ADR 0006 §3). Replaced by the replay ring and `after` (#659). The new snapshot still replaces all client state when the ring cannot serve the interval.
3. **The end signal as a `:DOWN`** (`docs/features/end-signal.md`). It stays for a client in the node. On the wire, the subscription process turns the `:DOWN` into `session_end`; it is the one process that sees both the events of the session and the `:DOWN`, and the session sends its last event before it dies, so `session_end` comes last (O5).
4. **`send/2` with no bound** (`events.ex:66`). Replaced by the credits (#659); the `:slow` end is a new item of the closed list of ADR 0006 §2.
5. **The build-id rule** of ADR 0006 (revision of 2026-10-03). Replaced by the protocol number and its schema test.
6. **HTTP and SSE as a Transport plugin** (ADR 0006 §6). Replaced by `Helyx.Transport.WebSocket`, a bundled module with no Core interface.
7. Tests: no test of the old remote plan exists. `test/helyx/session/end_signal_test.exs` keeps its properties for the local end signal.
8. **The token in `hello`** (protocol 1, #660). Replaced by `challenge` and `proof` in protocol 2 (#763): a frame held the token, and the logs of the WebSocket server that hold frame bytes or `conn` held it with the frame.
9. **The SHA-256 of the token in the plug options and the process states** (#660). The SHA-256 of the token is now the key of the proof, so it is in a closure. The test "the connection state holds no token" is replaced by the test that inspects the state of every process of the transport and the child spec, and by the three log tests (`plugins/bundled/test/helyx/transport/web_socket_test.exs`).
10. **Protocol 3** (#880). Protocol 4 adds the origin kind `"hook"` to `origin`; nothing else changes. A client of protocol 3 gets `refused` and the close `4426`, and the fixtures named protocol 4.
11. **Protocol 4** (#878). Protocol 5 adds UI blocks (ADR 0011, `docs/features/ui-blocks.md`): `ui_blocks` in a tool result `message`, the `ui_block` event, and the snapshot field `ui_blocks`; nothing else changes. A client of protocol 4 gets `refused` and the close `4426`, and the fixtures name protocol 5.
12. **Protocol 5** (#869). Protocol 6 adds the Hub (ADR 0010, `docs/features/hub.md`): the `token` of `hello`, the `hub.*` operations of records, projects, tokens, and the user, their params and results, and the error codes `forbidden`, `too_many_records`, `too_many_projects`, `unknown_project`, and `unknown_token`; a server with no authority answers as protocol 5 did. A client of protocol 5 gets `refused` and the close `4426`, and the fixtures name protocol 6. The schedules of a Hub (#870) come with protocol 7.
13. **Protocol 6** (#870). Protocol 7 adds the schedules of a Hub (`docs/features/hub.md`, decisions 11 and 12): the operations `hub.schedules.list`, `hub.schedules.create`, and `hub.schedules.delete`, their params and results, the shape `schedule`, and the error codes `too_many_schedules` and `unknown_schedule`; a server with no authority answers them with `unknown_op`, as every `hub.*` op. A client of protocol 6 gets `refused` and the close `4426`, and the fixtures named protocol 7.
14. **Protocol 7** (#492, `docs/features/mcp-client.md`). Protocol 8 adds the event `tools_change` with `data.tools_change`, the activated deferred tool names in drop order (the first name leaves first when the session drops one for its cap; a client only shows the list), and the snapshot field `activated`, the same list; nothing else changes. A client of protocol 7 gets `refused` and the close `4426`, and the fixtures name protocol 8.
15. **Protocol 8** (#921, `docs/features/hub.md`, decision 17). Protocol 9 adds the event subscriptions of a Hub: the operations `hub.subscriptions.list`, `hub.subscriptions.create`, and `hub.subscriptions.delete`, their params and results, the shape `subscription`, and the error codes `too_many_event_subscriptions` and `unknown_subscription`; the webhook endpoint itself is HTTP beside the WebSocket upgrade and carries no frame. A client of protocol 8 gets `refused` and the close `4426`, and the fixtures name protocol 9.
16. **Protocol 9** (review of 2026-11-11). Protocol 10 puts `older`, the count of the messages before the first of the list, in place of `more` in the snapshot and in the result of `history`: a client derives "more" from `older > 0`. It removes the origin kind `"unknown"`, since no session file from before #649 is read. A client of protocol 9 gets `refused` and the close `4426`, and the fixtures name protocol 10. `test/fixtures/wire/bounds.json` holds the numbers of "Bounds" and the error codes once; the server reads it (`Helyx.Transport.WebSocket.Bounds`).
17. **Protocol 10** (E.2, `docs/features/hub.md`, decision 8). Protocol 11 gives `record` what a sidebar needs in one call: `cwd`, `model`, `prompt`, `active_at`, `parent`, and the derived `status`; it removes `stored`, which was always true, so `created_at` and `updated_at` are always integers. A client of protocol 10 gets `refused` and the close `4426`, and the fixtures name protocol 11.
18. **Protocol 11** (#957, `docs/features/live-records.md`). Protocol 12 adds the records feed of a user: the operations `records.subscribe` and `records.unsubscribe`, their params and results, the `record_frame` and `records_frame` frames, `record_change`, and the status `"waiting"` of a record. A client of protocol 11 gets `refused` and the close `4426`, and the fixtures name protocol 12.
19. **Protocol 12** (review of 2026-11-12, `docs/features/live-records.md`). Protocol 13 adds `records_end`, the last frame of a records feed when the Hub process behind it ends, such as a restart of Hub under its supervisor: the client subscribes again and gets the list. It also lets `records.unsubscribe` answer `unknown_sub` on a server with no Hub, as a client that never subscribed has no subscription. A client of protocol 12 gets `refused` and the close `4426`, and the fixtures name protocol 13.

## Bounds

| What | Bound | Over the bound | Where enforced |
|---|---|---|---|
| WebSocket frame, both ways | 1,048,576 bytes of JSON text; a larger frame goes as parts | an inbound frame over it: close `1009` | transport |
| inbound WebSocket message of fragments | 1,048,576 bytes of the joined fragments | close `1009` | transport (the WebSocket server) |
| one inbound frame joined from parts (the request size) | 26,214,400 bytes (25 MiB): a text at the Core bound of 4,194,304 bytes in its worst JSON form, six bytes for each byte (`\u0001`), is 25,165,824 bytes, and the rest, 1,048,576 bytes, is for the other fields of the request | close `4413`; the parts are dropped as they come | transport |
| the decode bounds of one inbound frame (#787) | 65,536 values, and integers of at most 1,024 characters, the minus sign included. Each array, object, string, number, `true`, `false`, and `null`, and each object key, counts one value. An array or an object counts at its start, with its key, so a nesting of arrays of more than 65,536 levels, or of objects of more than 32,766 levels, is refused before its end; a key of another value counts with that value. The decode stops at the first value over the bound, and at the first integer over the bound before it converts it. A float is in the range of a 64-bit float: `1e400` does not decode. So the decoded value of a frame holds at most 65,536 values, each integer of at most 55 words; the strings of more than 64 bytes are off the heap, at most the bytes of their text. The peak heap of a decode has no stated bound, only measurements (open, see the review of #787). Measurements and margin: "The decode bounds, measured" | close `4400`, the answer of bad JSON: the connection ends, and its subscriptions with it | transport (`Helyx.Transport.WebSocket.Frame`) |
| the decode bounds of one outbound frame, for a client (#814) | 1,611,661,312 bytes of a frame joined from parts, 38,797,312 values counted as for an inbound frame, and integers of at most 1,024 characters: the largest frame that the server sends by its bounds, a `queue_dropped` of 64 texts of 4 MiB in their worst JSON form, and the most values, a tail snapshot whose newest group comes from the file. The derivation and the measurements are in `docs/features/tui-attach.md`, decision 13 | a contract break of the server: the client ends the connection | the client (`Helyx.Transport.WebSocket.Frame.decode/3` with `:outbound`) |
| the largest integer of the BEAM, for the JSON decoders of other boundaries | 2^4,194,240 − 1 on OTP 28 (65,535 words of 64 bits, 1,262,593 digits; measured): every integer of 1,262,592 digits or fewer decodes with `JSON.decode/1`, and 1,262,593 nines raise `SystemLimitError`. The transport refuses an integer far below it, at its decode bounds | `Helyx.JSON.decode/1` gives an error, not a raise; the decoder of each boundary states its answer | OTP; `Helyx.JSON.decode/1` at the other boundaries, and the Credo check `Helyx.Credo.JSONDecode` reports a call written `JSON.decode` or `JSON.decode!` in other `lib/` code (#792) |
| requests in flight per connection | 16, from the `req` to the end of its worker; a `subscribe` from the `req` to its reply | `res` with `busy` | transport |
| requests in flight per server | 1,024: 64 connections of 16 | as above | transport |
| calls that a session holds after their caller timed out | unbounded, ticket #677: Core does not count them. A caller adds one call for each call timeout while the session stalls. A call that the session takes past its deadline does not act (`docs/features/session-lifecycle.md`, "Late calls", #679). The worker of a remote request must keep its slot until the session answers or the call passes its deadline (#660) | the late call does not act and gets no reply | Core (#679), transport (#660) |
| params of a request worker | the checked params of its one request: the connection checks the params before it starts the worker, so the decoded frame, within the decode bounds, stays in the connection. The decode makes each string a copy (`Helyx.Transport.WebSocket.Frame`), so no worker, subscription, or session keeps the text of the frame; the copy takes at most one more request size in the connection while it decodes. The checked values are strings and integers, each no larger than its JSON text, so a worker holds at most the request size, 26,214,400 bytes; the 16 workers of a connection at most 419,430,400 bytes (400 MiB). The answer of `answer` is an object: the op is a key in the JSON text, so the connection decodes the frame before it knows the op, and then checks the answer with `Helyx.Session.check_answer/1`, a walk that stops past 16,384 bytes of JSON. A worker holds an answer of at most that JSON (#744) | `res` with `bad_params`, and no worker; an answer over its bound gets a worker that holds only the error and replies `invalid_answer` | transport |
| subscriptions per connection | 16 | `res` with `too_many_subscriptions` | transport |
| connections per server | 64 | HTTP 503 at the upgrade | transport |
| stop of the transport (#793) | 20,000 ms in all, the sum of the two shutdowns below, and the milliseconds of the process exits (20,006 ms measured with a stuck first step, review of 2026-10-19). Its first step, within 5,000 ms (the shutdown of that step), closes the listener and the connection gate, so a later upgrade gets HTTP 503, and kills at once each connection that is not inside the gate: a connection inside its HTTP headers, or one whose upgrade was refused, holds no session. Then each WebSocket connection gets close `1000` and stops. All connections are in one acceptor group of Thousand Island, so they stop together, each within 15,000 ms (`shutdown_timeout`): the close can wait for a client that does not read. After a crash of the gate or of the listener, the first step does nothing: Thousand Island alone stops every connection, within 15,000 ms | the transport supervisor kills the first step past 5,000 ms, and its stalled connections then stop with the WebSocket ones; Thousand Island kills a connection past 15,000 ms | transport (`Helyx.Transport.WebSocket`) |
| TCP connections per server, before and after the upgrade | 16,384: the `num_connections` of the one acceptor group of Thousand Island | Thousand Island waits up to 5 × 1,000 ms for a place, then closes the new connection; the acceptor takes no other connection while it waits | transport (Thousand Island) |
| live sessions per server | 64 | `start` or `resume` gets `too_many_sessions`; a `resume` of a session that runs attaches | the session supervisor of Core, for every caller (`docs/features/server-management.md`, #657) |
| auth wait | 5,000 ms from the upgrade to `hello` | close `4401` | transport |
| challenge | one for each connection, a nonce of 32 random bytes | a second `hello`: close `4400` | transport |
| the wait of a client for `challenge` | 5,000 ms, the auth wait: the server sends `challenge` at the upgrade, inside the auth wait | the client closes; the conformance client fails | client |
| a peer that is gone | a ping every 15,000 ms; 45,000 ms with no inbound frame or pong | close `4408` | transport |
| replay ring per session | 1,024 events and 4,194,304 bytes, each event counted by `:erlang.external_size/1`. A message is in the ring twice, as its deltas and as its `message_end`, so the ring holds about 2 MiB of new text | the oldest events go; an event over 4 MiB empties the ring and marks a gap, so a replay over it gives a snapshot | session (#659) |
| replay rings of the server | 268,435,456 bytes: 64 live sessions of 4 MiB. No accounting across sessions is needed | as above | the live-session cap |
| tail snapshot and page, count | default 200, at most 1,000; or the newest group alone | a value over 1,000: `bad_params` | session (#658) |
| tail snapshot and page, bytes | 16,777,216 bytes of message content (`:erlang.external_size/1`); or the newest group alone. A group is one assistant message of at most 1,024 blocks, live by `Helyx.Session.Turn` (`lib/helyx/session/turn.ex`, `@max_message_blocks` and `@max_message_bytes`), which also bounds it at 8 MiB, and at file read by #673, where only the 64 MiB of its line bounds its bytes (#834), with at most one tool result for each call (at read, `Helyx.Session.Transcript.repair/1` drops a second one, `lib/helyx/session/transcript.ex`, `repair/1`), each text block of a result at most 64 KiB (`lib/helyx/data/message.ex:184`, and at read `Codec.decode/1` cuts each block, `lib/helyx/session/file/codec.ex`); a result has no total bound of its own beyond the blocks of its message. The snapshot also carries the turn partial, at most 8 MiB | the tail ends; it goes as parts | session (#658) |
| request results per connection | 1: a `subscribe`, `history`, or `sessions.saved` request takes the one encoder slot of the connection before it reads its data from Core, and holds it until its reply is in the outbound queue. So at most one snapshot or page result exists per connection, and a waiting request holds no result. The wait for the slot is not in the deadline of the request; the request counts against the requests in flight while it waits. The connection checks the keys and the types of the params before the wait, so a request that fails that check gets `bad_params` while another holds the slot; a value that only Core checks, such as a `limit` out of its range, gets its answer after the wait. Another operation has a small result and takes no slot, and an event takes no slot: its subscription process encodes it | | transport |
| credits per subscription | 16,384 unacked events, a replayed event too. The bound is for each subscription, not for each process: each subscription of a connection is its own process, a connection holds at most 16 of them, and the outbound queue bounds the encoded frames of each connection. The acks of a client hold one entry in the connection and at most one message in each subscription process ("Subscriptions"). The count is chosen above the 10,000 provider messages that the session can hold waiting (`lib/helyx/session/stream.ex`, `@max_session_queue`), a heuristic: that number bounds messages, not events, and the burst test checks it. The credits count events only: the byte bound is the outbound queue | the subscription ends with `:slow`; close `4408` | session (#659) |
| outbound queue per connection | 67,108,864 bytes of frames added and not yet taken by the socket. A subscription process encodes each event when it takes it, and a writer adds each frame with a message to the connection process and a shared byte count, with no wait for room. Before each add, the writer checks the bytes of the queue without the frames that the connection already took for the socket, so one large frame does not close the connection at the next add | the queue holds more than 64 MiB at an add: close `4408` | transport |
| text of `prompt`, `steer`, `follow_up`, `compact` | 4,194,304 bytes of UTF-8: Core refuses a longer text from any caller with `{:error, :text_too_large}` (#672). The request size has room for this text in any JSON form, so the wire refuses no text that Core admits | `res` with `text_too_large` | Core (#672) |
| `queue_dropped` | 64 messages (32 steers, 32 follow-ups, `lib/helyx/session/queue.ex`, `@limit`), each of one text of at most 4 MiB (#672). It reaches only the subscribers that are connected when the session emits it; a client that connects later gets a tail snapshot, which does not hold the texts | goes as parts | Core |
| `answer` | a JSON object, else `bad_params`; 16,384 bytes of JSON of valid UTF-8, checked in the connection before the worker | `res` with `invalid_answer`; an answer whose frame is also over the decode bounds closes with `4400` | Core (`Helyx.Session.check_answer/1`) |
| `request` of an `ask` | 65,536 bytes of JSON | the tool call fails | Core (`Helyx.Tool.ask/1`) |
| a UI block, in `ui_blocks` of a message and in a `ui_block` event | 65,536 bytes of JSON, and integers of at most 100 digits; at most 8 blocks in a tool result, 8 keys of `ui_block` for one call and for `call_id` null in one turn, and 72 blocks of `ui_block` events that a turn holds, so at most 72 in the snapshot `ui_blocks` (`docs/features/ui-blocks.md`) | Core cuts a block over the byte bound to `{kind, text, cut: true}` and refuses any other break at its carrier, so a client never gets one: for a client it is a contract break | Core (`Helyx.UIBlock.check/1`) |
| request `id` | 1 to 64 bytes | `bad_params`; with no readable `id`, close `4400` | transport |
| `sessions.saved` page | 1 to 256 items, default 50 | `bad_params` | Core (`Helyx.Sessions.list_saved/2`) |
| live list | 64 items | | the live-session cap |
| webhook request body | 1,048,576 bytes | HTTP 413, and the authority sees no body | transport |
| webhook requests handled at once | 16 per server, and each holds one body of at most 1,048,576 bytes | HTTP 503 | transport (a gate of its own) |
| webhook `id` in the path | 1 to 64 bytes; a stored id has 12 | HTTP 404 | transport (the shape), the authority (the lookup) |
| webhook body read | 30,000 ms | HTTP 400 when the read fails | transport |
| webhook call to the Hub | 5,000 ms (the Hub call of decision 5) | HTTP 503, and the sender tries again later | the authority |
| records feed of a connection | one subscription; the first list and each full list of `Helyx.Hub.RecordFeed.max_reply/0`; the changes that wait for one subscriber `Helyx.Hub.RecordFeed.max_pending/0` | `too_many_subscriptions` for a second subscription; a subscriber over the bound gets a full list at the next poll | Hub, the transport (`docs/features/live-records.md`, "Bounds") |

The decode bounds, measured (#787; OTP 28, Elixir 1.19.5, the dev machine; a second run of the spec review gave times up to 25% higher):

- **Memory.** The peak heap of a decode, the smallest `max_heap_size` with which it ends: about 69 MiB for an object of 30,200 pairs of 64-byte keys and 800-digit integers (the largest found, round 2 of the review), 58 to 59 MiB for 25 MiB of 368-digit to 450-digit integers, about 48 MiB for 25 MiB of 1,024-digit integers (the decoded integers are on the heap), about 22 MiB for a frame at the value bound of 64-byte strings, and about 10 MiB for nested arrays, nested objects, floats, and objects at the value bound and for 25 MiB of `[`. Before #787, 25 MiB of `[` took about 1.1 GB (extrapolated from 171 MB for 4 million levels, review of #782). The tests run three refused frames of 25 MiB (nesting, integers near the BEAM limit, and 1,024-digit integers with one integer over the bound) in a process with a heap bound of 64 MiB; that bound holds for these frames, not for every frame.
- **Work.** Linear in the text. An integer of 1,024 digits converts in 4 to 6 µs, less work per byte than the other JSON of a frame; a float of 1,000,000 digits decodes in 2 to 4 ms. The slowest frames of 25 MiB measured, a string of `\n` escapes and 25,000 integers of 1,024 digits, decode in 0.25 to 0.35 s. Before #787, 20 integers just under the largest integer of the BEAM took about 4.4 s; now the decode stops at the first of them, after 1 to 3 ms.
- **Cost.** A prompt frame of 1 MiB decodes in 1,266 µs, against 1,195 µs with no bound (median of 21 runs, +71 µs, 6%); the spec review measured +0 µs for plain text and +100 µs for a text of escapes.
- **Margin.** A real client sends at most 8,206 values: an `answer` of 16,384 bytes of JSON holds at most 8,192, as `{"":[0,0,…]}` with 8,189 zeros, and the other fields of its frame 14. It sends integers of at most 100 digits: `Helyx.Session.check_answer/1` refuses a larger integer in an answer, and the other integers of a frame are a `seq`, `limit`, `tail`, `n`, or `protocol`. The bounds are 7.9 and 10 times these. A prompt frame holds 13 values, 19 with `origin`, whatever its text.

The memory of a connection follows from these bounds and the Core bounds of #672, #673, and the 8 MiB message (`Helyx.Session.Turn.max_message_bytes/0`); this doc claims no single number for it.

Each numeric limit gets tests at the limit, one under, and one over, and the frame limits a multibyte case at the edge of a part (#660).

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
|---|---|---|---|---|---|
| listen socket | the start of the transport | the WebSocket listener under the transport supervisor | the stop of the transport | the transport supervisor stops at a crash of the listener, of the gate, or of the first step of the stop (`one_for_all`, no restart), and the supervisor of the product starts it again | n/a |
| connection gate | the start of the transport | the transport supervisor | the stop of the transport; the place of a connection at the `:DOWN` of its process | as above, with a new, empty gate | n/a |
| socket | the accept | the connection process | the close of either side; at a stop of the transport, a socket that has not entered the gate closes with its killed process | the socket closes with its owner | n/a |
| request worker | a `req` | the connection process (linked) | its `res` | it dies with the connection | n/a: an `abort` request is one worker |
| deadline timer of a request | the worker | the worker | the end of the worker, at its reply or a crash | the connection: a timer to a process ends with it | n/a |
| subscription process | `subscribe` | the connection process (linked) | `unsubscribe`, `session_end` | it dies with the connection; its Core subscription ends at the session's `:DOWN` of it (`session-subscribers.md`, S4) | n/a |
| Core subscription and end monitor | the subscription process | the subscription process | the end of the subscription process: the session drops the entry at its `:DOWN` | the session drops the entry at its `:DOWN` | n/a |
| replay ring | the session | the session process | ends with the session | ends with the session | n/a |

## Out of scope

- Code: #657 to #662, and the Core bounds that they build on: #672 (a text of at most 4 MiB) and #673 (at file read, a message of at most 1,024 blocks and 8 MiB).
- Push to an app that is closed: `Helyx.Hub` sends it, and the client host receives it (ADR 0010).
- A browser client.
- Paging inside one message body: parts carry any size (#658).
- stdio framing code: same frames, a later ticket when a client needs it (#660).
- The `hands` role of `hello` and the `hands.*` operations and events of remote hands: decided in ADR 0012 (#856); the codec and a new protocol number come with its build ticket.
