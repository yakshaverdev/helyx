# Review: client kit, slices 1 and 2 (#860)

Scope: the precommit gate for `clients/*/Cargo.toml`, `rust 1.99.1` in `.tool-versions`, and the sans-I/O crate `helyx-client-core` (`docs/features/client-kit.md`). Base `a33d8334`.

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer` (it reads `lib/` only; the crate is in `clients/rust/core/src`).

## Round 1 (full)

Simplify, standards, spec, failure path, and Codex.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | failure path, spec F2 | An event with a duplicate, older, or skipped `seq` reached the state (a duplicate message; a lower `seq` sent in `after`). Reproduced. | Fixed: `State::apply` breaks on an event whose `seq` is not the next one and changes nothing; `tests/fold.rs`. |
| 2 | failure path, spec F5 | `{snapshot: null, replay: []}` passed as a replay. Reproduced. | Fixed: both keys read alike, exactly one present; `tests/checks.rs`. |
| 3 | Codex | An integer above `u64` in a tool call lost precision in `serde_json`. Reproduced by reading the default decode. | Fixed: `arbitrary_precision`; a 100-digit integer test. |
| 4 | spec F4 | A replay that crosses a multiple of 1,024 gave no ack. Reproduced. | Fixed: `ack(sub, from, to)`. |
| 5 | spec F5, failure path | A second `welcome` gave `Welcome` again. Reproduced. | Fixed: a `Done` phase; `tests/checks.rs`. |
| 6 | spec F2 | A user `message_start` opened the partial; the TUI streams only an assistant message. Reproduced. | Fixed, with a test. |
| 7 | spec F3 | A tool result with no `tool_call_id` passed; the TUI breaks on it. Reproduced. | Fixed, with a test. |
| 8 | standards 1 | No tests at the bounds of the nonce, the `res` id, and `int`. | Added, `tests/checks.rs`. |
| 9 | standards 2, 3 | The open transcript row had empty cells; AGENTS.md said every step prints seconds. | Doc fixed. |
| 10 | spec F1, F6, F7 | Block models and the fallback text not addressed; "each slice a commit". | Doc: protocol 3 has no UI block, so the block models wait for that protocol; slices 1 and 2 are one commit; slice 2 is partial (no connection). |
| 11 | standards 4–7, smells | `check` public; unused `res_id` and `Message::text`; the event type list repeated the match with a catch-all to `ask_end`. | `check` is crate-private with `Broken` and `Checked` re-exported; the unused functions removed; the match is explicit. Kept: the repeated `tool_call` type check (the delta path needs it), unanchored `target/` (no tracked folder of that name), the tuple of the error code and text (judgement call). |

Guarantee table of the spec agent: every row has a test or a probe, but the host toolchain (checked by the author over ssh, `cargo 1.99.1`, clippy 0.1.99, rustfmt 1.10.0 through `mise exec`) and the 128-level nesting of `serde_json` (a slice 3 bound, stated as not built).

## Round 2 (reduced: spec and failure path)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | spec D1, failure path 1 | A snapshot partial of a user or tool-result message became the partial and took deltas; the TUI breaks on it (`decode.ex`, `partial/1`). Reproduced. Second finding on the partial. | Mechanism fixed at the boundary: `Snapshot::parse` breaks on a partial that is not an assistant message; with the `message_start` rule, the partial is only ever an assistant message. Test in `tests/checks.rs`. |
| 2 | spec D2 | A tool-result `message_end` joined the transcript with no call id; the TUI ignores it. Reproduced. | Fixed: `message_end` follows the TUI by role. Test in `tests/fold.rs`. |
| 3 | spec D3, failure path | After a broken handshake frame, the next frame was taken. Reproduced. Second finding on the handshake phase. | Mechanism fixed: any break ends the handshake (`Phase::Done`). Test in `tests/checks.rs`. |
| 4 | failure path (no finding) | A replay or live events of another instance change nothing and raise no break, so the state can freeze. | Kept: the TUI does the same; the reconnect of slice 3 owns it. |
| 5 | spec | `precommit-run.sh`: "every step runs; the last line names each failed step" has no test. | The round 1 standards and failure-path agents ran the script with a stub `mise`: every step ran, exit 1, the last line named each failed step. The precommit run of this commit runs it for real. |

Two findings on one mechanism, so round 3 is a full round.

## Round 3 (full: simplify, spec, failure path, Codex)

Simplify moved a snapshot helper of the tests to `core/tests/common/mod.rs`. The reproductions of round 2 hold fixed. Round 3 reproduced four defects. They are open: the loop is at its limit of three rounds, and the small-fix round does not apply (the fixes touch more than one file, and two are second or third findings on one mechanism). The commit holds the code as round 3 reviewed it.

| # | Source | Finding | State |
|---|---|---|---|
| 1 | spec | A snapshot whose `messages` hold a tool result with no `tool_call_id`, or with an id of no earlier call, passes and joins the transcript; the TUI breaks on both (`decode.ex` `snapshot!`, `view_model.ex` `Map.fetch!` of the open call). Third finding on the role and pairing rules of messages. | Open. The fix is in `Snapshot::parse`: each tool result needs the call id of an earlier assistant call. |
| 2 | failure path | `refused` with `server_protocol` 3, the protocol of the client, gives `Refused(3)`; O1 and the protocol rule allow a refusal of another protocol only. | Open. A break when `server_protocol` equals `PROTOCOL`. |
| 3 | failure path | A replay that holds an event of another instance passes with that event skipped, and a replay to a state with no snapshot (no `after` sent) passes and leaves the state empty. The replay comes from the ring of `after.instance_id`, so both are breaks. | Open. The rule "another instance changes nothing" fits live events only; a replay needs the instance of the state and a snapshot before it. |
| 4 | Codex | With `arbitrary_precision`, the `Value` decoder of `serde_json` 1.0.154 reads an object whose only key is `$serde_json::private::Number` as a number, so a tool call argument of that shape changes, or a tool call whose arguments are that object breaks. Read in the source of the pinned crate; not run. Second finding on the integer precision of round 1. | Open. The mechanism needs a lossless decode of the host (slice 3), not the feature of `serde_json`. |

Not reached by the budget: frames split into parts, the results of `history` and `sessions.live`, the size bounds of slice 3.

# Cycle A: the four open defects (#860, owner decision of 2026-11-06)

Base `6e1e06d5`. The fix passes 100 code lines (a decoder of about 400 lines, the pairing, the TUI change), reported before round 1. Bounds sensor (base `HEAD`, before the round 1 fixes): `bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer`.

Decisions: the client enforces the shape and the bounds of each frame, and only renders the pairing of tool results ("Pairing" in the feature doc); a `refused` of the client's protocol, an event of another instance, and a replay with no snapshot are breaks by the wire doc; the core decodes JSON itself, losslessly; the transcript has the bound of the TUI view model, none of its own.

## Round 1 (full: simplify, standards, spec, failure path, Codex)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | spec, failure path, Codex | A `cost` of `-0.0` was a break; the server's `>= 0` check passes it and Elixir encodes it as `-0.0`. Reproduced. | Fixed: compared by value; test `a_cost_of_signed_zero_is_zero`. |
| 2 | Codex | A tool call block of a user message opened a call in `transcript::rows`, so it took the result of an assistant call. Reproduced by reading; the test fails before the fix. | Fixed: only an assistant message opens calls; test. |
| 3 | spec (unproven claim) | "As the decoders of the server do" for the last pair of a key: the decoders of Elixir keep the first (probed). | Fixed: the lookup takes the first pair. |
| 4 | spec (unproven claim) | "No provider is known to send" nesting over 1,024 levels had no source. | Doc: stated as an open, accepted hole with the stack probe. |
| 5 | standards | "Replaced mechanism" listed only the TUI items; a doc comment named 1,024 where the code reads the limit. | Fixed. |
| 6 | standards | The orphan arm of `rows` also caught a state that only a bug makes. | Fixed: `unreachable!`. |
| 7 | standards (judgement) | `object()` returns `&Json`; test helpers named `j` and `s`; the wire limits test repeats the numbers. | Kept: the numbers are the doc's, so the test pins them; the helpers are test-only. |

## Round 2 (reduced: spec, failure path)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | spec, failure path | An `int` written `-0` was a break (`as_u64` read digits only); `JSON.decode/1` reads it as 0, and the TUI and the server pass it. Reproduced. Second finding on one mechanism: a number judged by its text. | Mechanism fixed: both readers of a number, `as_u64` and `as_nonnegative_f64`, judge the value; the grammar of the decoder admits `-0` as the one signed integer zero. Test in `tests/checks.rs`. |

Fixes B (pairing) and C (first pair) held on every other path tried. Two findings on one mechanism, so round 3 is a full round.

## Round 3 (full: simplify, spec, failure path, Codex)

Simplify brought `json.rs` to 400 lines. The `-0` reproduction holds fixed; the core and the TUI agree on every number form probed (`-0`, `-0.0`, `-1e-400`, `-5e-324`, `1E2` and `1.0` as an int, `1e400`, integers of 1,024 and 1,025 characters). Codex: approve, no finding. No defect reproduced, so the loop ends.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | spec | The TUI checks a usage with `Helyx.Usage.valid?/1`, beyond the schema; the core takes those values. Not a break of the invariant (the core never breaks where the TUI takes a frame). | Doc: a Bounds row states the difference. |
| 2 | failure path | An `int` above 2^64 − 1 is a break in the core and taken by the TUI. The Bounds row stated the `u64` bound. | Doc: the row now states the difference. |

## Small-fix round (reduced: spec, failure path)

Precommit failed on `Helyx.Credo.FileLength`: `view_model.ex` had 405 lines. The fix rewrote the `add_cells` clause of a tool result as a guarded clause and an orphan clause, and inlined the orphan text: 399 lines, one file, no function or return shape changed. Spec and failure path: no defect; the snapshot path and the live path give the same cells for an orphan, a nil id, a closed call, and two calls of one id.

# Cycle B: slice 3, the connection (#860)

Base `8c5eb3d7`. Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full: simplify, standards, spec, failure path, Codex)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | failure path, Codex | An `unsubscribe` reply cleared the session by name: after a `session_end` and a new subscribe, it ended the new subscription, cleared the following of a subscribe on the way, and let `forget` drop a state that a later reply then needed (panic at an `expect`). Reproduced. | Mechanism replaced (below). |
| 2 | standards, spec, failure path | The `again` flag of `instance_changed` outlived its subscription: after a reconnect or an unsubscribe, a later `session_end` sent a subscribe that no one asked for. Reproduced. Second finding on the following flags. | Mechanism replaced. |
| 3 | Codex | A resubscribe refused as `Busy` at a `session_end` was dropped, and a reconnect skipped the session. Reproduced by reading. | Mechanism replaced. |
| 4 | spec | A snapshot with an `instance_id` over the request size made the welcome panic (`expect` of room). Reproduced. | Fixed: the subscribe leaves out `after`; test. |
| 5 | standards, spec | Untested: a frame over 1 MiB, a reused `sub`, a `session_end` of no sub, `TooLarge` through `request`, `NotSubscribed`, no ack for a snapshot, a request before the welcome. | Tests added. |
| 6 | standards | The challenge row had an empty cell; `Connection` was fields that `Client` reached into; `Joiner` public. | Doc fixed; `live_sub` and `attached` moved into `Connection`; `Joiner` crate-private. |

The mechanism: the stored flags `following` and `again` are replaced by one stored intent, `wanted`, with `renew` for `instance_changed`. Whether a session has a live subscription or a subscribe on the way is read from the connection. One function, the pump, sends each due subscribe after every input, so the welcome, a freed place, a `session_end`, and a renewal all take one path. An `unsubscribe` request names its sub, and its reply ends only that sub. `forget` refuses a session with a subscription or a subscribe on the way. A session is never subscribed while a subscription of it lives. Round 2 is a full round (two findings on one mechanism).

## Round 2 (full: simplify, spec, failure path, Codex)

The reproductions of round 1 hold fixed. Simplify made `connection` private.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | spec | After a `timeout` reply the server still holds the place, so a subscribe could get `busy`; that cleared the intent and gave the host a reply of an id it never had. Reproduced. | A refused subscribe gives `Output::Unfollowed` with the session and the error; the Bounds row states the `timeout` case. |
| 2 | spec, failure path | A renewal was set on a live subscription that already followed the new instance (the `history` page named the old one), so its later `session_end` subscribed again. Reproduced. | A renewal needs the page's `instance_id` to be that of the state; the request keeps it. |
| 3 | spec, Codex | An old `session_end` of an unsubscribed sub cleared a newer subscribe of the host that waited for it. Reproduced. | A `session_end` of a sub with an `unsubscribe` in flight leaves the intent. |
| 4 | failure path, Codex | A late `instance_changed` after an `unsubscribe` followed the session again. Reproduced. | A renewal needs a wanted session; the "subscribe at once after the end" rule is dropped (the host follows again). |

The intent rules moved to `follow` (`follow::Session`), which owns `wanted` and `renew` and decides each change of them. Round 3 is the last round of the cycle.

## Round 3 (full: simplify, spec, failure path, Codex)

Simplify added test helpers. The reproductions of round 2 hold fixed. Round 3 reproduced two defects on the follow intent. The cycle is at its limit of three rounds, and the small-fix round does not apply (a further finding on one mechanism), so the commit holds the code as round 3 reviewed it, and both stay open:

| # | Source | Finding | State |
|---|---|---|---|
| 1 | spec, failure path, Codex | An `unsubscribe` answered with an error (`busy` after a `timeout` frees a place in the client but not in the server, or `timeout`) leaves its subscription live with the intent cleared: events still apply, `forget` refuses, and the host gets no output. `unknown_sub` also leaves the sub in the client. | Open. The fix: give the host an output for a refused `unsubscribe`, and drop the sub at `unknown_sub`. |
| 2 | spec, failure path | `unsubscribe` is refused (`NotSubscribed`) for a wanted session with no live subscription: before the welcome, after a close, or with its subscribe in flight; the pump then subscribes it, against the host's latest intent. | Open. The fix: `unsubscribe` clears the intent whatever the connection holds, and sends the `unsubscribe` only for a live sub; a subscribe reply of an unwanted session sends one. |
| 3 | failure path (doc) | The Bounds row says a renewal takes a place; it needs a wanted session, so it takes none. | Open, doc only. |

Not reached by the budget: a host session id over 26 MB, a `failed` reply to `unsubscribe`, a reply that breaks a subscribe while a renewal is set.

# Cycle C: slice 4, the GPUI macOS app (#860)

Base `2904efd2`. Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`. Before the build: GPUI 0.2.2 needs `pkg-config` and the X11, Wayland, and font dev packages on Linux, and the host has none (`dpkg-query`, 2026-11-06); on this Mac it builds with `runtime_shaders` in 1 m 52 s, as Xcode here has no Metal toolchain.

