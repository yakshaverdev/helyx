# Remote hands

Ticket #927, part of #925. ADR 0012 decides remote hands (#856, #886). This doc gives what the ADR leaves to it: the terms of the hands protocol, their codec on the wire, the term limits, the durations on the protocol, the lease setting, the pairing design, the bounds, the ownership table, and the slices of the build. Owner decisions of 2026-11-11 close every question that the ADR leaves open; "Decisions" states them.

## Goal

A Helyx server runs on a Linux VPS. On a Mac, the owner runs `helyx hands --pair <link>` in the project folder and the Mac becomes the runner `mac`. A session that names the runner runs its tool calls and its provider process on the Mac (ADR 0012, user story). The capability report of the runner gives the session its tools, so a Mac runner can later report a build tool (#929) that a Linux runner does not.

The session speaks one protocol to local and to remote hands (ADR 0012 §1). So the build first moves the local hands, `Helyx.Session.Hands`, onto the terms of this doc, with no wire, and only then adds the stand-in of a remote hands and the wire. The local hands keep their tests; each slice keeps the suite green.

## The terms

Every term is a JSON object with a string `t`, the kind of the term, and the instance id `instance` of the session (ADR 0012 §3, fencing), plus the fields below. A provider process, a call, a read, and a request from a tool are named by ids that the session or the runner makes, strings of 1 to 64 bytes. No pid, reference, function, or module name crosses (ADR 0012 §2). A reason is the text of `Helyx.Reason.text/1` (`lib/helyx/data/reason.ex`), made on the side that has the term.

The inventory below lists every message between the session and its hands in the code, and its term. The direction is S→H (session to hands) or H→S.

| Today (message, file) | Term | Notes |
| --- | --- | --- |
| tool set built by the caller: `Helyx.Session.Input.tools/2` (`lib/helyx/session/input.ex`) with `Helyx.Tool.specs/2` and `check_available/1` | S→H `hands.open {session, instance, only, provider_opts}`; H→S answer `{specs, concurrent, providers, hooks, folder}` or `{error}` | the capability report (ADR 0012 §2); `only` is the `:tools` option of the session; `providers` are the registration ids of the provider plugins of the hands' Core; `hooks` are the registration ids of the hooks that the hands run (decision 1). The server checks the report with the rules of `Helyx.Tool.specs/2` and unique names |
| `Hands.run/4`: `{:run, turn_id, call, context}` cast | S→H `hands.call {turn, call: {id, name, arguments}, context}` | `context` is the map of `Helyx.Tool.context/0` without `core`; the hands add theirs |
| `Outcome.of/3`: `{:tool_result, turn_id, call_id, {status, text}}` or with UI blocks | H→S `hands.result {turn, call, status, text, ui_blocks?}` | the server cuts `text` again with `Helyx.Message.cut_result/1` and checks each UI block with `Helyx.UIBlock.check/1` (ADR 0012 §5) |
| `{:started, {status, text}, pid}` result of a background run (`hands.ex`, the `:started` call) | H→S `hands.result {..., started: true}` | the session moves the asker record of the call Task by its pid (`Asks.started/3`, `lib/helyx/session/server.ex`, the `:started` clause); the term carries the `task` id in place of the pid |
| `{:background_end, message}` (`Outcome.of/4`) | H→S `hands.background_end {id, message}` | the message as the session file codec encodes it |
| `Hands.taken/2` | S→H `hands.taken {id}` | |
| `{:asker, turn_id, pid, asker}` and the go `:helyx_go` (`Helyx.Session.Ask.await_go/0`) | H→S `hands.asker {turn, task, asker}`; S→H `hands.go {task}` | `task` is an id the hands make for each Task; the order guarantee (the session handled the record before the Task asks) holds because the stand-in passes both in the order of the connection |
| `Helyx.Tool.ask/1`, `Helyx.Hook.ask/1` (`GenServer.call` to the session) | H→S request `hands.ask {task, request}`; S→H answer `{answer}` or `{error}` | the bounds of `Helyx.Session.Ask` hold: `request` at most 65,536 bytes of JSON |
| `Helyx.Tool.show/2`: `{:ui_block, call_id, key, block}`, a `GenServer.call` to the session by its Core and id (`lib/helyx/interfaces/tool.ex:217`, handled by `Server.Calls.handle/3`) | H→S request `hands.show {task, call, key, block}`; S→H answer `ok`, `too_many`, `not_running`, or `too_many_blocks` | the server checks the block with `Helyx.UIBlock.check/1` again; on the runner the session's Core and id do not resolve, so the call goes through the hands |
| the `:DOWN` of each Task with an asker record: the session monitors the pid of `{:asker, ...}` (`Server.Asks`, `lib/helyx/session/server/asks.ex:31`) and `Asks.down/3` drops the asker and ends its open asks | H→S `hands.task_down {task}` | the hands send it when a Task that they sent an `asker` for dies, before its release and apart from its later result or hook answer, as the `:DOWN` reaches the session today while the hands still release; so the hands must send it while other releases wait in their queue. On remote hands the session has no pid to monitor |
| `Helyx.Tool.transcript/0` | H→S request `hands.transcript {task}`; S→H answer `{messages}` | the messages as the session file codec encodes them; over the term limit the call fails with an error, the turn goes on |
| `Hands.start_provider/3` with the closure of `ProviderProcess.run/1` | S→H `hands.provider_start {provider, id, model, tools, session, resume_id, resume_usage}`; H→S `hands.provider_start {id, ok}` or `{id, error}` | `provider` is the registration id; the hands resolve it on their Core; an id the hands did not report fails as `{:unknown_provider, id}` on the server before the term goes |
| `:start` from the session to the provider process (`Server.TurnLoop.handle/2`, `lib/helyx/session/server/turn_loop.ex:143`; `Server.Summary.started/2`, `summary.ex:55`), sent after the session recorded the pid of the start answer | S→H `hands.provider_go {id}` | the gate stays: the provider process waits for it before `init/3`, so `provider_ready` and every event come after the session recorded the id. On one connection the order is the order of the terms, but the gate also keeps the summary abort: a summary call that ended before the start answer sends `hands.provider_stop {id, aborted}` in place of the go, as it sends an exit today |
| `{:provider_ready, pid}` (`ProviderProcess`) | H→S `hands.provider_ready {id}` | |
| the `:DOWN` of the provider process: the session monitors its pid at the start answer (`turn_loop.ex:143`) and takes the death before the release ends (`monitor_down/1`: a dying process in a prepare, an idle session that waits for the release) | H→S `hands.provider_exit {id}` | the hands send it when the process ends, before its release; `hands.provider_down` follows after the release, as `{:provider_down, ...}` follows the `:DOWN` today. On one connection the two keep that order. The provider Task has no asker record, so `hands.task_down` does not cover it |
| `ProviderRequest.ask/3`: `{:provider_request, from, tref, request}` with the kill armed on the session's node | S→H `hands.provider_request {id, from, request, ms}` | `from` is an id the session makes. The kill of the request is armed by the hands on their clock with the duration that the session sends, `ms` (ADR 0012 §3, "the runner owns its bounds") |
| `{:provider_reply, from, kind, value}` | H→S `hands.provider_reply {id, from, kind, value}` | an error value as text |
| the actions of the provider process that it sends with `Helyx.Session.Stream.send_checked/3` (`ProviderProcess.action/2`, `lib/helyx/session/provider_process.ex`): `{:stream_event, turn_id, event}`, `{:stream_end, turn_id, terminal}`, `{:tool_request, pid, turn_id, call, bytes, rejection}`, `{:approval, pid, turn_id, approval_id, call_id}`, and `{:resume_id, pid, turn_id, id, cut}` | H→S `hands.provider_event {id, turn, event}` with one `event` shape for each: an event, a terminal, a tool request, an approval, a resume id; the pid becomes the provider `id` | the server checks each again as the provider process does: `Helyx.Session.Stream.check/1` for an event, a tool request, an approval, and a resume id, and the terminal check of `check/1` for a terminal; the mailbox bound of `send_checked/3` holds on the server (ADR 0012 §5) |
| `{:need_context, turn_id}` and `{:need_context, turn_id, :overflow}`, the context requests of the provider process (`ProviderProcess.action/2`; `Server.TurnLoop.handle/2`, `turn_loop.ex:73-83`, and the summary call, `lib/helyx/session/server.ex`) | H→S `hands.need_context {id, turn, overflow}` | not an event: `Stream.check/1` does not take it, so the server checks it with its own shape (a turn id string, `overflow` a boolean) and dispatches it as the session does today, by the turn id |
| `TurnLoop.stop_provider/2`, an exit signal to the pid | S→H `hands.provider_stop {id, reason}` | the hands stop the process on their node |
| `{:provider_down, pid, reason}` (`Outcome.of/4`) | H→S `hands.provider_down {id, reason}` | `reason` is the kind of the down (`provider_timeout`, `task_exit`, an error) with its text |
| `Hands.request_cancel/2` | S→H `hands.cancel {turn}`; answer `{ok}` or `{error, unconfirmed}` | |
| `Hands.request_revoke/2` | S→H `hands.revoke {turn}`; answer `{ids, error}` | |
| `Hands.stop/3` with a monotonic deadline | S→H `hands.stop {release_ms}`; answer `{unconfirmed}`, a list of texts | a duration, never an instant (ADR 0012 §3) |
| `Settle.request/5`: `{:settle, ref, turn_id, input, context}`; answer `{:settle_answer, ref, :settle \| {:continue, module, text}}` | S→H `hands.settle {ref, turn, input, context}`; H→S `hands.settle_answer {ref, answer}` | the module of a `continue` crosses as the hook's registration id; the hooks run on the runner (decision 1) |
| `Approval.request/5`: `{:approve, turn_id, call, context, provider}`; answer `{:approval_result, ...}` | S→H `hands.approve {turn, call, context, provider}`; H→S `hands.approval_result {turn, call, decision}` | the runner sends the ask to the server as `hands.ask`, the server sends it to the clients of the user, and the answer goes back (decision 1) |
| `{:hook_answer, turn_id, record}` (`Hands.Hooks`) | H→S `hands.hook_answer {turn, record}` | the hooks run on the runner (decision 1) |
| `Sources.start/3`, `Sources.tools/2`, `{:source, pid, plugin}`, `{:source_down, pid}`, and the source calls of `Helyx.Tool` (`announce/1`, `put_tools/2`, `notice/1`, `deferred/2`, `activate/1`) | none | a runner reports no tool source in the first build, and `deferred/2` and `activate/1` answer as on a session with no source (decision 2) |
| the read of the folder by `Helyx.ModelContext.Default` (`plugins/bundled/lib/helyx/model_context/default.ex`) and `Helyx.Skills.scan/2` (`plugins/bundled/lib/helyx/skills.ex`) on the server's filesystem | S→H request `hands.read {read, paths, max_bytes}`; answer `{files}` | see "The read of the folder" |
| the liveness of a remote hands (new) | S→H `hands.live {seq, ack}`; answer `{seq}` | ADR 0012 §3 |

An answer is the `res` of the request on the wire, and a term with no answer is an `event`. The terms of one session go in the order of the session's sends, on one connection, so the order that the code has today on one node (for example: the end of a closed provider process reaches the hands before its `:DOWN` reaches the session, `lib/helyx/session/server/stop.ex`) holds as long as each side passes the terms of one session in the order it got them. The request queue of the runner (ADR 0012 §3) gives each term to the hands of its session in order; the stand-in passes each term to its session in order.

## Codec on the wire

The wire of ADR 0008 (`docs/features/wire-protocol.md`), protocol 13:

- `hello` gets five fields: `role`, `"client"` (the default) or `"hands"`; `runner`, a `name`, required with the role `hands`; `client`, a `name`, required with the role `client`; `pair`, the pairing handshake of "Pairing and the public listener"; and `signature`, the handshake of a paired peer. A `hello` carries `pair` or `signature`, never both. A client is not a runner, so the name of a client is in `client`, never in `runner`.
- A runner registers with one `req` `hands.register {runner, folder}`; the result is `{lease_ms}`.
- On a hands connection every S→H term is a `req` frame (ADR 0012 §5), and the runner answers each with a `res`. A term that has no answer today (`hands.call`, `hands.taken`, `hands.go`, `hands.provider_go`, `hands.provider_request`, `hands.provider_stop`, `hands.settle`, `hands.approve`) gets the `res` `{}` when the runner's request queue gave it to the hands; the stand-in does not wait for it and arms no deadline on it (ADR 0012 §3). The runner sends `event` frames for the H→S terms and `req` frames for the requests of a tool (`hands.ask`, `hands.show`, `hands.transcript`). The request ids of the two directions are separate spaces.
- A term is the `params` of a `req`, the `result` of a `res`, or the `data` of an `event`, as the wire has them. Strings are UTF-8; a text that is not valid UTF-8 cannot be a term, so the sender turns it into text as the source of the text does today (a tool result through `Helyx.Message.cut_result/1`, a reason through `Helyx.Reason.text/1`).
- A frame over 1,048,576 bytes goes as parts, as on the wire.
- `start` gets the parameter `hands`, a runner name, and the session file records it. A resume reads it from the file. A session on a runner has exactly the folder of its runner: another `cwd` gets `bad_params` (decision 5).

## Pairing and the public listener

User story: on the server machine the owner runs `helyx pair --runner mac` and gets one link. On the Mac the owner runs `helyx hands --pair <link>` in the project folder. From then on the Mac is the runner `mac`. After a restart of either side it connects again alone, with no secret copied by hand. A phone or desktop client pairs with the same link, of the kind `client`, and from then on it is connected as the owner: it sees the sessions of the owner, starts sessions, follows them, and answers their asks, as a local client with the server token does. After a restart of either side it connects again alone. So the link has a kind.

### Public listener

`helyx serve --public <host>:<port>` starts a second listener of the same wire with TLS on every interface at `<port>`. The host is a DNS name or an IP address, and `<host>:<port>` is the address that a link carries. The port is 1 to 65535: the argument check refuses 0, because a link needs the port that the peer dials. The loopback listener and `server.json` stay as they are for local clients. This revises "There is no second listener" of ADR 0012 §5: that sentence meant no listener with another protocol, and both listeners speak the one wire.

The listener binds every interface of both families with one dual-stack socket when the host has IPv6, and every IPv4 interface otherwise. A link whose host is an IPv6 literal stays dialable then. The public listener speaks TLS 1.3 only; both ends are Helyx. It accepts no server token: a `hello` there must prove a pairing link or a paired key. Reason: the server token permits everything, so it must not be useful from the network. A `hello` on the public listener whose proof is the proof of the server token closes with `4401`.

Each listener has its own connection gate of `Helyx.Transport.WebSocket.max_connections/0`, so a public connection never takes a place of the loopback listener, in any state, and the total of a server is two gates. Each listener also admits at most `Helyx.Transport.WebSocket.tcp_connections/0` TCP connections before the upgrade, and `Helyx.Transport.WebSocket.TLS.handshake_ms/0` bounds the TLS handshake, so a connection that sends no ClientHello does not hold a place. The HTTP request of an upgrade is bounded by the same `handshake_ms/0` in all, from two waits of `Helyx.Transport.WebSocket.TLS.request_ms/0`. The upgraded WebSocket of the public listener keeps no read timeout of the listener: its idle rule is the ping and the lease, and a registered runner that is silent past the request bound stays open until its lease. The public listener serves no webhook: a path under `/hooks` answers 404 before any other work.

The server checks every field of a public `hello` for type and size before it reads any: the role `hands` with a `runner` that is a name, or the role `client` with a `client` that is a name, and one handshake whose parts are strings of the right size. A `hello` of another role, a `hands` without a runner name, a `client` without a client name, a handshake of the wrong type, and a `hello` with both handshakes close that connection with `4401`, and the transport keeps serving its other connections.

Without `--public` the server has one listener, and a pairing operation answers `no_public_listener`.

### Certificate

At the first start with `--public`, the server makes an ECDSA P-256 key and a self-signed certificate with `:public_key` (no new dependency) and writes `<data folder>/tls/key.pem` and `<data folder>/tls/cert.pem`. The folder has mode 0700, and the key file has mode 0600 before the first byte of the key is written. `Helyx.Transport.WebSocket.TLS.ensure/1` makes or reads them. Later starts read them, so the pin does not change at a restart, and a loose mode of an existing key file is corrected to 0600.

Only a missing pair makes a new key. A key or certificate file that exists and cannot be read as its part, a certificate that does not belong to the key, and a pair with one file missing are an error that refuses the start with one line that names the file. A damaged key then never changes the pin without a message.

The pin is the base64url, without padding, of the SHA-256 of the DER of the SubjectPublicKeyInfo of the certificate (`Helyx.Transport.WebSocket.TLS.pin/1`). A peer accepts only a certificate with that pin and checks nothing else of it: no name, no dates, no chain (`Helyx.Transport.WebSocket.TLS.verify/2`).

### Peers

A paired peer is a row in the Hub store: the table `peers` with `name` (1 to `Helyx.Transport.WebSocket.Pairing.name_bytes/0` bytes of a-z, 0-9 and `_`), `kind`, `public_key` (32 bytes, Ed25519), and `created_at`. The primary key is `(kind, name)`, so a client and a runner can have the same name. This is a store schema version step with an upgrade, as `Helyx.Hub.Store.SQLite.Schema` does it. At most `Helyx.Hub.max_peers/0` rows, the runners and clients of one server together; a pairing over it fails.

Both kinds pair: `hands` pairs a runner, and `client` pairs a client app. A paired client acts as the default owner of the Hub (`docs/features/hub.md`, decision 3), so its operations are the client operations of that user. A link for another Hub user is not built.

The server stores no secret of a peer: a copy of the store does not let its holder connect as the peer. This is why the peer has a key pair and not a stored shared secret: the HMAC key of a stored secret would be enough to forge a proof.

### The link

A link is `helyx-pair:1:<base64url of the JSON {"a": "<host>:<port>", "t": "<bootstrap token>", "p": "<pin>", "k": "hands" | "client", "n": "<name>"}>`.

The bootstrap token is the base64url of 32 random bytes. The server keeps only its SHA-256, in memory, inside a closure, so no `inspect` or crash report of the pairing process holds it. A link is valid for `Helyx.Transport.WebSocket.Pairing.link_ms/0`: long enough for the owner to carry it to the other machine, and short enough that an unused one dies. It is valid for one successful pairing. At most `Helyx.Transport.WebSocket.Pairing.max_links/0` pending links, so the state of the process stays bounded; a create over it fails with `too_many_links`. A stop of the server ends every pending link.

### Make a link

A new client operation `pair.create {kind, name}` with the result `{link, expires_ms}`, served only on the loopback listener, on a connection that proved the server token. The kind is `hands` or `client`, and the name follows the one name rule; any other kind, and a kind or name that is not a string, answers `bad_params`. A Hub user token gets `forbidden`: pairing is the operator's action. On the public listener it is `unknown_op`. `pair.revoke` checks its kind and name the same way before it reaches the pairing process.

Without `--public` it fails with `no_public_listener`. `helyx pair --runner <name>` and `helyx pair --client <name>` connect as a second start of `helyx serve` does (`CodingAgent.Attach.connect/1`), call the operation with the kind of the switch, and print the link and one line that says how long it is valid. Exactly one of the two switches is given.

A name that is already paired is paired again: the new key replaces the old one at the pairing, and the old connection closes.

### The pairing handshake

The `challenge` gives a nonce, as today. A `hello` of a pairing with a runner has `role` `hands`, `runner` (the name), and `pair: {proof, public_key, signature}`; one with a client has `role` `client`, `client` (the name), and the same `pair`:

- `proof` is the HMAC of the nonce with the SHA-256 of the bootstrap token, as the wire computes a proof today (`docs/features/wire-protocol.md`, rule O1).
- `public_key` is the Ed25519 public key that the peer made.
- `signature` is the Ed25519 signature of the signature text below with the private key. The server checks the link's kind and name, the proof, the signature, and that the role belongs to the link's kind and its name is the link's name. A wrong proof or signature, an expired or used link, another kind or name, and a role that does not belong to the link's kind close with `4401` and do not consume the link.

### The handshake of a paired peer

A `hello` with `role` `hands` and `runner`, or `role` `client` and `client`, and `signature` (the Ed25519 signature of the signature text). The server reads the public key of `(kind, name)` and verifies. No row, or a wrong signature: `4401`. A paired client acts as the default owner of the Hub: it gets the credential of that user, and its operations are the client operations of that user. It gets no operator operation: `pair.create`, `pair.revoke`, and `pair.list` stay `unknown_op` on the public listener, and everything that the loopback listener keeps for a connection that proved the server token stays refused.

**The signature text.** Both handshakes sign the same bytes, and part 2's runner builds them the same way: the context text `helyx-handshake-v1`, the 32 bytes of the nonce, the pin of the server, the kind, and the name, in that order, each part preceded by its length as a 32-bit big-endian integer (`Helyx.Transport.WebSocket.Pairing.signature_text/4`). A signature made for one server, one kind, or one name is of no use at another.

**A Hub that does not answer.** A Hub that is busy or gives no answer to a pairing closes the connection with `4503`, as the authority of the loopback listener does; the peer connects again later. A missing or wrong row is permanent and closes with `4401`. The caller waits `Helyx.Transport.WebSocket.Pairing.call_ms/0` for this process, which is `Helyx.Hub.call_ms/0` plus a margin, so the `4503` answer arrives before the caller's own wait ends.

**A caller that dies.** The pairing checks that the caller of a `hello` is alive after the Hub write and before it consumes the link. A caller that died during the write leaves the link pending, and the peer tries again. A connection that dies after the registration is cleaned up by the monitor that `Helyx.Transport.WebSocket.Pairing` sets at the registration inside its `hello` call.

### Revoke

`Helyx.Transport.WebSocket.Pairing.revoke/3` is the one path: it deletes the row of its kind and name and closes the connection of that peer, so its sessions stop as at a lost hands (ADR 0012 §4). It closes the connection of a paired client too, at once. The client operation `pair.revoke {kind, name}` on the loopback listener calls it, and so does the operator. The row may be gone already; the close still runs, and the operation answers `{}`. `pair.list` gives `{peers: [{kind, name, created_at, connected}]}`. A peer has at most one connection: a second connection with the same kind and name closes the first.

### With no Hub

Pairing does not exist without a Hub in the Core: `--public` fails the start with one line, and the transport with a public listener and no pairing gives `{:error, :pairing_required}`. A transport with a pairing process and no authority, or with an authority that has no `paired/4`, refuses `pair.create` with the kind `client` with `bad_params`: the paired handshake has no credential to ask for, so a link of that kind would never work. The kind `hands` is not affected.

### The runner state

This state is built in part 2; the design is here. `~/.helyx/hands/<name>.json`, mode 0600, holds the address, the pin, the name, the folder, and the private key. `helyx hands --pair <link>` writes it and connects. `helyx hands --name <name>` connects with a saved state. The reconnect waits 1,000 ms, then doubles to at most 60,000 ms, with no end: a runner is a service. A `4401` ends the runner with one line, because a retry cannot pass.

### Registration and lease

After `welcome`, the runner sends `hands.register {runner, folder}` and gets `{lease_ms}`. The folder is at most `Helyx.Transport.WebSocket.Pairing.max_folder_bytes/0` bytes. One connection holds one registration: a second `hands.register` on the same connection answers `bad_params`, so each connection has one lease timer chain.

The server sends a `hands.live` request every third of the lease. Its id carries the sequence of the request, and the request stays open until its answer. A `res` renews the lease only for the id of the open request, and each request is answered at most once: an answer with no open request, or a second answer, changes nothing. The lease closes a connection whose runner answers no open `hands.live` within the lease duration, with `4408`.

## The read of the folder

`Helyx.Session.read_files(paths, max_bytes)` (a name for the build; a function of Core that a plugin calls from the process where the session runs its model context) reads the regular files of `paths` on the hands, each at most `max_bytes`, and gives `{path, {:ok, binary} | {:error, :enoent | :too_large | :not_regular | :eacces}}`. On local hands it reads on the same node. `Helyx.ModelContext.Default` and `Helyx.Skills.scan/2` use it for local hands too (ADR 0012 §2). The bounds: at most 256 paths in one read, each at most 4,096 bytes of path; `max_bytes` at most the limit that each reader has today; and the answer within the term limit.

The skills scan lists folders (`Helyx.Skills`, the scan of `.agents/skills` from the root up to the folder). So the read also needs a list of a folder: `hands.read` takes `{list, paths}` for that. A folder can hold any number of entries, so the list has a bound of its own, which the read slice states from the bounds of `Helyx.Skills` (200 skills, `@max_skills`, `plugins/bundled/lib/helyx/skills.ex`); until then it is unbounded in the design of that slice.

## Term limits

ADR 0012 §5: one term on a hands connection has a limit in joined bytes, in decoded values, and in integer size; the sender checks it and fails the one operation, the receiver enforces it and closes the connection.

- **Runner to server**: the inbound decode bounds of the wire, 26,214,400 bytes and 65,536 values, with integers of 1,024 characters (`Helyx.Transport.WebSocket.Frame.max_request/0`, `test/fixtures/wire/bounds.json`).
- **Server to runner**: 67,108,864 bytes and 1,048,576 values, with integers of 1,024 characters. The bound is the outbound queue bound of a connection, so one term fits in the queue. The slice measures the peak heap of a decode on the runner.

## Durations on the protocol

Every bound that crosses is a duration in milliseconds (ADR 0012 §3):

| Term | Duration | Source |
| --- | --- | --- |
| `hands.stop` | `release_ms`, 20,000 | `Helyx.Session.Hands.State.release_ms/0` |
| `hands.provider_request` | `ms`, the kill of the request | `docs/features/session-lifecycle.md`, "Deadlines" |
| `hands.register` answer | `lease_ms` | the lease setting |

The runner arms them on its own clock. The server arms no deadline on one answer of the runner; it has only the lease and the shared stop deadline.

## The lease setting

A transport option `:hands_lease_ms` of `Helyx.Transport.WebSocket`, an integer from 30,000 to 120,000, default `Helyx.Transport.WebSocket.hands_lease_ms/0`; another value fails the start of the transport (ADR 0012 §3). The connection process sends `hands.live` every `div(lease_ms, 3)` ms, one request at a time.

## Interface changes

- `Helyx.Session.start/2` and `resume/2`: the option `:hands`, a runner name; the session file records it. The tool set comes from the capability report of the hands, local and remote. The `:provider_opts` of a session with `:hands` are a keyword list whose values encode as JSON, else the start fails before the session starts.
- A public entry point through which a connection hands Core a remote hands (ADR 0012 §1). Name and shape in the entry-point slice.
- `Helyx.Transport.WebSocket`: the roles `hands` and `client`, `hands.*`, the option `:hands_lease_ms`, the option `:public` for the second listener, and the pairing operations of "Pairing and the public listener". Protocol 13.
- `Helyx.Transport.WebSocket.Authority`: the optional callback `paired/4`, the credential of a paired client, which the Hub answers with the default owner.
- `Helyx.Transport.WebSocket.TLS` (new): `ensure/1` and `pin/1` and `verify/2` of the certificate.
- `Helyx.Transport.WebSocket.Pairing` (new): the links, the peer connections, the two handshakes, and the hands registrations.
- `Helyx.Hub`: `put_peer/4`, `peer/3`, `peers/1`, `max_peers/0`, and the internal `revoke_peer/3` that deletes a row. `Helyx.Transport.WebSocket.Pairing.revoke/3` is the one revoke path, and it closes the connection.
- `Helyx.Hub.Store`: `put_peer/4`, `peer/3`, `delete_peer/4`, and `peers/1`, with the schema version of "Store schema".
- `Helyx.Session.read_files/2` for the readers of the folder.
- `CodingAgent.CLI`: `helyx serve --public <host>:<port>`, `helyx pair --runner <name>`, and `helyx pair --client <name>`.
- `CodingAgent.CLI`: `helyx hands --pair <link>` and `helyx hands --name <name>` in part 2.

## Replaced mechanism

The local mechanism and its replacement are the inventory of "The terms". In addition:

1. **The tool set on the caller's node** (`Helyx.Session.Input.tools/2`): replaced by the capability report, for local hands too. This reverts the update of 2026-10-12 of ADR 0003.
2. **The closure of the provider start** (`Hands.start_provider/3`, `ProviderProcess.run/1`): replaced by the data of `hands.provider_start`; the hands build the args with their Core and the folder.
3. **The armed kill of a provider request on the session's node** (`ProviderRequest.ask/3`, `:timer.kill_after(ms, pid)`): the hands arm it. The guarantee that a blocked loop is killed at the bound holds, by the hands' timer.
4. **Pids in the answers** (`{:provider_start, ref, {:ok, pid}}`, `{:provider_down, pid, _}`, `{:provider_ready, pid}`): ids. The session matches on the id where it matches on the pid today (`lib/helyx/session/server.ex`, the `:provider_ready` and `:provider_down` clauses).
5. **The monotonic deadline of `Hands.stop/3`**: a duration.
6. **The background folder delete in `Stop.run/1`**: the hands delete it at their stop (ADR 0012, Consequences).
7. **The wait for the end of a closed provider process in `Stop.run/1`**, which has no `after`: on remote hands, one shared deadline of `@hands_stop_ms` (ADR 0012 §3).
8. **The server token on every listener**: the public listener accepts no server token, and a hands role takes a pairing link or a paired key (ADR 0012 §5a, revision of 2026-11-12).
9. **A hands credential minted by a product in memory**: for the owner's own runner the link writes a peer key in the Hub store. A product that starts a container runner mints a hands credential through the public API of the server, as ADR 0012 §5a says; that path is out of scope of this build.

Each slice lists the tests of the old mechanism that it touches, with the property each keeps.

## Bounds

| What | Bound | Over the bound | Where |
| --- | --- | --- | --- |
| hands per session instance | 1 | a term of another instance: refused by the hands, dropped by the session | both |
| connections per peer name | 1 | a new connection of the same kind and name closes the old connection | server |
| a frame | `Helyx.Transport.WebSocket.Frame.max_frame/0`, with parts | close `1009` | transport |
| a term, runner to server | `Helyx.Transport.WebSocket.Frame.max_request/0`, the values and integers of the request decode bounds | the receiver closes the connection; the sender fails the one operation | sender and receiver |
| a term, server to runner | as "Term limits" | the receiver closes the connection; the sender fails the one operation | sender and receiver |
| a link | `Helyx.Transport.WebSocket.Pairing.link_ms/0`, one successful pairing | the pairing closes with `4401` | server |
| pending links | `Helyx.Transport.WebSocket.Pairing.max_links/0` (16) | `pair.create` fails with `too_many_links` | server |
| peers | `Helyx.Hub.max_peers/0` | the pairing closes with `4401`, and the link stays unused | server |
| a peer name | 1 to `Helyx.Transport.WebSocket.Pairing.name_bytes/0` bytes of a-z, 0-9, and `_` | `bad_params` for `pair.create`; `4401` for a `hello` | `Helyx.Transport.WebSocket.Pairing` |
| a public `hello` | the role `hands` with a `runner` name, or the role `client` with a `client` name, and one handshake of parts of 32 or 64 decoded bytes | `4401` | `Helyx.Transport.WebSocket.Pairing` |
| the TLS key and certificate | ECDSA P-256; the folder has mode 0700, the key 0600 before its first byte | the start refuses with one line that names the file | `Helyx.Transport.WebSocket.TLS` |
| the TLS handshake | `Helyx.Transport.WebSocket.TLS.handshake_ms/0` | the connection closes | `Helyx.Transport.WebSocket.TLS.Transport` |
| the HTTP request of an upgrade | `Helyx.Transport.WebSocket.TLS.handshake_ms/0`, from two waits of `Helyx.Transport.WebSocket.TLS.request_ms/0` | the server answers 408 and closes | `Helyx.Transport.WebSocket.TLS.Transport` |
| the wait for a pairing answer | `Helyx.Transport.WebSocket.Pairing.call_ms/0`, the Hub wait plus a margin | the caller times out; the answer is `4503` when the Hub waited to its own bound | `Helyx.Transport.WebSocket.Pairing` |
| the lease setting | `Helyx.Transport.WebSocket.hands_lease_ms/0`; a request each third | the server closes the connection; every hands of it is dead | server |
| runner's lease | as ADR 0012 §3 | the runner kills its hands and tool processes with `:kill` | runner |
| stop of the hands of a session | remote: one deadline of 22,000 ms for the provider ends and the stop answer; local: unchanged | `:unknown` | server |
| `Stop.shutdown_ms/0` | 31,000 ms, unchanged | the supervisor kills the session | server |
| a tool result | `Helyx.Message.cut_result/1`, 65,536 bytes | cut | server |
| a provider event | `Helyx.Session.Stream.check/1`, the mailbox bound of `send_checked/3` | the provider process stops, the turn fails | server |
| a capability report | the checks of `Helyx.Tool.specs/2` | the start fails | server |
| a read of the folder | 256 paths, each path at most 4,096 bytes, each file at most the reader's own limit; the list of a folder: unbounded until the read slice states it | the read fails with an error | Core |
| a folder of a runner | `Helyx.Transport.WebSocket.Pairing.max_folder_bytes/0` | the registration closes with `4401` | pairing |
| connections of a server | two gates, one for each listener, of `Helyx.Transport.WebSocket.max_connections/0` each; each listener admits `Helyx.Transport.WebSocket.tcp_connections/0` TCP connections before the upgrade | HTTP 503 at the upgrade; a TCP connection over `tcp_connections/0` waits for a place | transport |

Each numeric limit gets tests at it, one under, one over, and a multibyte case where it counts bytes, in the slice that builds it.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| --- | --- | --- | --- | --- | --- |
| the stand-in of a remote hands (a server process) | the entry point of Core, at the open of a session with `:hands` | the session (link) and the connection (monitor) | it ends after it passes on the stop answer | the session ends as at a hands crash (`crashed`); the connection sends a stop of the instance to the runner | the session kills it past the shared deadline |
| the hands on the runner | the runner, at `hands.open` | the runner's request queue process | `hands.stop` | the runner kills at the close or at its lease (ADR 0012 §3) | `hands.stop` from the connection at any end of the stand-in |
| tool Tasks and their OS resources on the runner | the hands on the runner | the hands | ADR 0004, unchanged | ADR 0004, unchanged, and the kill at the runner's lease | ADR 0004 |
| the provider process on the runner | the hands on the runner | the hands | `hands.provider_stop` or `close` | the kill at the runner's lease | `hands.provider_stop` |
| the hands connection (socket) | the runner | the runner and the server's connection process | the stop of the runner | the close; on the server, its sessions stop | n/a |
| the public listener socket | `helyx serve --public` | the transport supervisor | the stop of the transport | the transport supervisor stops at the crash of the listener and starts it again | n/a |
| the TLS key and certificate | `Helyx.Transport.WebSocket.TLS.ensure/1`, at the first start with `--public` | the data folder, `<data folder>/tls/` | they stay; a later start reads them | they stay | n/a |
| a peer row | the pairing handshake, in the Hub store | the Hub store | `Helyx.Transport.WebSocket.Pairing.revoke/3` deletes it | it stays | n/a |
| the connection of a peer | the pairing handshake or the handshake of a paired peer | `Helyx.Transport.WebSocket.Pairing`, with a monitor | the close of the connection | the monitor drops the entry | a revoke closes it; a second connection of the same kind and name closes the first |
| a pending link | `pair.create` | `Helyx.Transport.WebSocket.Pairing`, as a closure of the SHA-256 of its bootstrap token | one successful pairing, the end of its lifetime, or the stop of the server | the stop of the server | n/a |
| the background folder of a session | the hands | the hands | the hands delete it at their stop | accepted hole: a killed runner leaves it, as a killed VM leaves it today | the hands delete it at their stop |

## Slices

In order, each through `/ship` with its own commit. The pairing slices come first, so the owner has a runner to pair before a session uses one. The term slices change Core and the local hands only, with no wire, until the entry-point slice.

### Pairing slices

- **P1. The public listener with TLS and the pin.** The option `:public` of `Helyx.Transport.WebSocket`, `Helyx.Transport.WebSocket.TLS`, and `helyx serve --public <host>:<port>`. Tests: the pin is stable across two starts; the folder has mode 0700 and `key.pem` 0600 before its first byte; a loose mode is corrected; a cut key, a key with no certificate, and a certificate of another key refuse the start with a line that names the file, and make no new key; a client with the pin connects and a client with another pin does not; TLS 1.3 only; a connection that sends no ClientHello closes at `handshake_ms/0`; a connection that sends no HTTP request closes at `handshake_ms/0`; the server token is refused on the public listener with `4401`; a bad `--public` value, and port 0, are one line and exit 1; the host is the link's address and the listener binds every interface, IPv6 and IPv4; a webhook path answers 404.
- **P2. Peers in the Hub store.** The table, the schema upgrade, the store functions, and the cap. Tests at the cap, one under, one over; the name check with a multibyte case.
- **P3. Links and `pair.create`, `pair.revoke`, `pair.list`.** Tests: one use; the lifetime; the cap of pending links; a kind that is not `hands` or `client` is `bad_params`; a kind or name that is not a string is `bad_params`; a Hub user token is `forbidden`; `unknown_op` on the public listener; `no_public_listener`; a revoke closes the connection of the peer, also after the row is gone; the state and a crash report hold no link secret, for a link of either kind.
- **P4. The two handshakes on the public listener.** A pairing `hello` and a paired `hello`, for the kind `hands`. After `welcome`, `hands.register {runner, folder}` gives `{lease_ms}`, and the lease closes a silent runner. A second registration of a name closes the first connection, and a second registration on one connection is `bad_params`. A client operation on a hands connection is `unknown_op`. A bad field of a public `hello` closes that connection only, and a Hub that does not answer closes with `4503`. No session uses the runner yet. Tests with a peer in the test process that speaks the frames over TLS: a pairing, then a second connection with the key alone; a wrong signature; a signature over the nonce alone; a signature for another name; a used link; an expired link; a bad field that leaves the loopback listener serving; each listener's gate; a registration with another name than the `hello`; an answer to no open `hands.live`; a Hub that does not answer through a real connection; a link of a caller that died.
- **P5. `helyx pair --runner <name>`** on the server machine. Tests as the CLI tests of `serve` do.
- **P7. The client kind.** The kind `client` of a link and of `hello`, the field `client` of its name, and the credential of the default owner on the public listener. A paired client starts a session, lists it, follows it, and sees a session that the server token started on the loopback listener; the operator operations stay `unknown_op` on its connection. Tests: a client pairing gives a link with `"k": "client"`, the pairing `hello` gets `welcome`, and `pair.list` shows the peer connected; a second connection with the key alone gets `welcome`; a wrong signature, a signature for the kind `hands` with the same name and key text, a signature for another name, and no row are `4401`; a used link and an expired link are `4401`; a `hands` link used with the role `client` and a `client` link used with the role `hands` are `4401` and do not consume the link; the default owner starts, lists, and follows a session, and sees the session of the loopback connection with the server token; `pair.create`, `pair.revoke`, and `pair.list` are `unknown_op`; a revoke closes the connection at once and its key no longer connects; a second connection of the same name closes the first; a client and a runner of the same name pair and both show in `pair.list`; `max_peers` counts both kinds; the state and a crash report hold no link secret, for a client link; a Hub that does not answer closes with `4503`; `helyx pair --client phone` prints a link of the kind `client`, and both switches, neither, and a bad name are one line and exit 1. The Rust client kit implements the client side of this slice: the link, the key, the two handshakes, the TLS check with the pin, and the saved state (`docs/features/client-kit.md`, "A remote server").

### Term slices

1. **The terms.** `Helyx.Session.Hands.Term` (`@moduledoc false`): the term shapes as data, their checks, and their encode and decode to JSON objects, with property tests of the round trip. No caller yet.
2. **The capability report.** The local hands build the tool set and run the tool checks at their start, and the session takes the report (`Helyx.Session.Input.tools/2` moves to the hands). A runner reports no tool source, and `deferred/2` and `activate/1` answer as on a session with no source (decision 2).
3. **Provider start without a closure, ids for pids.** `hands.provider_start` as data; the start gate as `hands.provider_go`; the hands build the args of `ProviderProcess`; `provider_ready`, `provider_down`, and the answer carry the id; the stop of a provider process is a request; reasons as text.
4. **Provider requests as data.** The kill of a request armed by the hands; replies and events by id.
5. **Calls from a tool into its session.** `hands.ask`, `hands.show`, `hands.transcript`, the go handshake by task id, and `hands.task_down`.
6. **Hooks on the runner.** The hook terms, the hook names in the capability report, and the approval ask to the clients (decision 1).
7. **Cancel, revoke, stop with durations,** the background folder on the hands, and the shared stop deadline in `Stop.run/1` for remote hands.
8. **The read of the folder,** and `Helyx.ModelContext.Default` and `Helyx.Skills.scan/2` on it.
9. **The entry point for a remote hands** and the stand-in, tested with a peer in the test process that speaks the terms.
10. **The wire: the `hands` role and the term limits,** with the tests that ADR 0012 lists (build ticket 3) and the fixtures.
11. **The wire: `hands.*` and the lease.**
12. **The runner:** its request queue, its lease, and its kill, and `helyx hands --pair` and `helyx hands --name` at start and resume.

## Decisions

Owner decisions of 2026-11-11. No question of ADR 0012 stays open.

1. **Hooks of a session on a runner run on the runner.** The runner names its hooks in the capability report. The server refuses a runner that does not report the approval hook when the session requires one. An approval prompt does not show on the runner: the runner sends the ask to the server (`hands.ask`), the server sends it to the clients of the user, and the answer goes back. With no client connected the answer is deny. The server forwards the approved call as it was shown, not a later edit of the command or the folder. Reason: the hooks run where the tools run, as today, with one path. A container runner that the agent controls needs more, and it takes the hands credential path of ADR 0012 §5a (out of scope).
2. **No tool sources on a runner in the first build.** `deferred/2` and `activate/1` answer as on a session with no source. Reason: the goal of #925 needs the build tools of the runner, not MCP, and a source call as a request adds five request kinds with their bounds.
3. **Term limits.** Runner to server: the wire limits (26,214,400 bytes, 65,536 values, integers of 1,024 characters). Server to runner: 67,108,864 bytes and 1,048,576 values, integers of 1,024 characters; the slice measures the peak heap of a decode on the runner. Reason: a turn context has no Core size bound, and a term must fit the outbound queue.
4. **A runner connects by pairing.** "Pairing and the public listener" is the design. `helyx hands --connect` with a copied secret is gone, and so is a secret that a client copies by hand after a restart.
5. **The folder of a session on a runner is exactly the folder of the runner.** Another `cwd` gets `bad_params`. Reason: the ADR's user story has the runner register as the hands of a folder, and a session cannot reach above it.
6. **The signature covers the context.** Both handshakes sign the signature text of "The pairing handshake", not the nonce alone: the context text, the nonce, the pin of the server, the kind, and the name, each with a length before it. Reason: a signature made for one server, one kind, or one name is of no use at another. Part 2 signs the same bytes.
7. **TLS 1.3 only.** Both ends are Helyx, so an older version adds a downgrade path for no peer.
8. **A `res` renews the lease only for the open `hands.live`.** The request id carries its sequence, and each request is answered at most once. Reason: an answer with no open request cannot hold a connection alive.
9. **Both kinds pair in this build.** A link of the kind `hands` pairs a runner, and one of the kind `client` pairs a client app (#956). The link keeps its kind field, and the two kinds share the key pair, the two handshakes, and the peers table. Reason: a paired client acts as the default owner of the Hub, and its operations are the client operations of that user, so the authority that the public listener needs for a client exists. A link for another Hub user is not built.

## Out of scope

- Containers, snapshots, portals, secrets, and the model proxy of the key rule (ADR 0012, Out of scope).
- A hands credential minted in memory by a product for a container runner (ADR 0012 §5a). That path stays as the ADR has it, and this build does not use it.
- A child session from the hands: `Helyx.Tool.Agent` is not reported by a runner (ADR 0012 §2).
- A tool set that changes during a session (#473).
- The choice of a runner by the Hub: executor assignment (#928, #857).
- The build tools: #929.
- A result with blocks other than text: #858.
- `helyx hands`, the runner program: part 2.
- A link for a Hub user that is not the default owner. A client link always acts as the default owner.
- The client side of a pairing: the desktop and phone apps that read the link, the keychain, and their UI (`clients/`).
