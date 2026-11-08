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

## The owner's rule on the app gate

The window of the app builds on macOS only, and the merge gate on the Linux host leaves it out (`clients/rust/macos-only`). The orchestrator's judgement of 2026-11-06: the owner's rule stands, and the orchestrator tells the owner that the merge gate does not build the app.

# Cycle D: the follow intent (#860, judgement of the orchestrator of 2026-11-06)

Base `cce1d0fb` (the branch after the rebase on `origin/master`). The open items 1 and 2 of cycle B round 3. Chosen mechanism: the intent that the host states is the state, and only the host changes it; `subscribe` and `unsubscribe` set it, are never refused but by the cap of 16, and can be stated again. The client reconciles each session after each input (`reconcile`). An error answer leaves the intent and reports the server state to the host (`Output::Failed`, `Client::subscribed`), and holds the session on that connection, so a refusing server gives no request loop; a restatement of the host or a new connection ends the hold. `unknown_sub` marks the subscription gone. Accepted with its source: no deadline for a reply (#834, `docs/features/tui-attach.md`, decision 17).

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full: simplify, standards, spec, failure path, Codex)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | standards, spec, Codex | After a `session_end`, a subscribe went while the `unsubscribe` of the session waited: two requests of one session in flight, against the Bounds row. Reproduced. | The pump skips a session with a subscribe or an `unsubscribe` in flight; the tests wait for the reply. |
| 2 | standards, spec, failure path, Codex | A renewal lifted the hold of a refused subscribe, so a subscribe went with no restatement. Reproduced. | A hold has its reason (`Hold::Ended`, `Hold::Refused`); a renewal ends only an end hold; test. |
| 3 | spec | The cap counted wanted sessions, not the subscriptions that the server holds: with an unsubscribed sub live, a 17th subscribe went and got `too_many_subscriptions`. Reproduced. | A subscribe goes while the live subscriptions and the subscribes in flight are under 16; test. |
| 4 | spec, failure path | A subscribe reply with a sub id in `gone` was taken, and its frames dropped. Reproduced. | A break; test. |
| 5 | failure path | `held` kept the entries of forgotten sessions. Reproduced. | `forget` drops the hold. |
| 6 | failure path | A session id over the request size took a place and was skipped at each input with no report. Reproduced. | `subscribe` refuses it (`Refusal::TooLarge`); an `unsubscribe` too large for its sub id holds the session; test. |
| 7 | standards, spec (doc) | "Oldest session id first" (the order is the byte order of the ids); the no-deadline row too broad for `start` and `resume`. | Fixed. |
| 8 | standards (judgement) | `reconcile` widens fields to `pub(crate)`; `Output::Failed.op` a string; the `unknown_sub` handler needs evidence. | Kept: `reconcile` owns the decision of which requests go. The server sends `unknown_sub` (`plugins/bundled/lib/helyx/transport/web_socket/connection.ex`), and an `unsubscribe` after a `timeout` that took effect gets it. |

Round 2 is a full round: the mechanism had findings in cycle B.

## Round 2 (full: simplify, spec, failure path, Codex)

The reproductions of round 1 hold fixed.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | spec, Codex | A `session_end` replaced a `Refused` hold with an `Ended` one, which a renewal then lifted: a subscribe with no restatement. Reproduced. Second finding on the hold. | A `session_end` keeps a `Refused` hold; test. |
| 2 | spec, failure path | A refused `unsubscribe` of a session forgotten meanwhile left a hold with no state. Reproduced. | No hold for a forgotten session; test. |
| 3 | failure path, Codex | A late `unsubscribe` reply removed, or marked gone, a sub id that the server gave again to another session after an end. Reproduced. | The reply acts only on a sub that is still that of its session; test. |
| 4 | spec (doc) | An `unsubscribe` too large for its sub id is held with no report, unlike an error answer; the no-deadline row named server deadlines that the wire doc and the server code disagree on. | Doc fixed. |
| 5 | spec | The app dropped a refused follow with no word. | The app's line says so. |

Round 3 is a full round.

## Round 3 (full: simplify, spec, failure path, Codex)

Simplify merged two arms of `unsubscribed`. The reproductions of round 2 hold fixed. Codex: approve, no finding. A random walk of the failure-path agent (400 seeds of 600 steps against a model of the server) found no two requests of a session in flight, no 17th subscription, no request of a held session, no loop, and no panic. Round 3 reproduced two defects on the hold, so the cycle ends at its limit; the small-fix round does not apply (a further finding on one mechanism). The commit holds the code as round 3 reviewed it, and these stay open:

