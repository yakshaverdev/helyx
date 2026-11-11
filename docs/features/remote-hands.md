# Remote hands

Ticket #927, part of #925. ADR 0012 decides remote hands (#856, #886). This doc gives what the ADR leaves to it: the terms of the hands protocol, their codec on the wire, the term limits, the durations on the protocol, the lease setting, the bounds, the ownership table, and the slices of the build. It changes no decision of ADR 0012. Where the ADR leaves a choice open that this doc cannot make from a source, the doc names it under "Open decisions", with options and a recommendation, and no slice that depends on it is built before the owner decides.

## Goal

A Helyx server runs on a Linux VPS. On a Mac, `helyx hands --connect <address>` registers a runner for a folder. A session that names the runner runs its tool calls and its provider process on the Mac (ADR 0012, user story). The capability report of the runner gives the session its tools, so a Mac runner can later report a build tool (#929) that a Linux runner does not.

The session speaks one protocol to local and to remote hands (ADR 0012 §1). So the build first moves the local hands, `Helyx.Session.Hands`, onto the terms of this doc, with no wire, and only then adds the stand-in of a remote hands and the wire. The local hands keep their tests; each slice keeps the suite green.

## The terms

Every term is a JSON object with a string `t`, the kind of the term, and the instance id `instance` of the session (ADR 0012 §3, fencing), plus the fields below. A provider process, a call, a read, and a request from a tool are named by ids that the session or the runner makes, strings of 1 to 64 bytes. No pid, reference, function, or module name crosses (ADR 0012 §2). A reason is the text of `Helyx.Reason.text/1` (`lib/helyx/data/reason.ex`), made on the side that has the term.

The inventory below lists every message between the session and its hands in the code of `ff10c88b`, and its term. The direction is S→H (session to hands) or H→S.

| Today (message, file) | Term | Notes |
| --- | --- | --- |
| tool set built by the caller: `Helyx.Session.Input.tools/2` (`lib/helyx/session/input.ex`) with `Helyx.Tool.specs/2` and `check_available/1` | S→H `hands.open {session, instance, only, provider_opts}`; H→S answer `{specs, concurrent, providers, folder}` or `{error}` | the capability report (ADR 0012 §2); `only` is the `:tools` option of the session; `providers` are the registration ids of the provider plugins of the hands' Core. The server checks the report with the rules of `Helyx.Tool.specs/2` and unique names |
| `Hands.run/4`: `{:run, turn_id, call, context}` cast | S→H `hands.call {turn, call: {id, name, arguments}, context}` | `context` is the map of `Helyx.Tool.context/0` without `core`; the hands add theirs |
| `Outcome.of/3`: `{:tool_result, turn_id, call_id, {status, text}}` or with UI blocks | H→S `hands.result {turn, call, status, text, ui_blocks?}` | the server cuts `text` again with `Helyx.Message.cut_result/1` and checks each UI block with `Helyx.UIBlock.check/1` (ADR 0012 §5) |
| `{:started, {status, text}, pid}` result of a background run (`hands.ex`, the `:started` call) | H→S `hands.result {..., started: true}` | the session moves the asker record of the call Task by its pid (`Asks.started/3`, `lib/helyx/session/server.ex`, the `:started` clause); the term carries the `task` id in place of the pid |
| `{:background_end, message}` (`Outcome.of/4`) | H→S `hands.background_end {id, message}` | the message as the session file codec encodes it |
| `Hands.taken/2` | S→H `hands.taken {id}` | |
| `{:asker, turn_id, pid, asker}` and the go `:helyx_go` (`Helyx.Session.Ask.await_go/0`) | H→S `hands.asker {turn, task, asker}`; S→H `hands.go {task}` | `task` is an id the hands make for each Task; the order guarantee (the session handled the record before the Task asks) holds because the stand-in passes both in the order of the connection |
| `Helyx.Tool.ask/1`, `Helyx.Hook.ask/1` (`GenServer.call` to the session) | H→S request `hands.ask {task, request}`; S→H answer `{answer}` or `{error}` | the bounds of `Helyx.Session.Ask` hold: `request` at most 65,536 bytes of JSON |
| `Helyx.Tool.show/2`: `{:ui_block, call_id, key, block}`, a `GenServer.call` to the session by its Core and id (`lib/helyx/interfaces/tool.ex:208`, handled by `Server.Calls.handle/3`) | H→S request `hands.show {task, call, key, block}`; S→H answer `ok`, `too_many`, `not_running`, or `too_many_blocks` | the server checks the block with `Helyx.UIBlock.check/1` again; on the runner the session's Core and id do not resolve, so the call goes through the hands |
| the `:DOWN` of each Task with an asker record: the session monitors the pid of `{:asker, ...}` (`Server.Asks`, `lib/helyx/session/server/asks.ex:44`) and `Asks.down/3` drops the asker and ends its open asks | H→S `hands.task_down {task}` | the hands send it when a Task that they sent an `asker` for dies, before its release and apart from its later result or hook answer, as the `:DOWN` reaches the session today while the hands still release; so the hands must send it while other releases wait in their queue. On remote hands the session has no pid to monitor |
| `Helyx.Tool.transcript/0` | H→S request `hands.transcript {task}`; S→H answer `{messages}` | the messages as the session file codec encodes them; over the term limit the call fails with an error, the turn goes on |
| `Hands.start_provider/3` with the closure of `ProviderProcess.run/1` | S→H `hands.provider_start {provider, id, model, tools, session, resume_id, resume_usage}`; H→S `hands.provider_start {id, ok}` or `{id, error}` | `provider` is the registration id; the hands resolve it on their Core; an id the hands did not report fails as `{:unknown_provider, id}` on the server before the term goes |
| `:start` from the session to the provider process (`Server.TurnLoop.handle/2`, `lib/helyx/session/server/turn_loop.ex:151`; `Server.Summary.started/2`, `summary.ex:63`), sent after the session recorded the pid of the start answer | S→H `hands.provider_go {id}` | the gate stays: the provider process waits for it before `init/3`, so `provider_ready` and every event come after the session recorded the id. On one connection the order is the order of the terms, but the gate also keeps the summary abort: a summary call that ended before the start answer sends `hands.provider_stop {id, aborted}` in place of the go, as it sends an exit today |
| `{:provider_ready, pid}` (`ProviderProcess`) | H→S `hands.provider_ready {id}` | |
| the `:DOWN` of the provider process: the session monitors its pid at the start answer (`turn_loop.ex:150`) and takes the death before the release ends (`monitor_down/1`: a dying process in a prepare, an idle session that waits for the release) | H→S `hands.provider_exit {id}` | the hands send it when the process ends, before its release; `hands.provider_down` follows after the release, as `{:provider_down, ...}` follows the `:DOWN` today. On one connection the two keep that order. The provider Task has no asker record, so `hands.task_down` does not cover it |
| `ProviderRequest.ask/3`: `{:provider_request, from, tref, request}` with the kill armed on the session's node | S→H `hands.provider_request {id, from, request}` | `from` is an id the session makes. The kill of the request is armed by the hands on their clock with the duration that the session sends, `ms` (ADR 0012 §3, "the runner owns its bounds") |
| `{:provider_reply, from, kind, value}` | H→S `hands.provider_reply {id, from, kind, value}` | an error value as text |
| the actions of the provider process that it sends with `Helyx.Session.Stream.send_checked/3` (`ProviderProcess.action/2`, `lib/helyx/session/provider_process.ex`): `{:stream_event, turn_id, event}`, `{:stream_end, turn_id, terminal}`, `{:tool_request, pid, turn_id, call, bytes, rejection}`, `{:approval, pid, turn_id, approval_id, call_id}`, and `{:resume_id, pid, turn_id, id, cut}` | H→S `hands.provider_event {id, turn, event}` with one `event` shape for each: an event, a terminal, a tool request, an approval, a resume id; the pid becomes the provider `id` | the server checks each again as the provider process does: `Helyx.Session.Stream.check/1` for an event, a tool request, an approval, and a resume id, and the terminal check of `check/1` for a terminal; the mailbox bound of `send_checked/3` holds on the server (ADR 0012 §5) |
| `{:need_context, turn_id}` and `{:need_context, turn_id, :overflow}`, the context requests of the provider process (`ProviderProcess.action/2`; `Server.TurnLoop.handle/2`, `turn_loop.ex:76-89`, and the summary call, `lib/helyx/session/server.ex`) | H→S `hands.need_context {id, turn, overflow}` | not an event: `Stream.check/1` does not take it, so the server checks it with its own shape (a turn id string, `overflow` a boolean) and dispatches it as the session does today, by the turn id |
| `TurnLoop.stop_provider/2`, an exit signal to the pid | S→H `hands.provider_stop {id, reason}` | the hands stop the process on their node |
| `{:provider_down, pid, reason}` (`Outcome.of/4`) | H→S `hands.provider_down {id, reason}` | `reason` is the kind of the down (`provider_timeout`, `task_exit`, an error) with its text |
| `Hands.request_cancel/2` | S→H `hands.cancel {turn}`; answer `{ok}` or `{error, unconfirmed}` | |
| `Hands.request_revoke/2` | S→H `hands.revoke {turn}`; answer `{ids, error}` | |
| `Hands.stop/3` with a monotonic deadline | S→H `hands.stop {release_ms}`; answer `{unconfirmed}`, a list of texts | a duration, never an instant (ADR 0012 §3) |
| `Settle.request/5`: `{:settle, ref, turn_id, input, context}`; answer `{:settle_answer, ref, :settle \| {:continue, module, text}}` | S→H `hands.settle {ref, turn, input, context}`; H→S `hands.settle_answer {ref, answer}` | the module of a `continue` crosses as the hook's registration id; depends on open decision 1 |
| `Approval.request/5`: `{:approve, turn_id, call, context, provider}`; answer `{:approval_result, ...}` | S→H `hands.approve {turn, call, context, provider}`; H→S `hands.approval_result {turn, call, decision}` | depends on open decision 1 |
| `{:hook_answer, turn_id, record}` (`Hands.Hooks`) | H→S `hands.hook_answer {turn, record}` | depends on open decision 1 |
| `Sources.start/3`, `Sources.tools/2`, `{:source, pid, plugin}`, `{:source_down, pid}`, and the source calls of `Helyx.Tool` (`announce/1`, `put_tools/2`, `notice/1`, `deferred/2`, `activate/1`) | open decision 2 | |
| the read of the folder by `Helyx.ModelContext.Default` (`plugins/bundled/lib/helyx/model_context/default.ex`) and `Helyx.Skills.scan/2` (`plugins/bundled/lib/helyx/skills.ex`) on the server's filesystem | S→H request `hands.read {read, paths, max_bytes}`; answer `{files}` | see "The read of the folder" |
| the liveness of a remote hands (new) | S→H `hands.live {seq, ack}`; answer `{seq}` | ADR 0012 §3 |

An answer is the `res` of the request on the wire, and a term with no answer is an `event`. The terms of one session go in the order of the session's sends, on one connection, so the order that the code has today on one node (for example: the end of a closed provider process reaches the hands before its `:DOWN` reaches the session, `lib/helyx/session/server/stop.ex`) holds as long as each side passes the terms of one session in the order it got them. The request queue of the runner (ADR 0012 §3) gives each term to the hands of its session in order; the stand-in passes each term to its session in order.

## Codec on the wire

The wire of ADR 0008 (`docs/features/wire-protocol.md`), protocol 9:

- `hello` gets two fields: `role`, `"client"` (the default) or `"hands"`, and `runner`, a `name` (1 to 64 bytes of a-z, 0-9, and _), required with the role `hands`.
- A runner registers with one `req` `hands.register {runner, folder}`; the result is `{lease_ms}`.
- On a hands connection every S→H term is a `req` frame (ADR 0012 §5), and the runner answers each with a `res`. A term that has no answer today (`hands.call`, `hands.taken`, `hands.go`, `hands.provider_go`, `hands.provider_request`, `hands.provider_stop`, `hands.settle`, `hands.approve`) gets the `res` `{}` when the runner's request queue gave it to the hands; the stand-in does not wait for it and arms no deadline on it (ADR 0012 §3). The runner sends `event` frames for the H→S terms and `req` frames for the requests of a tool (`hands.ask`, `hands.show`, `hands.transcript`). The request ids of the two directions are separate spaces.
- A term is the `params` of a `req`, the `result` of a `res`, or the `data` of an `event`, as the wire has them. Strings are UTF-8; a text that is not valid UTF-8 cannot be a term, so the sender turns it into text as the source of the text does today (a tool result through `Helyx.Message.cut_result/1`, a reason through `Helyx.Reason.text/1`).
- A frame over 1,048,576 bytes goes as parts, as on the wire.
- `start` gets the parameter `hands`, a runner name, and the session file records it. A resume reads it from the file.

## The read of the folder

`Helyx.Session.read_files(paths, max_bytes)` (a name for the build; a function of Core that a plugin calls from the process where the session runs its model context) reads the regular files of `paths` on the hands, each at most `max_bytes`, and gives `{path, {:ok, binary} | {:error, :enoent | :too_large | :not_regular | :eacces}}`. On local hands it reads on the same node. `Helyx.ModelContext.Default` and `Helyx.Skills.scan/2` use it for local hands too (ADR 0012 §2). The bounds: at most 256 paths in one read, each at most 4,096 bytes of path; `max_bytes` at most the limit that each reader has today; and the answer within the term limit.

The skills scan lists folders (`Helyx.Skills`, the scan of `.agents/skills` from the root up to the folder). So the read also needs a list of a folder: `hands.read` takes `{list, paths}` for that. A folder can hold any number of entries, so the list has a bound of its own, which slice 7 states from the bounds of `Helyx.Skills` (200 skills, `@max_skills`, `plugins/bundled/lib/helyx/skills.ex`); until then it is unbounded, slice 7.

## Term limits

ADR 0012 §5: one term on a hands connection has a limit in joined bytes, in decoded values, and in integer size; the sender checks it and fails the one operation, the receiver enforces it and closes the connection. The numbers are open decision 3. Whatever the numbers, the check is the decode bound of `Helyx.Transport.WebSocket.Frame` with the limits of a hands connection, and the sender's check is the same function on the encoded text before the send.

## Durations on the protocol

Every bound that crosses is a duration in milliseconds (ADR 0012 §3):

| Term | Duration | Source |
| --- | --- | --- |
| `hands.stop` | `release_ms`, 20,000 | `Helyx.Session.Hands.State.release_ms/0` |
| `hands.provider_request` | `ms`, the kill of the request | `docs/features/session-lifecycle.md`, "Deadlines" |
| `hands.register` answer | `lease_ms` | the lease setting |

The runner arms them on its own clock. The server arms no deadline on one answer of the runner; it has only the lease and the shared stop deadline.

## The lease setting

A transport option `:hands_lease_ms` of `Helyx.Transport.WebSocket`, an integer from 30,000 to 120,000, default 45,000; another value fails the start of the transport (ADR 0012 §3). The connection process sends `hands.live` every `div(lease_ms, 3)` ms.

## Interface changes

- `Helyx.Session.start/2` and `resume/2`: the option `:hands`, a runner name; the session file records it. The tool set comes from the capability report of the hands, local and remote. The `:provider_opts` of a session with `:hands` are a keyword list whose values encode as JSON, else the start fails before the session starts.
- A public entry point through which a connection hands Core a remote hands (ADR 0012 §1). Name and shape in slice 8.
- `Helyx.Transport.WebSocket`: the role `hands`, `hands.*`, the option `:hands_lease_ms`, and `mint_hands_credential/2` and `revoke_hands_credential/2` (names for the build) in its public API (ADR 0012 §5a). Protocol 9.
- `Helyx.Session.read_files/2` for the readers of the folder.
- `CodingAgent.CLI`: `helyx hands --connect <address>`; see open decision 4.

## Replaced mechanism

The local mechanism and its replacement are the inventory of "The terms". In addition:

1. **The tool set on the caller's node** (`Helyx.Session.Input.tools/2`): replaced by the capability report, for local hands too. This reverts the update of 2026-10-12 of ADR 0003.
2. **The closure of the provider start** (`Hands.start_provider/3`, `ProviderProcess.run/1`): replaced by the data of `hands.provider_start`; the hands build the args with their Core and the folder.
3. **The armed kill of a provider request on the session's node** (`ProviderRequest.ask/3`, `:timer.kill_after(ms, pid)`): the hands arm it. The guarantee that a blocked loop is killed at the bound holds, by the hands' timer.
4. **Pids in the answers** (`{:provider_start, ref, {:ok, pid}}`, `{:provider_down, pid, _}`, `{:provider_ready, pid}`): ids. The session matches on the id where it matches on the pid today (`lib/helyx/session/server.ex`, the `:provider_ready` and `:provider_down` clauses).
5. **The monotonic deadline of `Hands.stop/3`**: a duration.
6. **The background folder delete in `Stop.run/1`**: the hands delete it at their stop (ADR 0012, Consequences).
7. **The wait for the end of a closed provider process in `Stop.run/1`**, which has no `after`: on remote hands, one shared deadline of `@hands_stop_ms` (ADR 0012 §3).

Each slice lists the tests of the old mechanism that it touches, with the property each keeps.

## Bounds

| What | Bound | Over the bound | Where |
| --- | --- | --- | --- |
| hands per session instance | 1 | a term of another instance: refused by the hands, dropped by the session | both |
| connections per runner name | 1 | a new registration closes the old connection | server |
| hands credential | 32 random bytes, one for each runner name; SHA-256 in memory only | n/a | server |
| a frame | 1,048,576 bytes, with parts | close `1009` | transport |
| one term | open decision 3 | the sender fails the operation; the receiver closes | sender and receiver |
| lease | 30,000 to 120,000 ms, default 45,000; a request every third | the server closes the connection; every hands of it is dead | server |
| runner's lease | as ADR 0012 §3 | the runner kills its hands and tool processes with `:kill` | runner |
| stop of the hands of a session | remote: one deadline of 22,000 ms for the provider ends and the stop answer; local: unchanged | `:unknown` | server |
| `Stop.shutdown_ms/0` | 31,000 ms, unchanged | the supervisor kills the session | server |
| a tool result | `Helyx.Message.cut_result/1`, 65,536 bytes | cut | server |
| a provider event | `Helyx.Session.Stream.check/1`, the mailbox bound of `send_checked/3` | the provider process stops, the turn fails | server |
| a capability report | the checks of `Helyx.Tool.specs/2` | the start fails | server |
| a read of the folder | 256 paths, each path at most 4,096 bytes, each file at most the reader's own limit; the list of a folder: unbounded until slice 7 states it | the read fails with an error | Core |
| connections of a server | 64, the hands connections among them | HTTP 503 | transport |

Each numeric limit gets tests at it, one under, one over, and a multibyte case where it counts bytes, in the slice that builds it.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| --- | --- | --- | --- | --- | --- |
| the stand-in of a remote hands (a server process) | the entry point of Core, at the open of a session with `:hands` | the session (link) and the connection (monitor) | it ends after it passes on the stop answer | the session ends as at a hands crash (`crashed`); the connection sends a stop of the instance to the runner | the session kills it past the shared deadline |
| the hands on the runner | the runner, at `hands.open` | the runner's request queue process | `hands.stop` | the runner kills at the close or at its lease (ADR 0012 §3) | `hands.stop` from the connection at any end of the stand-in |
| tool Tasks and their OS resources on the runner | the hands on the runner | the hands | ADR 0004, unchanged | ADR 0004, unchanged, and the kill at the runner's lease | ADR 0004 |
| the provider process on the runner | the hands on the runner | the hands | `hands.provider_stop` or `close` | the kill at the runner's lease | `hands.provider_stop` |
| the hands connection (socket) | the runner | the runner and the server's connection process | the stop of the runner | the close; on the server, its sessions stop | n/a |
| a hands credential | the public API of the server | the server's memory (SHA-256) | revoke, new mint, or the stop of the server | the stop of the server | n/a |
| the background folder of a session | the hands | the hands | the hands delete it at their stop | open: a killed runner leaves it, as a killed VM leaves it today | the hands delete it at their stop |

## Slices

In order, each through `/ship` with its own commit. Slices 1 to 7 change Core and the local hands only, with no wire. A slice that depends on an open decision waits for it.

1. **The terms.** `Helyx.Session.Hands.Term` (`@moduledoc false`): the term shapes as data, their checks, and their encode and decode to JSON objects, with property tests of the round trip. No caller yet.
2. **The capability report.** The local hands build the tool set and run the tool checks at their start, and the session takes the report (`Helyx.Session.Input.tools/2` moves to the hands). Depends on open decision 2 for the tool sources.
3. **Provider start without a closure, ids for pids.** `hands.provider_start` as data; the start gate as `hands.provider_go`; the hands build the args of `ProviderProcess`; `provider_ready`, `provider_down`, and the answer carry the id; the stop of a provider process is a request; reasons as text.
4. **Provider requests as data.** The kill of a request armed by the hands; replies and events by id.
5. **Calls from a tool into its session.** `hands.ask`, `hands.show`, `hands.transcript`, the go handshake by task id, and `hands.task_down`.
6. **Cancel, revoke, stop with durations,** the background folder on the hands, and the shared stop deadline in `Stop.run/1` for remote hands.
7. **The read of the folder,** and `Helyx.ModelContext.Default` and `Helyx.Skills.scan/2` on it.
8. **The entry point for a remote hands** and the stand-in, tested with a peer in the test process that speaks the terms.
9. **The wire: role, credential, protocol 9,** with the tests that ADR 0012 lists (build ticket 3) and the fixtures.
10. **The wire: `hands.*` and the lease.**
11. **The runner:** its request queue, its lease, and its kill.
12. **`helyx hands --connect`** and the runner at start and resume. Depends on open decisions 4 and 5.

Hooks (open decision 1) touch slices 2, 5, and 8 for the hook terms.

## Open decisions

ADR 0012 does not state these, and no source decides them. No slice that depends on one is built before the owner decides.

1. **Hooks on remote hands.** Today the session passes `Helyx.Core.hooks/1` of its own Core, modules and limits, to the hands (`lib/helyx/session/server/open.ex`), and the hands run the hook chains of `before_tool`, approvals, and `before_settle` (`Hands.Hooks`, `Hands.Approval`, `Hands.Settle`). A module cannot cross (ADR 0012 §2), and the ADR's protocol names no hook term. Options: (a) the runner's Core gives the hooks, the capability report names them, and a `continue` of `before_settle` names the hook by its registration id; (b) hooks run on the server, for local hands too, which moves them out of the hands and changes ADR 0013's placement; (c) a session whose Core has hooks does not start on remote hands. Recommendation: (a) for the owner's runner, because the hooks then run where the tools run, as today, with one path. Risk: on a runner that the agent controls, the agent can start a runner of its own with the hands credential and no hooks (ADR 0012, accepted hole of the credential), so the approval gate of #882 would not hold there; a container runner needs (b) or a server-side check before it ships.
2. **Tool sources on remote hands** (MCP, `docs/features/mcp-client.md`). The source processes run in the hands and call the session (`announce/1`, `put_tools/2`, `notice/1`, `deferred/2`, `activate/1`); the ADR names only `ask/1` and `transcript/0` as calls into the session. `Helyx.Tool.deferred/2` and `activate/1` are calls into the session from any tool call or hook (`Server.Calls.handle/3`), not only from a source. Options: (a) the first build: a runner reports no tool source, and a ticket adds them; (b) every source call as a request from the runner. Under (a), `deferred/2` and `activate/1` on the runner answer as on a session with no source. Recommendation: (a): the goal of #925 needs the build tools of the runner, not MCP, and (b) adds five request kinds with their bounds.
3. **The term limits.** A turn context (the system prompt and every message of the context, sent to the provider process on the runner at each turn) has no Core size bound, nor has the answer of `transcript/0`. Options: (a) the inbound decode bounds of the wire in both directions: 26,214,400 bytes, 65,536 values, integers of 1,024 characters; a long session fails its turns on remote hands when its context passes 65,536 values (a tool call and its result count about 15 values, an estimate, not measured); (b) runner to server as (a), server to runner 67,108,864 bytes (the outbound queue bound of a connection, so one term fits in the queue) and 1,048,576 values, integers of 1,024 characters, with the peak heap of a decode on the runner measured in the slice; (c) other numbers. Recommendation: (b), with the measurement before the numbers are final.
4. **The secret and the address of the owner's runner.** `helyx serve` makes a new server token at each start (`docs/features/serve.md`, decision 7), and serves only `ws://` with no TLS (decision 6). ADR 0012 §5a lets the owner's runner prove the server token, and lets a product mint a hands credential through the public API, but names no channel by which the Mac gets either. Options: (a) `helyx hands --connect ws://<host>:<port> --name <runner>` reads the secret from the environment variable `HELYX_HANDS_SECRET` (the server token, which the owner copies from `server.json` on the VPS after each server start), through an SSH tunnel; (b) a mint on the server's own command line, by the code that starts the server (ADR 0012 §5a lets that code mint through the public API), which prints the credential once to the owner's terminal; `docs/features/serve.md`, decision 1, says that no output of `helyx serve` holds the token, so this option changes that rule of serve, not the ADR. A delivery of a credential in a frame, also a frame of the owner's client, is not an option: §5a says the credential never goes in a frame; (c) a `wss://` address and a TLS proxy, with (a) or (b). Recommendation: (a) for the first build; (b) and (c) are follow-ups.
5. **The folder of the runner and the cwd of a session.** The runner registers with one folder (ADR 0012 §5). Options: (a) a session on runner R has the cwd of R's folder; a `start` that names R and another `cwd` fails with `bad_params`; (b) any cwd below R's folder. Recommendation: (a), the ADR's user story ("registers as the hands of a folder").

## Out of scope

- Containers, snapshots, portals, secrets, and the model proxy of the key rule (ADR 0012, Out of scope).
- A child session from the hands: `Helyx.Tool.Agent` is not reported by a runner (ADR 0012 §2).
- A tool set that changes during a session (#473).
- The choice of a runner by the Hub: executor assignment (#928, #857).
- The build tools: #929.
- A result with blocks other than text: #858.
