# Client kit

Ticket #860, part of #853. The owner's decisions are in the ticket body and its comments of 2026-11-06.

## Goal

An adopter of Helyx gets a cross-platform app from a shared client core and a thin reference app per platform, and needs no client change for a new mode: the logic lives in Helyx Core and the plugins, and the wire conformance fixtures (`test/fixtures/wire/`, #855) are the contract.

Decisions, each fixed by the owner on 2026-11-06:

- **A shared core in Rust**, in `clients/rust/` of this repo, so the fixtures and the client change in one commit. Desktop apps link it; mobile apps call it through generated bindings (a later ticket).
- **GPUI for the desktop, macOS first**, the owner's daily client.
- **The gate is `precommit.sh`**, as for a Mix project. The repo has no CI.
- **Rust is pinned in `.tool-versions`** (`rust 1.99.1`), so `mise exec` gives `cargo` on the owner's Mac and on the precommit host, where `~/.cargo/bin` is not on `PATH`.
- **Auth is the token proof of protocol 3** (rule O1). Hub auth follows #869.
- **No client extension point** in the first version: a block of a kind that the kit does not know shows its fallback text (#858). Protocol 3 carries no UI block and no fallback text (`docs/features/wire-protocol.md`, "Out of scope"), so today the core keeps the kind of an unknown block, and a renderer shows a placeholder with that kind. The block models of the block vocabulary of ADR 0011 come with the protocol number that adds UI blocks to the wire.

## Slices

The ticket is built in this order. Each slice passes the gate; slices 1 and 2 are one commit, and the fixes of their review (cycle A) another.

1. **The gate.** `.tool-versions` pins `rust 1.99.1`. `.claude/skills/ship/precommit-run.sh` runs `mix precommit`, then, for each `clients/*/Cargo.toml`, `cargo fmt --check`, `cargo clippy --locked --all-targets -- -D warnings`, and `cargo test --locked` through `mise exec`. `precommit.sh` runs that file here or on the host. Every step runs; the last line names each step that failed.
2. **The protocol core** (`clients/rust/core`, crate `helyx-client-core`). It does no I/O: a host feeds it the text of each server frame of one connection, and sends the frames it returns.
   - `json`: the JSON of the wire, lossless. A number keeps its text, so an integer of a tool call keeps every digit, and no object key has a meaning of its own (a decoder that reads a key as a number, such as `serde_json` with `arbitrary_precision`, changes a tool argument that holds that key). `decode` holds the outbound decode bounds of the wire and the depth bound of this client (table "Bounds"); an object lookup takes the first pair of a key, as `JSON.decode/1` of Elixir and `Helyx.Transport.WebSocket.Frame.decode/3` do (probed on 2026-11-06: `{"a":1,"a":2}` gives `a` 1), and `encode` writes every pair in its order. A number `>= 0` of the schema is read by its value, so `-0.0` is zero, as the `>= 0` checks of the server have it.
   - `handshake`: `challenge` (a nonce of exactly 32 bytes), `hello` with `proof = base64(HMAC-SHA256(SHA-256(token), nonce))` or no proof with no token, then `welcome` of protocol 3 or `refused` with the server protocol, which is not 3: the server refuses only a protocol that is not its own. Any other frame or order is a break, and after a break, `welcome`, or `refused`, every frame is a break.
   - `frame` and `event`: `res` read by the op of its request (a `res` of no request in flight is a break), `event`, and `session_end`, each checked by the schema of `docs/features/wire-protocol.md`. An event of an unknown type is skipped with its envelope checked; a known type with a broken shape is a break. As in the TUI, `tool_execution_end` carries a tool result, and `queue_dropped` and `steer_unconfirmed` carry user messages only. A `tool_call_id` is optional, as the schema has it ("Pairing"). A `subscribe` result has exactly one of `snapshot` and `replay`.
   - `fold`: the state of one subscription, by the rules of `test/fixtures/wire/README.md`, "folds.json": a snapshot replaces it, a replay applies its events, an event applies. Every event of a subscription comes after its snapshot or its replay and is of that instance: a restart of the session ends the subscription with `session_end`, and a replay comes from the ring of the instance of `after` ("Replay" in `docs/features/wire-protocol.md`). So an event before a snapshot, an event of another instance, a replay to a state with no snapshot (the state sent no `after`), and an event whose `seq` is not the next one (O4: a duplicate, an older one, or one after a gap) are breaks and change nothing; in a replay, the events before the break stay applied. The TUI drops an event of another instance and an older one instead, so the core is stricter; the TUI subscribes again at a switch of the session on one connection, and the core keeps one state for each subscription. Only an assistant message is a partial that deltas stream into: a snapshot whose partial has another role is a break, as in the TUI, and a `message_start` of another role opens none. A `message_end` adds a user or an assistant message, and an assistant one ends the partial; a tool result joins the transcript at `tool_execution_end` only, as in the TUI.
   - `transcript::rows`: the rows that a client draws, derived on read ("Pairing"). `subscribe_params` adds `after` of the last applied event. `ack(sub, from, to)` gives the `ack` frame when a frame moved the `seq` past a multiple of 1,024, the cadence of the TUI, so a replay that crosses one acks too.
   - Tests: `core/tests/fixtures.rs` runs every case of `server_frames.json` (handshake, `res`, `event`, `session_end`) and of `folds.json`; `core/tests/fold.rs` checks the rules the fixtures do not pin; `core/tests/checks.rs` and `core/tests/json.rs` check the bounds of the table below; `core/tests/transcript.rs` checks the pairing.
3. **The connection** (`client`, `connection`, `parts`), still with no I/O: the host opens the WebSocket, calls `Client::connect`, gives each text frame to `Client::receive`, sends each `Output::Send`, and calls `Client::closed` with the close code, or none for a lost connection.
   - `parts`: a server frame of `"type": "part"` is joined: exactly the keys `type`, `n`, `last`, `data`, `n` from 0 with no gap, `data` of base64, the joined text UTF-8 and within the frame bound of `json::WIRE`, then decoded as one frame that is not a part. A frame while parts wait, a part inside parts, and any other broken part are breaks (as `Helyx.Transport.WebSocket.Frame`). A request whose text is over 1,048,576 bytes goes as parts of 786,000 bytes, and one over 26,214,400 bytes, the request size of the server, is refused (`Refusal::TooLarge`), so the server never closes with `4413` for it.
   - `connection`: the state of one socket: the handshake, the parts, the requests in flight by id (at most 16, the bound of the server; a 17th is refused with `Refusal::Busy`), and the live subscriptions by `sub`. A request goes only after `welcome`. An event or a `session_end` of a `sub` that the connection does not hold, a `subscribe` reply with a `sub` that it holds, and a reply of no request in flight are breaks.
   - `client`: the state of each session that the host followed, which outlives a connection, and one stored intent for it, `wanted`. Whether the session has a live subscription or a subscribe on the way is read from the connection, not stored. After each input (a frame, a welcome, a host call), the client sends a subscribe, with `after` of the state, for each wanted session that has neither, oldest session id first, while a request place is free; so a lost connection, any close code, and the `4408` slow close resume with a replay or a snapshot, and a subscribe that finds no place goes at the next reply. A session is not subscribed again while a subscription of it lives, so two subscriptions never feed one state. The intent and its rules are in `follow`. `subscribe` sets the intent (at most 16 sessions); `unsubscribe` clears it and sends the `unsubscribe` of the live subscription, whose reply ends only the subscription that it named; a refused subscribe clears it and gives `Output::Unfollowed` with the error (the server answers `busy` when its places are full, see "Bounds"); a `session_end` clears it when the session has no newer subscription or subscribe and the host did not unsubscribe that subscription, so a subscribe that the host made while the old subscription ended stands. A `history` reply of `instance_changed` renews a wanted session whose state is of the instance that the page named: the session started again, so the `session_end` of that instance keeps it wanted, and the next subscribe reply ends the renewal. A page of another instance, or of a session that is not wanted, renews nothing: the host follows that session again if it wants to. An `after` whose `instance_id` would take the subscribe over the request size is left out, and the server sends a snapshot. After each frame that moves a `seq` past a multiple of 1,024, the client sends the `ack` (a snapshot is the credit base, so it is not acked). `closed` gives `Next::Reconnect` after a welcome, and `Next::Stop` for a connection that ended before its welcome, by a break, or by `refused`, as the TUI ends at a failed reconnect. `forget` drops the state of a session that is not wanted and has no subscription or subscribe on the way.
   - Tests: `core/tests/client.rs` runs every fold of `folds.json` through connections, closes, and the subscribe with `after` that the client sends at the welcome; and the rules above.
4. **The GPUI macOS app** (not built): session list, session view, block renderers, settings, push. GPUI may need system packages on the Linux host for `cargo clippy` and `cargo test`; they are listed here when slice 4 adds the app.

## Pairing

The session pairs each tool result with its call: a live result follows its call, and at read `Helyx.Session.Transcript.repair/1` drops a second result of one call. That is a rule of the server, and the fixtures are the contract, so a client enforces at its boundary only what keeps it whole: the shape of each frame by the schema, and the bounds, so that it never crashes and never grows without a bound. It does not enforce the pairing, which needs state that only the server holds in full (a tail snapshot can start after a call). It shows what it gets:

- A result closes the oldest open call of its `tool_call_id`, as in the session. Only an assistant message opens calls, as in the TUI: a tool call block of a user message is part of that message.
- A result with no open call of its id, or with no `tool_call_id` (the schema has it optional), is an orphan row in its place, drawn as a result with no call.
- The pairing is derived on read (`transcript::rows`) from the messages of the state: the fold stores no open calls.

The TUI does the same (`Helyx.TUI.ViewModel`): an orphan result is a cell `{:tool, nil, "a tool result with no call", result}`. Before #860 it crashed on an orphan (#407), and its decoder broke on a `tool_execution_end` result with no `tool_call_id`. The fixtures hold both cases: `server_frames.json`, "tool_execution_end: a result with no call id", and `folds.json`, "a tool result with no call before it is an orphan in its place".

## Interface changes

- New: the Cargo workspace `clients/rust/` and the crate `helyx-client-core` (`publish = false`).
- `.claude/skills/ship/precommit.sh` runs `precommit-run.sh` instead of `mix precommit`; `.tool-versions` gains `rust 1.99.1`. The rsync to the host leaves out `target/`, so the build cache of the host stays between runs.
- The toolchain needs the components `clippy` and `rustfmt`. `mise` installs a Rust with the minimal profile, which has neither, so on a machine whose `mise exec -- cargo clippy --version` fails, add them once in a folder whose `.tool-versions` pins the Rust: `mise exec -- rustup component add clippy rustfmt`. That ran on the precommit host on 2026-11-06; the Mac had both. No system package is needed for the core.
- No server change. The fixtures gain three cases (an orphan result, a result with no call id, a `refused` of the client's own protocol), and the TUI follows them: `Helyx.TUI.ViewModel` shows an orphan, `Helyx.TUI.Wire.Decode` takes a result with no call id, and `Helyx.TUI.Wire` breaks on a `refused` of its own protocol.

## Replaced mechanism

1. **The crash of the TUI fold on a tool result with no open call** (#407, `view_model_test.exs`, "a result with no open call crashes"). Replaced by the orphan cell ("Pairing"); the test checks the orphan cell. The guarantee it gave, that a client sees the pairing of the session, stays with the session (`Helyx.Session.Transcript.repair/1`).
2. **The break of the TUI decoder on a tool result with no `tool_call_id`** (`decode_test.exs`). Replaced by an orphan cell; the test checks that it decodes.
3. **The rules of the core of the first commit of #860** (`6e1e06d5`), each replaced by this cycle:
   - An event of another instance changed nothing; it is a break now ("Slices", `fold`), test `tests/fold.rs`, "an event before a snapshot or of another instance is a break".
   - `tool_execution_end` needed a `tool_call_id`; it does not now ("Pairing"), test `tests/checks.rs`, "a tool result may have no call id" (it was "a tool result has its call id").
   - The core read a `serde_json::Value` that the host decoded, with `arbitrary_precision`; it decodes the text itself now (`json::decode`), and the default depth of `serde_json`, 128 levels, is 1,024.
   - A `refused` of protocol 3 gave `Refused(3)`; it is a break now, in the core and in `Helyx.TUI.Wire`.

Otherwise the TUI keeps its own client and view model in Elixir; the Rust core is a second client of the same fixtures.

## Bounds

The core decodes the text of each frame with `json::decode`.

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| `nonce` of `challenge` | exactly 32 bytes after base64 | a break | `handshake` |
| `id` of a `res` | 1 to 64 bytes, and the id of a request in flight | a break | `frame::parse` |
| an `int` of the schema | 0 to 2^64 − 1 (`u64`), judged by its value (`-0` is 0); the server sends far smaller. The TUI has no upper bound here, so an `int` above 2^64 − 1 is a break in the core and not in the TUI | a break | `json::Json::as_u64` |
| the values that the TUI checks beyond the schema | none: the core checks the schema, and the TUI also checks `Helyx.Usage.valid?/1` (tokens up to 10^15, a cost up to 10^12 with its `cost_kind`, a context window of at least 1) and a model as a model ref (`docs/features/wire-protocol.md`, "Conformance fixtures"). A frame over those is a break in the TUI and shown by the core | shown | none |
| unacked events of a subscription | an `ack` after each frame that moves the `seq` past a multiple of 1,024, far below the 16,384 of the `:slow` end | the server closes with `4408` | `fold::ack`, sent by the host |
| `seq` of an event | the `seq` of the state plus one | a break | `fold::State::apply` |
| one server frame, as a text | 1,048,576 bytes | a break | `connection::Connection::decode` |
| the joined parts of one server frame | the frame bound of `json::WIRE`, 1,611,661,312 bytes | a break | `parts::Joiner::take` |
| one request of the client | 1,048,576 bytes in one frame, else parts of 786,000 bytes, at most 26,214,400 bytes in all | `Refusal::TooLarge`, nothing sent | `parts::split` |
| requests in flight on one connection | 16, freed at each reply. The server holds the place of a request that it answered with `timeout` until its worker ends ("Bounds" of the wire), so after a `timeout` the server can still answer `busy` | `Refusal::Busy`; a `busy` of the server is a reply (a subscribe: `Output::Unfollowed`) | `connection::Connection::request` |
| the wait for a reply | none in the core: it has no clock. A request whose reply never comes keeps its place until the connection ends; the TUI ends a request at its deadline and 5,000 ms (`Helyx.TUI.Wire.Connection`). Open, accepted: the host closes a connection that stalls | the 16 places fill, then `Refusal::Busy` | the host |
| the wait for `challenge` | 5,000 ms (`docs/features/wire-protocol.md`, "Bounds") | the host closes the connection; `closed` gives `Next::Stop`, as before a welcome | the host |
| followed sessions | 16 wanted sessions, the subscriptions of one connection on the server. A renewal by `instance_changed` takes a place too, and is not made when none is free | `Refusal::TooManySubscriptions` | `client::Client::subscribe` |
| states of sessions | one for each session that the host followed, kept after the following ends, for the host to show, until the host drops it with `Client::forget` | the host forgets the ones it no longer shows | `client::Client::forget` |
| the transcript of the state | the bound of the TUI view model: none of its own. The TUI cell list is "unbounded: one cell for each message, tool call, stop line, notice, and information cell" (`docs/features/coding-agent.md`, row "TUI cell list"), and the transcript of the session that it mirrors has no bound of its own either: a resumed one comes from a session file of at most 64 MiB, and a live one grows by the turns of the human (`docs/features/session-snapshot.md`, row "transcript in the full snapshot"). The core holds the same: the tail of the snapshot, then one message for each `message_end` and `tool_execution_end`, and one notice for each `notice` and failed `turn_end`. `transcript::rows` derives one row for each message and tool call | the state grows with the session, as the session does | none, as in the TUI |
| a partial message | grows by each delta; the server bounds a message at 8 MiB (`Helyx.Session.Turn`) | | the server |
| the text of one frame | 1,611,661,312 bytes, 38,797,312 values (each value and each object key), integers of at most 1,024 characters with the sign, finite floats: the outbound decode bounds of `docs/features/wire-protocol.md` | a break | `json::decode` (`json::WIRE`) |
| the nesting of one frame | 1,024 levels of arrays and objects. Not a bound of the wire: the parse, the clone, and the drop of a value recurse, so it bounds the stack of the client (1,024 levels ran on a thread of 2 MiB in a debug build, review of cycle A). A frame within the wire bounds can be deeper only in the arguments of a tool call, the request of an ask, or an answer. Open, accepted: the core breaks on such a frame, and the TUI decodes it, so a session that holds one cannot be shown by the core; no ticket, as the owner allows none for #860 | a break | `json::decode` |
| the memory of one decoded frame | grows with its values and the text of its strings, within the two bounds above; not measured | | `json::decode` |

## Ownership

None: the core holds no socket, file, timer, or process. The host owns the socket; `Client::closed` tells it whether to open another.

## Out of scope

- The iOS app, the Android app, and the web client: follow-up tickets (the web client is a Phoenix client).
- Hub auth: after #869.
- A client extension point.
- Any server change.
