# Remote hands: one serializable hands protocol, first on one runner

Ticket #856, part of the roadmap #853. Owner decision of 2026-11-06: the hands use the same wire. The other points stand as the ticket proposes them. This ADR revises the update of 2026-10-12 of ADR 0003 for every hands, local and remote. The codec, the numbers, and the ownership table go in a feature doc, `docs/features/remote-hands.md`, which the first build ticket writes.

User story: `helyx serve` runs on a server. On a laptop, `helyx hands --connect <address>` registers as the hands of a folder. A client starts a session for that folder. The session runs on the server; every tool call runs on the laptop, and so does the harness program (Claude Code, Codex). The laptop disconnects: the running calls get their release, the turn fails as a Core stop fails it, and the session file stays. The laptop connects again: a client resumes the session, and it runs with the same hands.

## Context

- ADR 0003 made the hands a process so that the session and the tools could run on two machines. Its update of 2026-10-12 notes that the session builds the tool set and runs the tool checks on its own node (`Helyx.Tool.specs/2` and `Helyx.Tool.check_available/1`, in the caller of `Helyx.Session.start/2` and `resume/2`, `lib/helyx/session.ex`), so remote hands would need that decided again.
- The session talks to its hands with OTP messages that hold pids, refs, and a function. `Helyx.Session.Hands.start_provider/3` takes a closure, `Helyx.Session.ProviderProcess.run/1`, whose arguments hold the session pid (`lib/helyx/session/server/turn_loop.ex`). The answers name the provider process by pid: `{:provider_start, ref, {:ok, pid}}`, `{:provider_down, pid, reason}`. The provider process sends its events and replies to the session pid (`Helyx.Session.Stream.send_checked/3`, `Helyx.Session.ProviderRequest`). So a pid on another node is not enough.
- A tool calls into its session: `Helyx.Tool.ask/1` and `Helyx.Tool.transcript/0` make a `GenServer.call` to the session.
- A death of the hands stops the session (`Helyx.Session.Server`, the `:EXIT` clause), and a resume gives every open call the interrupted result of `docs/features/interrupted-calls.md`.
- The wire of ADR 0008 has a token proof, a protocol number, frame bounds, parts, and a ping that ends a connection whose peer is gone within 45,000 ms (`docs/features/wire-protocol.md`).

## Decision

### 1. A Core construct, not an interface

The hands protocol is Core, behind the split that ADR 0003 made. It is not a sixth interface: Core does not dispatch to a hands plugin, and every provider needs it, because every provider process runs on the hands side (ADR 0007, amendment of 2026-10-02). The local hands, `Helyx.Session.Hands`, become one implementation of the protocol. The session speaks only the protocol, to local and to remote hands alike, so the two kinds have one path and one set of tests.

Core does not name the wire. It defines the protocol as terms of data, and a public entry point through which a connection hands Core a remote hands that speaks those terms. The WebSocket transport carries them as frames, and it uses only the public API, as ADR 0008 §1 requires.

### 2. The protocol

Every term is data: strings, numbers, booleans, lists, and maps that encode as JSON. No pid, reference, function, or module name crosses it (ADR 0003). A provider process, a call, and a cancel are named by ids that the session makes. The protocol has these parts:

