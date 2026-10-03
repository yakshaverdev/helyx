# The client contract

A client shows a session and sends operations to it: the TUI now, and a SwiftUI app for macOS and iOS later. The server owns all session state, and a client only renders it (README). This ADR defines the contract between a client and a session. Every client uses the same operations, snapshot, and events, through different transports: function calls and OTP messages in one node, or a Transport plugin across devices.

The research is in `docs/research/agent-client-protocols.md`, `docs/research/agent-ui-protocols.md`, and `docs/research/swiftui-client.md` (2026-09-26).

## Decision

### 1. Helyx owns the contract

Helyx chooses its event names, shapes, and rules to meet its own needs. External protocols (ACP, opencode, pi, Claude Code) are references, not rules. Compatibility with an external protocol is the job of a Transport plugin, never of core. An event change states the concrete problem that it solves.

### 2. The contract is a closed list

The contract is the operations below, the snapshot, the events, and the end signal. Nothing else in `Helyx.Session` or `Helyx.Core` is part of it.

| Operation | Reply |
|---|---|
| `start(opts)`, `resume(opts)` | a session, or a start error (below) |
| `subscribe(session)` | `{:ok, snapshot, ref}`, or `{:error, :session_not_found}` |
| `prompt`, `steer`, `follow_up` (text) | `:ok`, or an error atom |
| `abort` | `:ok` |
| `set_model` (a `provider/model` string) | `:ok`, or a model error |

- **Every value is data:** strings, numbers, booleans, atoms, lists, maps, and structs of these. No pid, reference, function, or module. The one exception is the `ref` of `subscribe` in the local transport (below). A remote transport does not send it. An error is an atom, or a tuple of an atom and data.
- **Start errors for a client:** `:invalid_cwd`, the model errors (`{:invalid_model_ref, ref}`, `{:unknown_provider, id}`), and, for `resume`, `:not_found` when the directory has no saved session. Any other start error reaches a client as `{:start_failed, text}`, where the text is for a person. The product still gets the full term, and so does the log.
- **A missing or ended session:** `subscribe` to a session that is not running returns `{:error, :session_not_found}`. It does not exit, and it leaves no subscriber entry and no monitor. An operation on such a session returns the same error.
- **The end signal:** a subscriber learns that a session ended from one signal with a reason as data. The local transport gives it as the `:DOWN` of the caller's monitor of the session process, whose `ref` `subscribe` returns: `{:DOWN, ref, :process, pid, reason}`. `Session.end_reason/1` maps `reason` to `:stopped` or `:crashed` (`docs/features/end-signal.md`). The caller owns the ref and demonitors it when it no longer wants it. The `pid` is not a contract value. A remote transport sends the end signal as a last event and then closes the stream. A stream that closes with no end signal is a lost connection, and the client subscribes again.
- **Not in the contract:** `Session.pid/1`, `Core.plugins/2`, and the registry and supervisor names. They are for the product and for a Transport plugin inside the node. The TUI stops using `Session.pid/1`.

### 3. A client joins with a snapshot

