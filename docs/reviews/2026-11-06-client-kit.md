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