## Round 1 (full: simplify, standards, spec, failure path, Codex)

The round 1 fixes pass 100 code lines (the waits of `net`, the token type of the core, the gate), stated here before round 2.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Codex | The derived `Debug` of `Client` and `Handshake` held the token, so a `Debug` of `Shared` printed it. Reproduced. | `handshake::Token`, whose `Debug` is `Token(..)`; tests in the core and the app. |
| 2 | Codex | The list count came from one read of the rows and the drawn rows from another: a shorter state between them panicked at an index. Reproduced by reading. | The count and the rows are one snapshot in `render`. |
| 3 | standards, spec, failure path, Codex | Pings before `welcome` held the 5,000 ms wait open. Reproduced. | The wait is checked at each frame; test. |
| 4 | failure path | The upgrade had a 5,000 ms bound for each read, not in all (one byte each 400 ms held it). Reproduced. | A watchdog shuts the socket down at 5,000 ms. |
| 5 | spec | `refused` was overwritten by "the connection ended". Reproduced. | It keeps its line; test. |
| 6 | spec | No pause between reconnects (1,939 connections a second). Reproduced. | 1,000 ms. |
| 7 | spec | A frame over the bound reconnected; and `broken` returned the `Reconnect` of the core for a break that only the socket saw. Reproduced. | A break stops; a reset with no close frame stays a lost connection; test. |
| 8 | spec | A missing data folder gave a read error, not "no server". Reproduced. | Fixed; test. |
| 9 | failure path | A server that stalls after the welcome is not ended. Reproduced. | A 45,000 ms silence rule ends a server that is gone; a server that pings and never replies stays open, accepted in the doc. |
| 10 | spec | The host gate built the app's `settings` and `net`, against the owner's "the host gate runs only the core". | `macos-only` and the gate; the app is checked on the Mac. |
| 11 | standards | No Unix mode refused nothing; untested bounds; a mutex poisoned by a panic of the thread panicked the window. | Refused; tests added; the window takes the poisoned lock. |
| 12 | standards (judgement) | The symlink swap between the stat and the open; the duplicated `closed` lines; `Unfollowed` not shown. | Kept: the swap needs write access to a folder that only the user can write (doc); the rest are judgement calls. |

