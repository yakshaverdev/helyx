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

The ticket is built in this order. Each slice passes the gate; slices 1 and 2 are one commit.

1. **The gate.** `.tool-versions` pins `rust 1.99.1`. `.claude/skills/ship/precommit-run.sh` runs `mix precommit`, then, for each `clients/*/Cargo.toml`, `cargo fmt --check`, `cargo clippy --locked --all-targets -- -D warnings`, and `cargo test --locked` through `mise exec`. `precommit.sh` runs that file here or on the host. Every step runs; the last line names each step that failed.
2. **The protocol core** (`clients/rust/core`, crate `helyx-client-core`). It does no I/O: a host feeds it the decoded JSON of each server frame of one connection, and sends the frames it returns.
   - `handshake`: `challenge` (a nonce of exactly 32 bytes), `hello` with `proof = base64(HMAC-SHA256(SHA-256(token), nonce))` or no proof with no token, then `welcome` of protocol 3 or `refused` with the server protocol. Any other frame or order is a break, and after a break, `welcome`, or `refused`, every frame is a break.
   - `frame` and `event`: `res` read by the op of its request (a `res` of no request in flight is a break), `event`, and `session_end`, each checked by the schema of `docs/features/wire-protocol.md`. An event of an unknown type is skipped with its envelope checked; a known type with a broken shape is a break. As in the TUI, a tool result of `tool_execution_end` must have its `tool_call_id`, and `queue_dropped` and `steer_unconfirmed` carry user messages only. A `subscribe` result has exactly one of `snapshot` and `replay`. The crate turns on `arbitrary_precision` of `serde_json`, so a host that decodes with it keeps an integer of a tool call exactly, at its 100 digits too.
   - `fold`: the state of one subscription, by the rules of `test/fixtures/wire/README.md`, "folds.json": a snapshot replaces it, a replay applies its events, an event applies. An event of another instance changes nothing, as in the TUI. An event of the instance whose `seq` is not the next one, a duplicate, an older one, or one after a gap, is a break of O4 and changes nothing; the TUI drops an older one instead, so the core is stricter. Only an assistant message is a partial that deltas stream into: a snapshot whose partial has another role is a break, as in the TUI, and a `message_start` of another role opens none. A `message_end` adds a user or an assistant message, and an assistant one ends the partial; a tool result joins the transcript at `tool_execution_end` only, as in the TUI. `subscribe_params` adds `after` of the last applied event. `ack(sub, from, to)` gives the `ack` frame when a frame moved the `seq` past a multiple of 1,024, the cadence of the TUI, so a replay that crosses one acks too.
   - Tests: `core/tests/fixtures.rs` runs every case of `server_frames.json` (handshake, `res`, `event`, `session_end`) and of `folds.json`; `core/tests/fold.rs` checks the rules the fixtures do not pin; `core/tests/checks.rs` checks the bounds of the table below.
3. **The connection** (not built): WebSocket I/O, parts, the outbound decode bounds, the ping, and the reconnect with `after` on a lost connection, on `instance_changed`, and on the `4408` slow close. The ticket names these as part of the wire client, so the wire client of slice 2 is partial: it has the frames and the fold, not the connection.
4. **The GPUI macOS app** (not built): session list, session view, block renderers, settings, push. GPUI may need system packages on the Linux host for `cargo clippy` and `cargo test`; they are listed here when slice 4 adds the app.

## Interface changes

- New: the Cargo workspace `clients/rust/` and the crate `helyx-client-core` (`publish = false`).
- `.claude/skills/ship/precommit.sh` runs `precommit-run.sh` instead of `mix precommit`; `.tool-versions` gains `rust 1.99.1`. The rsync to the host leaves out `target/`, so the build cache of the host stays between runs.
- Host setup, done once on 2026-11-06: `mise exec` installed `rust 1.99.1` with the minimal profile, without clippy and rustfmt, so `mise exec -- rustup component add clippy rustfmt` ran on the host. On the Mac, the same toolchain has both. No system package is needed for slices 1 and 2.
- No server change, no wire change.

## Replaced mechanism

None. The TUI keeps its own client and view model in Elixir; the Rust core is a second client of the same fixtures.

## Bounds

The core holds a frame that the host decoded; the bounds of a frame belong to the connection of slice 3.

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| `nonce` of `challenge` | exactly 32 bytes after base64 | a break | `handshake` |
| `id` of a `res` | 1 to 64 bytes, and the id of a request in flight | a break | `frame::parse` |
| an `int` of the schema | 0 to 2^64 − 1 (`u64`); the server sends far smaller | a break | `check::int` |
| unacked events of a subscription | an `ack` after each frame that moves the `seq` past a multiple of 1,024, far below the 16,384 of the `:slow` end | the server closes with `4408` | `fold::ack`, sent by the host |
| `seq` of an event | the `seq` of the state plus one | a break | `fold::State::apply` |
| the transcript of the state | unbounded: a snapshot holds the tail, and each `message_end` and `tool_execution_end` adds one message, as in the TUI view model. No ticket: the owner allows no new ticket for #860, and the report of #860 names it | the state grows with the session | none |
| a partial message | grows by each delta; the server bounds a message at 8 MiB (`Helyx.Session.Turn`) | | the server |
| the decoded frame | the outbound decode bounds of `docs/features/wire-protocol.md` (1,611,661,312 bytes, 38,797,312 values, integers of 1,024 characters): not built, slice 3. A nesting deeper than 128 levels fails the default `serde_json` decode | | slice 3 |

## Ownership

None in slices 1 and 2: the core holds no socket, file, or process. Slice 3 adds the socket.

## Out of scope

- The iOS app, the Android app, and the web client: follow-up tickets (the web client is a Phoenix client).
- Hub auth: after #869.
- A client extension point.
- Any server change.
