# TUI attach

Ticket #662. Decisions of the orchestrator, 2026-10-19 (owner away), in the comments of the ticket.

## Goal

The TUI becomes a wire client. `helyx` attaches to the server of its data folder, or starts one in the background, as tmux does. Quitting the TUI leaves the sessions running. This is the end state of ADR 0008: one long-running server owns the sessions, and every client is on one wire contract (`docs/features/wire-protocol.md`). The server is `helyx serve` (`docs/features/serve.md`).

User stories:

- A user quits the TUI during a long turn, opens it again, and sees the turn still running.
- A user who never ran `helyx serve` types `helyx`, and it works as today.

Decisions:

1. **Find the server.** The client finds the server of its data folder by `<data folder>/server.json`, while the lock `<data folder>/server.lock` is held (serve.md, decision 8). It refuses a data folder that its group or other users can write, with the line of `helyx serve`: such a user could write a server file that sends the prompts of the user to another server. A data folder that is not there is no server. A path that is not a directory gives `helyx: the data folder <dir> is not a directory`, and a failed stat `helyx: could not read the data folder <dir>: <reason>`. The client tests the lock with a non-blocking take (`Helyx.Session.Lock.take/1` on `<data folder>/server`). When it gets the lock, no server runs: it releases the lock at once and takes the folder as no server. It never removes the file: the next `helyx serve` replaces it. The take runs in a Task of its own, which traps exits as `Lock.take/1` needs and ends after the take, so no message of the port stays in the mailbox of the caller.
2. **Read the file as `helyx serve` reads it.** The client and a second start read the file with one function, `CodingAgent.Serve.read_file/1`: a regular file, at most 4,096 bytes, a JSON object with `address` a parsed IP address and `port` an integer from 1 to 65535. The client also needs `token`, a string. A file that fails a check is no valid file.
3. **The server is starting.** With the lock held, a missing or invalid file, a file with no string token, a refused TCP connection, any other failure up to the `101` reply of the upgrade, a close of the server before `welcome` (such as `4401`, a refused proof, or a close inside a frame), and the timeout of the connect mean that the server is starting: ticket #777 holds the race from the `flock` of a new server to its remove of the stale file, in which the file can name a dead server, and its port can be in use by another program. The client tests the lock, reads the file, and connects again every 100 ms, as a second `helyx serve` does, and starts no attempt after 5,000 ms (`CodingAgent.Serve.wait_ms/0`). Then it shows one line, `helyx: could not attach to the server of <dir> in 5000 ms: <reason>`, with the reason of the last attempt, and exits 1. A lock that is free at a later attempt is no server. The comment of the orchestrator names the refused connection and the refused proof; the other failures before `welcome` join them, so one rule covers every failure that a server in its start or its stop can give.
4. **The handshake.** The client connects over TCP to the address of the file, sends the upgrade, checks `101` and `Sec-WebSocket-Accept` (RFC 6455), waits for `challenge`, sends `hello` with its protocol number (`Helyx.Transport.WebSocket.protocol/0`) and the proof of the token (wire-protocol.md, O1), and waits for `welcome`. The token is the secret of the server: it stays in a closure, and no error, line, or crash report holds it.
5. **Refused.** On `refused` the client shows `helyx: the server speaks protocol <server_protocol>, this client speaks <n>; install the same build` and exits 1. It does not retry and starts no second server: the lock of the data folder is held, so a second `helyx serve` exits 1 anyway. `server_protocol` is checked as a JSON integer of 0 or more before it reaches the line.
6. **A contract break.** After a valid `101` reply, any frame or value that the handshake does not allow is a contract break: a text that is not JSON or is over the decode bounds of the transport, a frame over the frame bound, a masked frame, a reserved bit, a binary frame, a control frame that is fragmented (FIN 0) or over 125 bytes, a continuation with no start, a `part`, a frame type that the handshake does not expect or a missing key, a nonce that is not the base64 of 32 bytes, a `welcome` of another protocol number, and a `refused` whose `server_protocol` is not an integer of 0 or more. It gets one generic line, `helyx: could not attach to the server at ws://<address>:<port>: the server broke the wire contract`, at once, with no retry. A real server of this build sends none of these. A ping or a pong is skipped, also between the fragments of a text.
7. **The TUI over the wire** (slices 2 and 3). The TUI keeps its pure fold `Helyx.TUI.ViewModel`. A connection process owns the socket, decodes each frame with the codec of the transport (`Helyx.Transport.WebSocket.Frame`), turns each wire event into the Core event that the fold takes (the message shape is the message entry of the session file, `Helyx.Session.File.Codec`), and acks it. The operations of the TUI become requests: `steer`, `follow_up`, `abort`, `set_model`, `compact`, `answer`, `start`, `resume`, `sessions.saved`. The TUI subscribes with `answers: true`.
8. **Quit leaves the sessions running** (slice 3). Over the wire, a quit closes the connection and sends no `abort`: the session runs on in the server.
9. **The log** (slice 3). The TUI writes its log to `<data folder>/tui.log` (`CodingAgent.log_to_file/2`); a server that the client starts writes its output to `<data folder>/server.log`. The two run in two OS processes, so their logs do not mix. The process-global handler change of `log_to_file/2` then holds only the client.
10. **Auto-start** (slice 4). With no server, `helyx` starts `helyx serve` in the background through the launcher: a new process group, stdin on `/dev/null`, stdout and stderr to `server.log`. Then it waits for the server as decision 3 does. Two clients that start a server at the same moment start two `helyx serve`; the lock keeps one, and both clients attach to it. A second start then tries the lock again at each poll, so the short lock take of a client test (decision 1) does not end a start. With no launcher (`mix helyx`), slice 4 decides.
11. **Reconnect** (slice 4). The TUI records the `instance_id` and the `seq` of the last event that it applied. After a lost connection, it connects again and subscribes with `after`; the replay ring gives the events it missed, or a new tail snapshot replaces its state (wire-protocol.md, "Join, pages, and replay"). The rule of the TUI that it has no seq guard changes: the fold applies an event only once, by its `seq`.
12. **The in-node path goes** (slice 5). The TUI uses only the wire; `CodingAgent.run/1` keeps print mode.