| # | Source | Finding | State |
|---|---|---|---|
| 1 | spec, failure path | A `busy` to an `unsubscribe` that comes after the `session_end` of its sub holds a follow that the host stated after the end, a forgotten and followed-again session too: the subscribe does not go until the host states it a third time. | Open. The fix: hold only when the sub of the reply is still that of the session (`ours`), as for `ok` and `unknown_sub`. |
| 2 | spec | With 16 live subscriptions, one of them of a session whose `unsubscribe` was refused, a new wanted session waits for a place that no reply frees, with no report to the host. | Open. The fix: report the wait, or count the place of a refused `unsubscribe` to the host. |
| 3 | spec (doc) | "A sub id that the server gave again to another session after an end stays live": the server never gives a sub id again (`next_sub` only grows, `plugins/bundled/lib/helyx/transport/web_socket/connection.ex`). The guard holds for a server that breaks the contract. | Open, doc only. |

# Cycle E: the waits of the app socket (#860, judgement of the orchestrator of 2026-11-06)

Base `7390fc43`. The open items 1, 2, and 4 of cycle C round 3, and the doc item 3. Reproduced first: an unfinished binary frame (`02 01 78`), then pings and a close, reconnected instead of stopping (test `an_unfinished_binary_frame_is_a_break` failed with `could not connect …`). Choices: the read deadline is an instant that only a frame read moves, and a batch of sends has a deadline of its own, both held by the watchdog (`socket::Watchdog`); a tap on the socket marks a binary frame at its first frame (`socket::Tap`); the close frame at a watchdog shutdown: the doc is fixed, no frame is sent, because a write of the app can be in progress and a frame in its middle would break the stream. Tests: the silence while sends stall, the TCP connect to a full backlog (on this Mac the 129th local connect times out), and the end of the watchdog thread. The waits became `socket::Waits`, so the tests run with short waits.

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full: simplify, standards, spec, failure path, Codex)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | failure path | An HTTP reply with bare `\n` line ends, or empty lines before its status line, kept the tap in HTTP or put it off the frame bounds, so a binary frame went unmarked; `httparse` takes both. Reproduced. | The tap ends the reply by the rules of the parser; unit tests of the three forms. |
| 2 | failure path | A text frame in the same read as a binary header was dropped. Reproduced. | At a binary frame the tap gives only the bytes before it; the flag is checked before each read and after a failed one; test. |
| 3 | Codex (by reading) | Continuation frames with no ping kept `ws.read()` from returning, so the flag was not checked until the silence. | The tap fails every read after a binary frame; test with continuations and no ping. |
| 4 | standards, spec | The send deadline had no test. | Test: a stalled batch ends at it; an ended batch clears it. |
| 5 | spec | "Ends within 100 ms": the test allows 2.1 s, the probe measured 102 ms. | Doc: at its next check, one poll and the wake-up. |
| 6 | spec (doc) | The challenge row named `net::connection` and a close. | Fixed. |
| 7 | standards (judgement) | The binary arm no input reaches; `live_watchdogs` a test counter in code; frame-length tests. | The arm stays with a comment; the counter stays, `#[doc(hidden)]`; unit tests of the tap cover 0 to 70,000-byte frames in reads of 1 byte to 200,000. |

## Round 2 (reduced: spec, failure path)

The reproductions of round 1 hold fixed. The failure-path agent compared the end of the HTTP reply with `httparse` 1.10.1 over 100,000 random replies (the same byte for each of the 11,705 complete ones) and the frame bounds over 3,000 random frame sequences in reads of 1 to 9 bytes (no false mark).

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | spec, failure path | The check of the binary mark before each read dropped the frames that `tungstenite` still held: a ping, a text frame, and a binary frame in one write lost the text. Reproduced. Second finding on the stop of a binary frame. | The check runs only after a failed read: the tap fails a read only when the frames before the binary one are taken; test. |
| 2 | spec | The send-deadline test passed with `Watchdog::sending` a no-op: the write timeout ends a fully stalled batch too. Reproduced by the mutant. | The test reads 16 KiB each 20 ms, so writes go on and only the send deadline ends the batch; it fails with the mutant (checked). |

Round 3 is a full round.

## Round 3 (full: simplify, spec, failure path, Codex)