## Round 2 (reduced: spec, failure path)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | spec, failure path | The watchdog of the upgrade that round 1 recorded was not in the code (the edit did not apply after a format) though the doc claimed it; a `101` one byte each 400 ms held the upgrade for 20 s. Reproduced. | Mechanism replaced (below); test. |
| 2 | spec, failure path | A frame that comes a byte at a time held a read open past the wait for `welcome`, and past the silence rule. Reproduced. Second finding on the waits. | Mechanism replaced; test. |
| 3 | failure path | A batch of writes had a bound only for each write call: a slow reader held a send of 3 MB for over 15 s. Reproduced. | Mechanism replaced. |
| 4 | spec | A text frame that is not UTF-8 reconnected. Reproduced. | A break; test. |

The mechanism: the waits of a connection were bounds for each read and write call, checked between frames. Now every wait after the connect is one deadline of the socket, held by a watchdog thread of the connection (`net::Watchdog`) that shuts the socket down when it passes, whatever call is in progress. Round 3 is a full round.

## Round 3 (full: simplify, spec, failure path, Codex)

Simplify made `send` restore the deadline it found, and added a test helper. The reproductions of round 2 hold fixed: the slow `101` (5,000 ms), the slow frame before `welcome`, the slow reader of a 3 MB send (shut at 5.2 s), and a text that is not UTF-8. The failure-path agent found no defect: no watchdog outlives its connection, none acts on another socket, and a welcome at 4,950 ms is taken. Round 3 reproduced a defect on the waits again, so the cycle ends at its limit; the small-fix round does not apply (a third finding on one mechanism). The commit holds the code as round 3 reviewed it, and these stay open:

| # | Source | Finding | State |
|---|---|---|---|
| 1 | spec (reproduced), Codex | A batch of sends sets the deadline to 5,000 ms from its start, and the next batch can start from a restored deadline that has passed: with sends queued from 41 s, a silent server held the socket for 61 s and 76 s, past the 45,000 ms of the Bounds row. | Open. The fix: a batch takes the earlier of the deadline it finds and its own, and a passed deadline ends the connection before the next batch. |
| 2 | Codex (by reading) | `tungstenite` keeps a binary frame that is not final without returning it, so the stop of a binary frame does not run; a close after it reconnects, and pings keep the silence wait open. | Open, not reproduced. The fix: refuse a binary opcode at its first frame. |
| 3 | spec (doc) | The Ownership row says the thread sends a close at a wait over its bound; the watchdog shuts the socket down and sends none. | Open, doc only. |
| 4 | spec (no proof) | The TCP connect bound of 5,000 ms and the watchdog thread's end within 100 ms of its drop have no test (the failure-path agent saw the thread count fall back after each connection). | Open. |