- **Capability discovery.** At each start and resume of a session, the hands build the tool set and run the tool checks on their own node, and report the specs, the names of the concurrent tools, and the providers that they can start. The session resolves a `provider/model` reference as today, and a start whose provider the hands did not report fails as `{:unknown_provider, id}`. The session takes what the hands report, keeps the tools of its `:tools` option, and checks the report as it checks plugin output today: the rules of `Helyx.Tool.specs/2`, unique names. A hands that reports an unavailable tool fails the start as `{:tool_unavailable, name, reason}` does today. The plugin tables of the two nodes do not change during a session (#473 stays open). This reverts the update of 2026-10-12 of ADR 0003, for local hands too.
- **Tool call and result.** The call with its turn id, its call id, and the context of `Helyx.Tool.context/0`, but without the Core name: the hands add their own. The result as today. The start answer and the end of a background run, and the `taken` of a run end.
- **Reads of the folder by the session node.** A plugin that runs on the session node and reads the working directory or the user's home, such as `Helyx.ModelContext.Default` (the context files from the root down to the folder) and `Helyx.Skills.scan/2`, reads them through the hands, never from the server's filesystem. Core gives such a plugin a bounded read that goes through the protocol; the feature doc names the call and its bounds, and the two bundled readers use it, for local hands too.
- **Calls from a tool into its session.** `Helyx.Tool.ask/1` and `Helyx.Tool.transcript/0` become requests from the hands to the session, with the same bounds and answers. A tool that calls the session API of its Core itself needs the Core of the session. The one bundled tool that does so, `Helyx.Tool.Agent`, starts a child session on `context.core`; on a runner that Core is not the server's, and a child there would put session state on the runner. So a runner does not report it. A request from the hands that starts a child session on the server, with the parent link and the cleanup of `Helyx.Tool.Agent`, is a later decision.
- **Provider start without a closure.** The start names the provider by its registration id, with the model, the tool specs, the session id, the resume id, and the resume usage as data. The runner puts in its own Core and the folder. Every request to the provider process (a turn with its context, a steer, an interrupt, an idle close, a close) crosses as data too. The `:provider_opts` of a session with remote hands are a keyword list whose values encode as JSON; the runner turns a key back into an atom only when that atom exists, so network data makes no atom, and a start with another key fails. A start or resume with other options fails before the session starts. The provider config and the credentials that the runner's node holds stay on that node (section 6).
- **Reasons as text.** A provider error, a failed start, an error reply, and the end of a provider process can hold any term today. They cross as the text of `Helyx.Reason.text/1`, made on the runner, and the raw term goes only to the runner's log (ADR 0006 §2: Core turns reasons into text in one place). The answer, the ready signal, every event, every reply, every request of the session (turn, steer, interrupt, idle close, close), and the end of the provider process carry the provider id, not a pid.
- **Cancel and stop, with release confirmation.** A cancel of a turn answers `ok` when every release returned, or an error that names the handles that stay unconfirmed. A stop answers the unconfirmed handles as text, in place of the terms that `Helyx.Session.Hands.stop/3` returns today. The rules of ADR 0004 hold inside the hands node unchanged: `Helyx.Tool.hold/1`, `release/3`, the links, and the watchdog at the port.
- **Disconnect.** Section 4.

### 3. Fencing and lease

- One session instance owns one hands at a time. Every term carries the instance id of the session. The hands refuse a term of an instance that they do not hold, and the session drops a term of an instance that is not its own.
- A runner holds one hands for each session id. When it gets the start of a newer instance of a session id that it still holds, it stops the older hands and waits for its release before it starts the new one.
- A hands that lost its session releases every handle, as `Helyx.Session.Hands.stop/3` does at a session stop. A runner whose connection closes does this at once. A runner that cannot tell, such as on a connection that is half open, does it when its lease ends: a deadline with no frame from the server. The server pings every 15,000 ms and ends a connection with no inbound frame for 45,000 ms. The lease is longer than the ping interval and at most those 45,000 ms, so the runner starts its release no later than the server takes the hands as lost. The feature doc states the number.
- One connection for each runner name. A second registration of a name replaces the first: the server closes the older connection, and its sessions stop as in section 4.
- The runner arms the kills of ADR 0007 on its node, as the local hands do. A runner can still answer pings while it does not answer a request, so the ping alone does not bound a request. Every request of the session that has a deadline today (a provider request, a cancel, a stop) gets a deadline on the server too: its local deadline plus a margin for the network that the feature doc states. The capability report, which has no deadline today because it runs in the caller, and a read of the folder get one too. Each is armed at the OTP timer server, as ADR 0007 arms a deadline, never as a timer of the session process: an exit signal with a `{:shutdown, _}` reason (`:timer.exit_after/3`) to the server process that stands for the remote hands, which does not trap exits. A start or resume that waits for the report watches that process and fails when it ends. Past a deadline, the hands is lost (section 4), and a late answer finds no process. A tool call has no deadline, as today: its cancel has one.

### 4. Disconnect and reconnect

- A runner that misses a deadline cannot be trusted to release on request. So at a missed deadline the server closes the runner's connection, which stops every session on it; the runner releases at the close, or at its lease when the close does not reach it.
- A closed connection, or a missed deadline of section 3, is a lost hands. The session stops as at a death of the hands today: the turn fails, the session file stays, and the stop report gives every handle of the lost hands as unconfirmed. A `notice` event tells the clients that the hands are lost, before `session_end`.
- New: the session stops with a `{:shutdown, _}` reason, so `Helyx.Session.end_reason/1` gives `stopped`. A lost connection is an expected event, not a crash, and `session_end` keeps its two reasons. A crash of the hands process, local or the one on the server that stands for remote hands, still ends the session as `crashed`.
- The runner releases every handle of that connection (section 3).
- No call survives a disconnect. At a resume, every open call gets the interrupted result of `docs/features/interrupted-calls.md`, as after a Core stop.
- The session file records the runner name. A client resumes the session as after any stop, and the resume goes to the runner of that name. Without a connected runner of that name, the resume fails with an error, and nothing starts. The server does not resume a session by itself.

### 5. Transport: the same wire

- The runner connects on the WebSocket wire of ADR 0008 with a `hands` role in `hello`, the same token proof, the protocol number that every client sends, and the same frame size and parts. There is no second listener.
- The frames of the hands are a namespace of operations and events, `hands.*`, on the frame types that the wire has. A runner registers with one `req`, with its name and its folder. On a hands connection the server sends `req` frames for the terms that the session sends, and the runner answers with `res` and sends `event` frames for the terms that the hands send. The calls of a tool into its session are `req` frames from the runner.
- A hands connection counts against the 64 connections of a server. A client operation on a hands connection, and a hands operation on a client connection, get `unknown_op`.
- The role and the `hands.*` operations change the schema, so the build ticket raises the one protocol number that clients and runners share. A bump of another ticket, such as #857 or #858, is separate.
- **The sender checks each term.** Some terms have no Core size bound: a tool spec, the system prompt and the context of a turn, the answer of `transcript/0`. So no limit derived from Core bounds covers every legal term. A hands connection has its own limits for one term, in joined bytes, in decoded values, and in integer size, which the feature doc states and which both sides know. Before it sends a term, the sender checks it against them; a term over them fails the one operation that it belongs to with an error (the turn, the start, the call, the read), not the connection. The receiver enforces the same limits, and a frame over them is a contract break of its peer, which closes the connection.
- The server checks every frame of the hands as plugin output. It trusts no check that the runner ran, because that check ran on a node that the server does not control: the text of a tool result goes through `Helyx.Message.cut_result/1` again, and every provider event passes `Helyx.Session.Stream.check/1` on the server. This is a second check next to the one of the provider process on the runner, and it is deliberate. A result that carries blocks other than text is #858. The session mailbox bound of `Helyx.Session.Stream.send_checked/3` applies on the server: past it, the server stops the provider process on the runner, and the turn fails, as today.

### 6. Who provisions

Starting a container, a snapshot of `.agents/setup`, secrets, portals, and any process that starts a runner belong to a product or a bundled integration module, never to Core. The provider options and credentials that a provider process needs come from the runner's node, because the process runs there.

## Bounds

| Input | Bound | Where |
|---|---|---|
| hands per session instance | 1 | the instance id in every term |
| connections per runner name | 1; a new one replaces the old | server |
| a frame of a hands connection | 1 MiB, with parts | transport |
| one term on a hands connection | the joined-byte, value, and integer limits that the feature doc states; over them the sender fails the one operation, and the receiver closes the connection | sender and receiver |
| a request of the session to the hands, the capability report, a read of the folder | a deadline plus a network margin, armed outside the session process; past it the server closes the connection | server |
| a tool result from the hands | the cut of `Helyx.Message.cut_result/1`: valid UTF-8, at most `Helyx.Message.max_result_bytes/0` bytes | server |
| a provider event from the hands | `Helyx.Session.Stream.check/1`, and the session mailbox bound | server |
| a capability report | the checks of `Helyx.Tool.specs/2`, in one request | server |
| lease | the deadline that the feature doc states, over 15,000 ms and at most 45,000 ms; after it the runner releases every handle | runner |
| reconnect | the open calls get interrupted results, as a resume after a Core stop gives them | session resume |

## Considered options

- **A second listener for the hands.** Rejected by the owner: a second port, a second auth, and a second set of bounds, for frames that the wire can carry.
- **A Hands interface in Core.** Rejected: Core would not dispatch to a hands plugin; it speaks a protocol to a peer.
- **Erlang distribution between the server and the runner.** Rejected: the closure and the pids would cross as they are, but distribution trusts the whole peer node, and a runner that is not on the BEAM, or a server on a runtime that cannot run one, could not take part.
- **The provider process on the server for an API provider.** Rejected: two provider paths, against the one path of ADR 0007's amendment of 2026-10-02.
- **Calls that survive a reconnect.** Rejected: a call's result would come to a session instance that did not start it, and the interrupted result already tells the model to check the effects.

## Consequences

- ADR 0003 gets an update note: since this ADR the hands report the tool set and run the tool checks, for local and for remote hands.
- `docs/features/wire-protocol.md` names this ADR for the `hands` role. Its schema does not change until the build ticket.
- Accepted hole: between a replace or a half-open close and the end of the old runner's release, the commands of the old hands can still run. The model gets interrupted results at the resume and checks the effects.
- Accepted hole: `Helyx.Tool.Agent` is not available on remote hands until a child session can be started from the hands.
- The background folder of a session moves to the hands node, and the hands delete it at their stop, no longer `Helyx.Session.Server.Stop`.
- This work gives the means to choose a runner: a start option that names it, a `hands` parameter of `start` on the wire, and the runner name in the session file. Which runner a session gets in a product with a hub is the executor assignment of `Helyx.Hub` (#857), which uses these means.

Later tickets of #853 build, in this order:

1. The feature doc `docs/features/remote-hands.md`: the terms, their codec on the wire, the lease number, the term limits, the deadlines and their margin, the bounds, and the ownership table.
2. Core: the protocol terms; the local hands as one implementation of them; the capability report in place of the tool set that the session builds; the provider start without a closure; reasons as text; the read of the folder, and `Helyx.ModelContext.Default` and `Helyx.Skills.scan/2` on it; the entry point for a remote hands.
3. The wire: the `hands` role, the `hands.*` operations and events, and the new protocol number.
4. The runner, `helyx hands --connect`, and the runner choice at start and resume.

Out of scope: containers, snapshots, portals, and secrets (follow-ups after this ADR); a tool set that changes during a session (#473); a UI for harness approvals.