Simplify split the deadline tests into `tests/deadlines.rs` with a shared stub module, and added tap tests of a final binary frame and a masked frame. The reproductions of round 2 hold fixed, and the send-deadline test fails against the no-op mutant. The failure-path agent checked 14,691 two- and three-way splits of HTTP, ping, text, close, fragment, masked continuation, and binary bytes: the tap marked each and gave exactly the bytes before the binary frame. Round 3 reproduced defects on the stop of a binary frame again, so the cycle ends at its limit; the small-fix round does not apply (a further finding on one mechanism). The commit holds the code as round 3 reviewed it, and these stay open:

| # | Source | Finding | State |
|---|---|---|---|
| 1 | failure path (reproduced 8 of 8), Codex | The welcome and a binary frame in one write: the tap marks the binary frame, the welcome is taken, and a send that then fails (its deadline, a reset) ends in `lost`, which reconnects; the mark is checked only after a failed read. | Open. The fix: check the mark in `lost` too, so a send failure after a mark stops with the break. |
| 2 | spec (reproduced 10 of 10) | `tungstenite` flushes a pending pong at the start of a read; a failed flush fails the read while a text frame is still buffered, and the mark then stops the app with that frame lost. | Open. The fix: stop on the mark only when the tap itself failed the read. |
| 3 | spec (doc) | The silence row says "a frame that comes a byte at a time counts from its start"; the silence counts from the last frame read before it (shut 1,018 ms after it, 418 ms into the slow frame, with a silence of 1,000 ms). | Open, doc only. |

# Cycle F: the frames that the schema allows (#860, judgement of the orchestrator of 2026-11-06)

Base `c652b055`. Items 4 and 5 of the judgement. `docs/features/wire-protocol.md` states no bound on the nesting of an outbound frame, only its values, so both clients decode any nesting within the values. Seen first, by the tests of the old rules: the core broke on 1,025 levels (`json::decode`, depth 1,024) and on an `int` of 2^64 (`as_u64` gave none), and the TUI on a usage of 10^16 tokens, a cost with no kind, a window of 0, a count of a compaction over 10^9, and a total cost over 10^300 (`decode_test.exs` had each as `:error`). Choices: the core keeps a container past 64 levels as its text (`Json::Deep`), checked with a stack on the heap; a `seq` is a big integer (`seq::Seq`), exact in the fold, the `after` of a subscribe, and the ack; another `int` past 2^64 − 1 reads as 2^64 − 1. The TUI reads a usage that `Helyx.Usage.valid?/1` does not take as the unknown usage, a total cost over 10^300 as 10^300, a window of 0 as no window, and a count of a compaction of any size, in integers. Fixtures: a frame of 1,029 levels, a notice and a fold past 2^64 − 1, usages and totals past the bounds of Core, and a negative cost as a break. Probe: with the expectation of each new case flipped, both runners fail (core: `res`, `event`, `folds`; TUI: the three same tests). The core runner reads the fixture files with the decoder of the core: `serde_json` reads an integer past 2^64 − 1 as a float, and its `arbitrary_precision` feature would reach the `serde_json` of gpui in a workspace test build. Also fixed: `docs/features/tui-attach.md` still had a tool result with no call id as a break, stale since cycle A. Open, not decided: the TUI checks beyond the schema that the judgement did not name (`docs/features/client-kit.md`, row "the values that the TUI checks beyond the schema").

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full: simplify, standards, spec, failure path, Codex)