`subscribe` returns a snapshot valid at a `seq`, and then delivers the events after that `seq` (`docs/features/session-snapshot.md`, #163).

- **The rule:** the transcript cells from a snapshot at `seq` equal the transcript cells folded from every event up to `seq`, and so do the model, the queue counts, the streaming message, and the run state. The rule does not cover what is not in the transcript: notices ("aborted", "error: …", harness notices, "resumed session"). A late client does not show them. Since #385, a partial reply with a tool call joins the transcript, with an `aborted` result for each call, and since #432 a partial reply with text only joins too, with the stop reason `aborted` or `error`, so the rule covers both. To rebuild them, the session would have to store display state that the model never reads.
- **Session instance:** each start of a session process, a resume too, is a new instance with a new `instance_id`, and every event and snapshot carry it. A resume keeps the session id and starts `seq` at 0 again, and two Cores can hold one session id. So a client first drops every event whose `instance_id` is not the one of its snapshot, and then every event with a `seq` at or below the snapshot's `seq` (#204, `docs/features/session-instance.md`). Since the revision of 2026-10-03, this rule is for a client that reconnects; the TUI subscribes once and does not apply it.
- **Reconnect:** a client that loses its connection subscribes again and gets a new snapshot. The new snapshot replaces all the session state that the client holds: the client drops its old cells and sets its last `seq` to the `seq` of the new snapshot. It then applies only events of the instance of the new snapshot with a higher `seq`. Notices that the client showed before the reconnect are gone, as for any late client. A server buffer that replays events after a `seq` is an optimization for later.

### 4. Operations and lost replies

- **Three kinds of command.** Client actions (quit, scroll, copy, theme) stay in the client. Session operations are the operations of section 2; each client shows them in its own way, for example `/model` in the TUI and a picker in an app. Server commands, when the first one is needed, are prompt templates: data with a name, a description, an argument hint, and a template. They add no extension interface.
- **A lost reply.** A client never sends an operation again on its own. When the reply of an operation is lost, the client shows the result as unknown and subscribes again. The new snapshot can show that the operation took effect, but it cannot always show that it did not: for example, two steers with the same text look the same. So the result can stay unknown after the reconnect, and the user decides whether to send it again. Request ids with a bounded duplicate check come later, when a client needs to retry on its own.

### 5. Compatibility

Replaced by the revision of 2026-10-03: a client works with one Helyx version and is a tolerant reader within it. The former text below is history and does not apply.

- The snapshot has a `contract_version` (an integer).
- Within one version, the server adds a field, an event type, or a value only when a client that does not know it still behaves correctly when it ignores it. A client ignores an unknown event type and an unknown field.
- Any other change raises the version: a removal, a rename, a change of meaning, and a new value that a client must understand to stay correct (for example, a new final status for a tool call, which an old client would show as open forever).
- A client that does not support the version of a snapshot says so and does not render the session.

### 6. Transports

- The local transport (function calls and OTP messages in one node) is the only transport now.
- The first remote transport is HTTP with Server-Sent Events, as a Transport plugin. Its routes, formats, bounds, and security are in its own feature doc.
- ACP support is a later Transport plugin. It maps the JSON-RPC transport, the session lifecycle, replay, commands, and the Helyx behavior that ACP does not have. Core gives it data values, the snapshot, and `seq`.

## Considered options

- **ACP as the native contract, or the ACP v2 event model in core.** Rejected. ACP v2 is a draft, so core stability would depend on an external draft. An ACP plugin must map the lifecycle, replay, and commands in any case, so the gain is small. Core stays small (AGENTS.md), and a transport is a plugin.
- **Stable ids for messages and tool calls now.** Deferred. They would remove the position rule for provider tool ids that repeat. They did not remove the former accepted limit of section 3; consistent cell-creation rules did (revision of 2026-10-02). Reconnect does not need ids, because each reconnect takes a full snapshot. They come when the second-client test, or a client, shows a need.
- **Store notices and failed partial replies with text only, so that a snapshot can rebuild them.** Rejected for notices: this is display state that the model never reads. Revised for partial replies by #432: such a reply joins the transcript, and the model reads it.
- **Request ids with duplicate detection in the first version.** Rejected for now: no client retries on its own.
- **Phoenix Channels as the first remote transport.** Rejected for the first transport: the Swift clients for the Channels protocol are weak. HTTP with SSE needs no special client library. Phoenix can still come later in a Transport plugin (AGENTS.md); it never goes into core.
- **LiveView Native.** Rejected: the library is archived.

## Consequences

- A contract value that holds a pid, a reference, a function, or a module is a defect. The TUI uses only the contract, so a remote client can do all that the TUI does.
- The rule sentence of `docs/features/session-snapshot.md` changes to state its exclusions, as in section 3. This goes in with this ADR.
- New tickets, in this order:
  1. `subscribe` and the operations return `{:error, :session_not_found}` for a missing or ended session. The start errors for a client follow section 2. The TUI drops its alive check before the subscribe.
  2. The end signal. The TUI stops using `Session.pid/1`.
  3. `contract_version` in the snapshot. Replaced by the revision of 2026-10-03, which removes it.
  4. A second-client test with the local transport. A second subscriber joins during streaming, disconnects, subscribes again, and sends a steer. The test covers a turn that succeeds, a turn that fails, and an abort, and it checks the rule of section 3 at each join. An unstarted call that gets an `aborted` result shows one closed cell in the joined client and in the live client (revision of 2026-10-02). At the reconnect, it checks that the client's `seq` is the `seq` of the new snapshot and that no event at or below it changes the view. Since the revision of 2026-10-03 the TUI view model has no `seq`, so the test no longer checks this; the check comes with the first client that reconnects.
- The HTTP and SSE Transport plugin, a SwiftUI spike, typed blocks, and ACP support wait until the second-client test passes. Each gets its own feature doc or ticket.

## Revision

2026-10-02, ticket #305 (owner decision). The accepted limit of section 3 is removed. A call that never started and got a result in the transcript, such as an `aborted` one, shows a closed cell in the live client and in a late client. The live fold and `ViewModel.from_snapshot/1` make a tool cell with one function, and a result with no open cell gives a closed cell to its call in the last assistant message. The snapshot keeps its bulk construction. The revision of 2026-10-03 replaces this last sentence and the TUI cell rules of this revision: the TUI makes its cells from the messages, and `ViewModel.from_snapshot/1` folds the snapshot messages through the live fold.

2026-10-03, ticket #404 (owner decision). The tickets after #404 build it.

- **Section 5 is replaced.** A client works with one Helyx version: at connect it compares the version for equality and refuses a mismatch. A client in the same node as its Core needs no check. The remote check is built with the first remote client, not now. It compares a build id, because two dev builds can share a version. The hand-bumped `contract_version` and the rules about when to bump it go away.
- **Tolerant reader.** Within its version, a client dispatches on the event type first. Each known type has a clause that matches the type only and checks its payload inside, so a known event with a broken shape is a contract break, and the client does not repair it. Only a type that no clause names is ignored. An unknown field is ignored. An unknown block kind shows a placeholder, such as `[unsupported block: image]`. Block kinds and roles dispatch the same way.
- **The TUI drops the instance and `seq` guards of section 3.** The TUI subscribes once. The registration and the snapshot happen in one server handler (the subscribe clause of `lib/helyx/session/server.ex`), so no event of another instance or of an older `seq` can reach it. The TUI exits when the session ends. Section 3 stays for a client that reconnects.
- **TUI cells from the messages.** Each call of the streaming message and each call with no result shows an open cell labelled "awaiting result". The message proves that the call exists, not that it runs: an API provider runs it after `message_end`, and a harness program already runs it. A call that later gets an `aborted` result shows the label until that result. A result closes its cell. The TUI does not read `tool_execution_start`. `ViewModel.from_snapshot/1` folds the snapshot messages through the live fold, so the live and snapshot paths of the TUI share one pairing rule. Core and the TUI can still disagree, so the tests that compare a client against real session events stay. `Snapshot.turn.running` is removed from Core.
- **Cost.** A native app and its server must update together: an app that is older than its server refuses to connect until it updates.