## Slices

Each slice is one change of `/ship` size. A later slice is its own ticket, ready for an agent, blocked by the slice before it.

1. **The attach client** (#662). Decisions 1 to 6: `CodingAgent.Attach.connect/1` and `Helyx.TUI.Wire.connect/4`. Nothing calls them yet; `helyx` is not changed.
2. **The wire session of the TUI** (#806). Decision 7: the connection process with requests, replies, the subscription, the acks, the parts, and the pings; the events decoded to Core events. Nothing in the TUI uses it yet.
3. **`helyx` attaches** (#807). When a server runs for the data folder, `helyx` runs the TUI over the wire (decisions 8 and 9). With no server, it runs in the node as today.
4. **Auto-start and reconnect** (#808). Decisions 10 and 11.
5. **The in-node path goes** (#809). Decision 12.

## Interface changes

Slice 1:

- `CodingAgent.Attach.connect/1` (new): `connect(dir)` with the data folder. Returns `{:ok, socket}` with the socket after `welcome`, owned by the caller, `:none` when no server runs, or `{:error, text}` with the line without its `helyx: ` prefix.
- `Helyx.TUI.Wire.connect/4` (new, client code in `plugins/bundled/clients/tui`): `connect(ip, port, token, timeout)` with the token in a closure. Returns `{:ok, socket}` after `welcome`, passive and owned by the caller; `{:error, {:refused, server_protocol}}`; `{:error, :broken}` for a contract break; or `{:error, text}` for the failures of decision 3. It closes the socket on every error.
- `CodingAgent.Serve.read_file/1` and `CodingAgent.Serve.url/2` (new, `@doc false`): the read of the server file of decision 2 and the URL of a parsed address, which a second start used privately. `read_file/1` gives the token in a closure, or nil when the file holds no string token.
- `Helyx.Test.WireClient` gets a fake server for the tests of a client (`fake_server/1` and its steps).

Slice 2:

- `Helyx.TUI.Wire.Connection` (new): `open(socket)` with the socket of `connect/4`, owned by the caller, starts the connection process, which takes the socket; it returns `{:ok, conn, ref}` with the caller's monitor of it. The caller is the owner: the connection ends with it, and it gets `{:helyx_event, event}` for each event of its subscriptions and `{:helyx_end, sub, :stopped | :crashed}` at `session_end`, as a client in the node gets them from `Helyx.Session.subscribe/2`. The connection ends with `{:shutdown, :broken}` at a contract break and with `{:shutdown, {:closed, code}}` at a close of the server, `code` nil for a close with no code: a close of TCP, a close frame with no code, or a failed read or write.
- The operations: `subscribe(conn, session)` with `answers: true`, which gives `{:ok, snapshot | {:replay, events}, sub}`; `ack(conn, sub, event)` for each event that the owner applied, which sends an `ack` for each 1,024th `seq`, as `Helyx.Session.ack/2` does with an event; `start(conn, cwd: cwd)`, with `model:` as an optional key (a nil value is `bad_params`), and `resume(conn, id: id)` or `resume(conn, cwd: cwd)`, which give `{:ok, session_id}`; `list_saved(conn, opts)`, which gives `{:ok, [Scan.Summary.t()], next}` as `Helyx.Sessions.list_saved/2`; and `steer/3`, `follow_up/3`, `compact/3`, `abort/2`, `set_model/3`, and `answer/4`, which give `:ok`. An error of the wire is `{:error, code}` with the code as an atom; `invalid_model_ref`, `unknown_provider`, and `start_failed` give `{:error, {code, text}}`. A request over the frame bound goes as parts (`Helyx.Transport.WebSocket.Frame.encode/1`).
- An event is the `Helyx.Event` of Core: a message decodes with `Helyx.Session.File.Codec.decode/1`, a user message of origin `unknown` as the file holds it, with no origin. A message has the role that the fold takes for its event: a tool result for `tool_execution_end`, a user message for `queue_dropped` and `steer_unconfirmed`, and an assistant message for the partial of a turn. The arguments of a tool call get the integer cap of `Helyx.Message.cap_integers/1`, as in a message of the file. The two fields that the wire leaves out come back from the messages: `texts` of `queue_dropped` and `text` of `steer_unconfirmed` (`Helyx.Message.text/1`). An event of a type that the client does not know is dropped; a key that it does not know is ignored.
- `Helyx.TUI.Wire.check/4` and `Helyx.TUI.Wire.send_frame/3` become public with `@doc false`: the connection checks each frame header with the rule of the handshake, and sends its pongs and texts with the mask of the handshake.

## Replaced mechanism

None in slices 1 and 2. Slice 3 replaces the abort of the session at the quit of the TUI (`Helyx.TUI.terminate/2`, `CodingAgent.run_session/1`) for a TUI over the wire; slice 5 replaces the in-node TUI.

## Bounds

Slice 1:

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| mode of the data folder | no write for the group or other users (`mode &&& 0o022 == 0`) | `other users can write the data folder ...`, exit 1 | `CodingAgent.Attach` |
| wait for the answer of the lock | 5,000 ms (`Helyx.Session.Lock`) | `could not test the lock of the data folder: <text>`, exit 1 | `Helyx.Session.Lock` |
| read of the server file | a regular file, checked before the open (`read_up_to/2`, the accepted hole of serve.md), 4,096 bytes, a JSON object with `address` an IP address, `port` from 1 to 65535, and `token` a string | the file is not valid: the server is starting | `CodingAgent.Serve.read_file/1`, `CodingAgent.Attach` |
| the wait while the server is starting | an attempt every 100 ms; the deadline of 5,000 ms is checked after the sleep, so no attempt starts after it. An attempt that starts before it ends within its own bounds: the lock answer, 5,000 ms, the release of a free lock, 1,000 ms (`Lock.release_ms/0`), and the connect, 5,000 ms | `could not attach to the server of <dir> in 5000 ms: <reason>`, exit 1 | `CodingAgent.Attach` |
| one connect: TCP connect, upgrade, `challenge`, and `welcome` | 5,000 ms in all, from the TCP connect to `welcome`: the deadline is checked before each read, so bytes that wait in the socket, such as a stream of pings, do not keep a read past it; each send has the same timeout (`send_timeout`) | `no welcome from the server in 5000 ms`: the server is starting | `Helyx.TUI.Wire` |
| the HTTP head of the upgrade reply | lines of at most 8,192 bytes with the CRLF (`packet_size`), at most 64 header lines | the server is starting (decision 3) | `Helyx.TUI.Wire` |
| a server frame in the handshake | 1,048,576 bytes, the frame bound of the wire, with its fragments joined; the decode bounds of the transport (`Helyx.Transport.WebSocket.Frame`) | contract break | `Helyx.TUI.Wire` |
| `server_protocol` of `refused`, `protocol` of `welcome` | a JSON integer of 0 or more, within the decode bounds (at most 1,024 characters) | contract break | `Helyx.TUI.Wire` |
| `nonce` of `challenge` | the base64 of 32 bytes | contract break | `Helyx.TUI.Wire` |
| the address in a line | the address that `:inet.ntoa/1` gives for the parsed address, never the text of the file | n/a | `CodingAgent.Attach` |

Slice 2:

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| a server frame after `welcome` | the rules of the handshake (decision 6): 1,048,576 bytes with its WebSocket fragments joined, no mask, no reserved bit, a control frame whole and of at most 125 bytes; a frame of parts joined at most 26,214,400 bytes, its parts consecutive; the decode bounds of the transport | contract break: the connection ends with `{:shutdown, :broken}` | `Helyx.TUI.Wire.Reader`, `Helyx.Transport.WebSocket.Frame.decode/2` |
| the bytes read and not yet a frame | the header of a frame is checked before its payload is whole, so the buffer holds at most one frame of the bound and the bytes of one read | contract break | `Helyx.TUI.Wire.Reader` |
| a frame of the server | a `res` for an id that waits, an `event` or a `session_end` for a sub that a `subscribe` reply made, each of the schema of protocol 3 | contract break | `Helyx.TUI.Wire.Connection`, `Helyx.TUI.Wire.Decode` |
| a message | the message entry of the session file: at most 1,024 blocks, each text of a tool result cut to 64 KiB (`Codec.decode/1`, #673) | contract break | `Helyx.Session.File.Codec` |
| a value that the fold trusts | the bounds of Core: a token count of a compaction from 0 to 10^9 (`Helyx.Usage.wire_tokens?/1`), a model ref that `Helyx.ModelRef.parse/1` takes, a total cost of a snapshot of at most 10^12 USD, a tool result with its call id, and a snapshot that `Helyx.TUI.ViewModel.from_snapshot/2` takes | contract break | `Helyx.TUI.Wire.Decode` |
| the wait of an operation | the deadline of the server for it (wire-protocol.md, "Deadlines", `Ops.deadline/1`) and 5,000 ms for the wait of the server for its encoder slot and the encode of a large result, from the moment that the connection takes the request; a request also waits while the connection writes the frames of an earlier one, each WebSocket frame within the send timeout of the socket, 5,000 ms (`connect/4`) | `{:error, :timeout}`: the outcome is unknown; the late reply is checked as any reply and dropped, and a subscription that it made ends with `unsubscribe` | `Helyx.TUI.Wire.Connection` |
| requests that wait for a reply | 16, late ones too, as the requests in flight of a connection of the server | `{:error, :busy}`, and nothing is sent | `Helyx.TUI.Wire.Connection` |
| events that the owner did not apply | the credits of the server, 16,384 unacked events: the owner acks an event after it applied it, so an event that waits in the mailbox of the owner is not acked | the server closes with `4408`: `{:shutdown, {:closed, 4408}}` | the server; `Helyx.TUI.Wire.Connection.ack/3` |

## Ownership

Slice 1:

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the port of the lock test, and its `flock` when free | `Helyx.Session.Lock.take/1` in a Task of `CodingAgent.Attach` | the Task, a design flag of the template: it holds the port only for the take and the release, the caller waits for it, so a caller has one at a time, and it ends within the bounds of the take (5,000 ms) and the release (1,000 ms) | `Lock.release/1` when the take got the lock; the end of the Task closes the port in every case | the port closes with the Task; perl exits at the end of its stdin, and the kernel frees the lock. A `helyx serve` that tries the lock while a client holds it for its test exits 1: open, ticket #808 | n/a |
| the read of `server.json` | `Helyx.Session.File.Scan.read_up_to/2` in the caller | the caller | closed by the read | closed with the caller | a FIFO put in place between the type check and the open blocks the open: open, ticket #777 |
| the socket | `Helyx.TUI.Wire.connect/4` in the caller | the caller | returned after `welcome`; closed by `connect/4` on every error | the socket closes with its owner | n/a |
| `server.json` | `helyx serve` | the disk | the client never writes or removes it | n/a | n/a |
| `server.lock` | perl, at the first take of the lock, by a server or a client | the disk | stays, as for a server | stays | n/a |

Slice 2:

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the socket | `Helyx.TUI.Wire.connect/4` in the owner | the connection process, from `open/1` | the end of the connection: the end of the owner (the connection monitors it), a contract break, a close of the server | the socket closes with the connection process | n/a |
| the connection process | `open/1`, one for each call; the owner calls it once for each socket | the owner, by its monitor, and no supervisor: the connection monitors the owner and ends with it, as a Task ends with its caller | the end of the owner | the owner gets `:DOWN`; a waiting operation gets `{:error, :closed}` | n/a |
| the deadline timer of a request | `Helyx.TUI.Wire.Connection` | the connection process | cancelled at the reply | ends with the process | n/a |
| a subscription of the server | the `subscribe` reply | the connection, for the owner | `session_end`; `unsubscribe` of a late one | the server ends it with the connection | n/a |

## Accepted holes

- The lock test of a client holds the lock for the few milliseconds of a take and a release. A `helyx serve` that starts in that window waits for a server file and exits 1 after 5,000 ms. Slice 4 (#808) makes a second start try the lock again at each poll (decision 10).
- The read of the server file checks the type of the path, then opens it, as a second start does: a FIFO put in place between the two blocks the open. Only the owner of the data folder can make it. Open, ticket #777.
- Slice 2: the bounds of the client are the bounds of an inbound frame of the server (#806), and a real server can send more: a tail snapshot or an event of more than 65,536 values (200 messages of many blocks or large tool arguments), a `queue_dropped` of 64 texts of 4 MiB, or a snapshot whose JSON passes 26,214,400 bytes (a text of control characters is six bytes for each byte in JSON). The connection ends as at a contract break. Open: no ticket yet, the report of #806 asks the orchestrator for one.
- Slice 2: the client checks each frame against the frame bounds and the schema, not the counts that the server keeps: a page of 256 items, a replay of 1,024 events, a `queue_dropped` of 64 messages, an `ask` request of 65,536 bytes. A frame that breaks them reaches the owner within the frame bounds. A tail snapshot has no count bound of its own: the newest group alone can pass `tail`.
- Slice 2: the decode checks each event alone, and a snapshot with the fold. An event that the fold cannot apply to its state, such as the result of a call that is not open, crashes the fold, as a bug of Core does (`Helyx.TUI.ViewModel.apply/2`).
- Slice 2: the cap of the total cost of a snapshot, 10^12 USD, is the bound of one usage, not of a sum: a session whose cost passes 10^12 USD gets a snapshot that the client refuses. Open defect of the last review round of #806.
- Slice 2: an `ask` of the `question` tool whose request the tool did not make crashes `Helyx.TUI.Question`, as in the node: the tool checks its own request (`docs/features/question-tool.md`), and the client checks only that the request is a JSON object.
- Slice 2: a block of a kind that protocol 3 does not have ends the connection, as `Codec.decode/1` refuses it; the tolerant reader of wire-protocol.md shows a placeholder for it, and a server of protocol 3 sends none.
- Slice 2: a server that reads each WebSocket frame of a large request just within the send timeout makes the write of the request, and the wait of every operation behind it, up to 5,000 ms for each frame: 34 frames for a request of 25 MiB.
- Slice 2: the client does not check the `seq` order of the events of a subscription (O4): the fold has no `seq` guard until slice 4 (decision 11). An event of a type that the client does not know is dropped and not acked; a server of protocol 3 sends none.

## Out of scope

- Other clients.
- A server on another machine: the client reads the server file of a local data folder. An SSH tunnel or a TLS proxy serves other clients (serve.md, decision 6).