Simplify shared the scalar grammar of the deep scanner with the tree parse (`scalar`), shared the integer rule of `as_u64` and `Seq::parse` (`json::natural`), merged the cost guards of the TUI decode, and kept `view_model.ex` at 400 lines. It found that `tests/client.rs` read `folds.json` with `serde_json` and failed on the new fold (a `seq` past 2^64 − 1 read as a float); the runner now reads the fixtures with the decoder of the core, and the helpers of both runners are in `tests/common`. Codex: approve, no findings.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | spec, failure path (both reproduced) | An `mtime` of `sessions.saved` of 2^64 or 10^24, which the schema allows and the decode takes, raised `ArgumentError` in `SessionList.line/2` (the local time of the calendar), in the Task of the list. | A time past 9999-12-31 23:59:59 UTC shows as `>9999-12-31`; test in `link_test.exs` (2^64, 10^1023, and the last second). |
| 2 | standards, spec | No test of the ack past 2^64 − 1. | `tests/fold.rs`: the ack of 2^64 carries every digit; the fold runner of `tests/client.rs` checks that each ack has the `seq` that the client holds. |
| 3 | standards, spec | No test that another `int` past 2^64 − 1 reads as 2^64 − 1. | `tests/checks.rs`, "an int past the largest u64 reads as the largest u64". |
| 4 | spec | No test that the footer counts totals and the context in integers. | `decode_test.exs`: counts of 10^1023 render `>999B` and `>999%`. |
| 5 | spec (doc) | Decision 14 said that no value of the schema past the bounds of Core is a break, while it keeps the blocks, the result text, and the origin as breaks; "the fixtures hold each" held only at the entry. | Decision 14 names what is read in a form; client-kit.md says the fixtures hold the entry and names the tests of the fold and the render. |
| 6 | standards (doc) | Replaced mechanism did not name two renamed tests; the sentence on the depth of `serde_json` did not parse. | Named; rewritten. |
| 7 | standards (judgement) | The test name "the bounds of Core that the fold trusts" no longer fits; `Seq` derived `Ord` and `Hash` with no use; two functions named `digits`. | Renamed the test; dropped the derives; `json::digits` is `json::natural`. |
| 8 | standards, spec (judgement) | The TUI still breaks on a model that is not a model ref, more than 1,024 blocks, a tool result text over 65,536 bytes, a tool-call integer of more than 100 digits, and an origin on a message that is not a user message, which the core shows. | Not decided: the judgement named the usage values and the integers only. The row states the reason, and the report to the orchestrator names it. |

Guarantee table of the changed contract texts:

| Guarantee | Test or probe |
|---|---|
| The core decodes any nesting within the values; past 64 levels a container is its text | `tests/json.rs`, "any nesting within the values decodes" (a million levels); fixture of 1,029 levels; probe (spec): a million levels through the fold, `transcript::rows`, clone, and drop |
| The TUI decodes any nesting | fixture of 1,029 levels; probe (spec, failure path): a million and 200,000 levels through `Decode`, `ViewModel`, and `CallLine` |
| A `seq` is exact in the fold, `after`, and the ack | `tests/fold.rs`, "a seq past the largest u64 counts on"; `folds.json`; `tests/client.rs`, the fold runner |
| Another `int` past 2^64 − 1 reads as 2^64 − 1; `-0` is 0 | `tests/checks.rs`, "an int past the largest u64 reads as the largest u64", "an int is any integer from 0" |
| The TUI reads a usage that `Usage.valid?/1` refuses as the unknown usage | `decode_test.exs`, "a usage that Core would not make is the unknown usage" |
| A total cost over 10^300 counts as 10^300, and the footer shows `>$99999` | `decode_test.exs`, "a value of the schema past the bounds of Core …" |
| A window of 0 is no window; counts of any size in integers, in the fold and the footer | the same test |
| An `mtime` past the year 9999 shows as `>9999-12-31` | `link_test.exs`, "a /resume line of a time past the year 9999 …" |

## Round 2 (reduced: spec, failure path)

The reproduction of round 1 holds fixed: an `mtime` of 2^64, 10^24, 10^1023, or 1,024 nines renders `>9999-12-31` in four time zones (UTC, Asia/Kolkata, Pacific/Kiritimati, America/Los_Angeles). The failure-path agent sent every int of a snapshot and of the events at 1,024 digits, costs from 5e-324 to the largest float, and windows of 0 and 1 through the TUI decode, the view model, the footer, and a draw. It sent arguments nested 10^7 levels through the TUI. In the core, in a debug build, it sent a `seq` across 2^64 with its ack, a `seq` of 1,024 digits and a reconnect with it, and a nesting at the value bound through `transcript::rows`. None crashed. No reproduced defect, so the loop ends.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | spec (doc) | client-kit.md says that the fixtures hold a count of a compaction over 10^9, and no fixture had one. | Fixture "compaction: counts past the bounds of Core, 10^9 + 1 and 2^64", valid. Both runners pass, and both fail with its expectation flipped (probe). |
| 2 | spec, failure path (judgement) | With `elapsed_ms` and the queue counts at 10^1023, the second footer row is about 6,250 characters, and the usage values fall past the screen. It does not crash, and no stated bound covers it. These checks did not change in this cycle. | Recorded. No change. |
| 3 | failure path (judgement) | East of UTC, the last second of 9999 UTC shows as its local time, `10000-01-01 05:29:59`, and the next second shows `>9999-12-31`: the cap is set in UTC. | Recorded. No change: it renders, and the test takes a year of 4 or 5 digits. |

Not reached by the budget: the gpui render of the app, deep frames over 1 MiB sent as parts through `Client::receive`, and the `history` result.

# Cycle G: the checks of the TUI beyond the schema (#860, judgement of the orchestrator of 2026-11-07)

Base `f289c4f8` (the branch after the rebase on `origin/master`). The judgement: "the schema is the contract" applies to the five checks of the TUI beyond the schema. Seen first, by the tests of the old rules: the TUI decode broke on a model that is not a model ref, 1,025 blocks, a tool result text of 65,537 bytes, an integer of 101 digits in a tool call, and an origin that Core does not make (`decode_test.exs` had each as `:error`). An accepted hole broke the new rule too: an `ask` of the `question` tool whose request the tool did not make crashed `Helyx.TUI.Question`; "an accepted hole may not break a written rule", so it is in this cycle. Choices, each a cut that keeps a render bound:

- The model: kept whole, so `/new` sends it as it is and the server judges it (a server of this build answers `bad_params` to a null model, so leaving it out is not an option); the footer and the line of a model change show its first 256 bytes, cleaned (`Footer.model/1`).
- Blocks: kept whole, so a call past the first 1,024 still takes its result; the rows and the search text of a message draw the first 1,024 and `[+N more blocks]` (`Transcript.Item`). The count walks the list of a message that a frame shows.
- A tool result text: the cut of Core (`Message.cut_result/1`) once, at the decode, as at each boundary of tool text; a cut in each frame would cost O(text) in each frame.
- An integer of any size in a tool call: shown as its text in the call line, within its cut of 8,192 bytes.
- An origin: the TUI shows none; it keeps one that Core makes on a user message and drops any other.
- A question ask: the picker shows only a request that the tool asks with (`Helyx.Tool.Question.request?/1`, a walk of at most 5 questions and 5 options of each); another shows no picker, as an ask of another tool.

Fixtures: eight valid cases in `server_frames.json`, one for each. Probe: with the expectation of each case flipped alone, both runners fail (8 of 8 in each). The library change is 96 lines added and 42 removed, past the 100 lines of the brief; the wider scope is the picker and `request?/1`.

Bounds sensor: `bounds sensor: 6 candidate functions, 1 flagged, 0 without an answer`, flag `view_model.ex:189 SIZE defp fold(vm, %Event{type: :model_change, data: data})` (the model kept whole in `vm.model`; finding 1 is the path where its size mattered).

## Round 1 (full: simplify, standards, spec, failure path, Codex)

Simplify renamed a helper, moved `Footer.model/1` beside `location/2`, and tidied two tests.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | failure path (reproduced on a local Core and WebSocket server) | A `model_change` of 27 MiB, then `/new`: the `start` request passed the 26,214,400 bytes of the server, which closed with `4413`, and the TUI ended. | `Link.open/3` does not send a model over the text bound of 4 MiB: `could not switch: the model is over 4 MiB`; test in `link_test.exs`, which fails without the clause. |
| 2 | failure path, spec (both reproduced) | `[+N more blocks]` counted the tool calls past 1,024, which still show as tool cells. | The cut counts only the blocks that no cell shows. |
| 3 | Codex (high, by reading; the failure path measured 3 to 50 ms a frame for 3M blocks) | The render cut walked the whole block list in each frame (`Enum.split` and `length`). | The cut moved to the fold (`Helyx.TUI.ViewModel.Cut`): it walks the message once, when it becomes a cell, and a frame draws at most 1,025 blocks of a cell. The streaming message gets the cut in each frame, which walks its blocks as the frame did before. |
| 4 | spec (reproduced), standards | The accepted hole "an event that the fold cannot apply … the result of a call that is not open" was stale since cycle A (an orphan cell), and hid a real crash: after a snapshot with no partial, a `message_update` with no `message_start` made the improper list `[block \| nil]`, and the render raised. | A delta with no `message_start` starts the streaming message; the hole is removed. Test in `decode_test.exs`, which raises without the fix. |
| 5 | standards | The bounded walk of `request?/1` had no test: `length/1` in its place passed. | Tests with a list that is not a list after its fifth item. |
| 6 | standards | The cut line of a user message and a tool result had no test. | Tests in `decode_test.exs`. |
| 7 | spec (doc) | `tui-attach.md` still said that tool-call arguments hold no integer over 100 digits; `wire-protocol.md` stated the cap with no note. | Both say that a client takes any integer. |
| 8 | spec (doc, from cycle F) | `coding-agent.md` said that an information cell text is at most 263 bytes; a compaction line of two counts of 1,024 digits is 2,076. | The row states 2,076, and 263 for the line of a model. |
| 9 | spec (doc) | `client-kit.md` said that both clients take every frame that the schema allows; both keep the role of the message of an event, which the fixtures fix and the schema cannot show. | The row names the role rule of the fixtures. Not decided here whether the judgement covers it: reported. |
| 10 | standards (doc) | Comments: "no block past the first is drawn"; the origin comment did not follow; an empty cell of the row. | Fixed; the first went with the cut in the fold. |
| 11 | standards (judgement) | The fold calls `Footer.model/1`, a render module that matches `%ViewModel{}`; `@model_bytes 256` copies the private bound of `Helyx.ModelRef`. | Kept: a runtime call, as the fold calls `CallLine` for tool cells; the attribute names its source. `view_model.ex` is at its 400 lines. |

## Round 2 (reduced: spec, failure path)

The reproductions of round 1 hold fixed: the `/new` test fails without its clause, the delta test raises without its fix, and the cut tests pass at 1,024, 1,025, and a message of only calls past 1,024. Both fixture runners agree. The failure-path agent ran twice: the first run died at the usage limit and the second was stopped by a kill; its folders were removed and the third run reported. The failure-path agent also folded these event orders with no crash: `turn_end`, `message_end`, a tool-call delta, and `message_start` with no start before them; `ask_end` of an unknown ask; and `tool_execution_end` twice.

Round 2 reproduced defects again, each a second finding on a mechanism that round 1 patched. The two-findings rule asks the next round to fix the mechanism, but the work of the cycle is past its 45 minutes. So the commit holds the code as round 2 reviewed it, and these stay open:

| # | Source | Finding | State |
|---|---|---|---|
| 1 | spec (reproduced on a local server) | A resume id or an ask id of 27 MiB, which the schema allows, ends the connection with `4413` when the TUI sends it back (`Link.open/3` with `{:resume, id}`, `Link.answer/3`); by reading, the same holds for the session id of every request, the `sub` of an ack, and the `instance_id` of `after`. The same class as round 1 #1, which bounded only the model. | Open. The mechanism fix: the connection checks the size of each frame that it sends against the request bound of the server and refuses it with no send, as the Rust core does (`parts::split`, `Refusal::TooLarge`). |
| 2 | failure path (reproduced) | The cut counts no tool call, as each has a tool cell; in a user message or a tool result a call has no cell and shows as a placeholder, so a call past 1,024 blocks there is lost with no count. `ViewModel.prompt/3` reads the cut cell of a user message, so the recall of a prompt of more than 1,024 blocks gives a shorter text. A second finding on the cut. | Open. The mechanism fix: count each block that the cell does not draw, by role, and keep the recall on the event message. Only a server of another build sends such a message: a user message of Core has one block. |
| 3 | spec (reproduced) | `coding-agent.md` states that a notice of a failed turn is at most 4,000 bytes; the decode takes any string, and a probe made a notice of 100,007 bytes. The `text` of a `notice` and the `provider` of `resume_id` reach notices uncut too. Not new in this cycle: the decode never cut them. | Open. The fix: the cut of `Helyx.Reason.text/1` at the decode, or the row restated. |
| 4 | spec (judgement) | The streaming message is reversed, split, and cut in each frame: O(blocks) for each frame, so a long stream of deltas costs O(n²) in all (6 ms a frame at 100,000 deltas). | Open, stated in the row of `tui-attach.md`. A count in the fold would bound it; `view_model.ex` is at its 400 lines. |
| 5 | spec (judgement) | The cut bounds blocks, not bytes: a collapsed tool cell joins and splits each block in each frame, up to 1,024 × 64 KiB. | Within the bounds of Core: a tool result has no total bound beyond the blocks of its message (`docs/features/wire-protocol.md`, "Bounds"). Recorded. |
| 6 | failure path (measurement) | A fold of one message of 100,000 tool calls takes about 1.1 s: one cell for each call, about 11 µs each. | No render bound covers the count of cells; the TUI cell list is unbounded by the rule of `coding-agent.md`. Recorded. |
