# Review: ticket #869, protocol 6 and the schema

Slice of #869: the wire goes to protocol 6. The schema of `docs/features/wire-protocol.md` gets the lines of `docs/features/hub.md`, "Wire schema additions (protocol 6)", without the lines marked `#870`; `@protocol` is 6 and `@schema_sha256` is the SHA-256 of the new block (`plugins/bundled/lib/helyx/transport/web_socket.ex`). The prose of wire-protocol.md gets the authority of a Hub at the `hello`, the close codes `4403` and `4503`, the codes of a Hub in the op table, the deadlines under a Hub, and item 12 of "Replaced mechanism"; the conformance fixtures name protocol 6 and get three cases; both clients of the build speak 6: the TUI (`Helyx.TUI.Wire.Decode` takes the five codes of a Hub, `Helyx.TUI.Link` has a text for each) and the Rust client core (`PROTOCOL`, `ERROR_CODES`).

The slice was first built as protocol 4 and reviewed in one full round (below). The rebase on master, which had gained protocol 4 (#880) and 5 (#878), made it protocol 6; master's #860 made the schema the contract of both clients, so a code of a Hub is no longer a contract break for a client: both take it. The fast-mode round of 2026-11-09 (owner) reviewed the rebased change.

Invariant: the schema block is the schema of protocol 5 plus the non-#870 lines of hub.md, and its SHA-256 is the constant next to the protocol number 6; every client of the build speaks 6 and takes every code of the schema, and a client of protocol 5 gets `refused` and `4426`; a server with no authority does not read the `token` of a `hello` and answers a `hub.*` op with `unknown_op`.

## Bounds sensor

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

## Round 1, as protocol 4 (full: simplify, standards, spec, failure path, Codex)

Simplify: tests that pinned the number 4 read `WebSocket.protocol()`; the `4401` row names the `token` of a Hub; tui-attach.md decision 13 says "a new protocol number" in place of "protocol 4"; the README names the Hub tests. It noted that the wait of the TUI client for `sessions.saved` (`Ops.deadline/1` plus 5,000 ms, 15,000 ms) has no margin left under a Hub, whose deadline is 15,000 ms: open for the slice of the `helyx serve` wiring, where the TUI first runs under a Hub.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Codex (high), standards | The fixture "hello with a token id" ran against a server with no token and sent a valid id, so it showed neither that the `token` is not read nor that the proof is still needed. | Fixed: the case runs against the server with a token, sends the proof and `"token": 7`, and expects `welcome`. The case "hello with no proof to a server with a token" keeps the `4401`. |
| 2 | Spec | The op table of wire-protocol.md lacked the codes of a Hub: `too_many_records` for `start`, `forbidden` for the write ops (hub.md, decision 7). | Fixed: the errors column names them, "under a Hub". |
| 3 | Spec, failure path | "The `check` ... one Hub call of 5,000 ms" understated the bound of a `check`: the existence check of decision 8 (a search of at most 5,000 ms) and the scan of a `resume` of a folder (10,000 ms) run before the Hub call. | Fixed: the sentence names both. |
| 4 | Spec | "checks each later request" is too broad: `unsubscribe` gets no check (`connection.ex`); the proof rule is decision 3. | Fixed: "each later request but `unsubscribe`, and each subscription", decisions 3 and 5. |
| 5 | Spec | A cited section "The `hub.*` operations" does not exist. | Fixed: "Wire schema additions (protocol 4)" and "Bounds". |
| 6 | Spec, standards | No test of the deadlines under a Hub (15,000 ms, 6,000 ms) and of the Hub codes in the decoder of the TUI. | Fixed: `web_socket_test.exs`, "under an authority, sessions.saved has 15,000 ms and a hub op 6,000 ms"; `decode_test.exs`, the five codes give `:error`. |
| 7 | Standards | The README of the fixtures did not list the rules of a Hub among the rules in prose only. | Fixed: one item names them and their tests. |
| 8 | Spec (minor) | tui-attach.md said that the TUI connects as the default owner of a Hub, which `helyx serve` does not start yet. | Fixed: "Under a Hub, the TUI connects with the server token, so it is the default owner"; the record cap cites hub.md, "Bounds". |

Failure path: no finding. Probes: a stub server answers a TUI `steer` with each Hub code, and the TUI ends the connection as a contract break; a server with no authority takes a `hello` with a `token` of any type and size; every `hub.*` op answers `unknown_op` there; a real Hub with the TUI client as the default owner (`start`, `subscribe`, `sessions.saved`, a `resume` of another user's shared session gives `not_found`); a suspended or stopped Hub at the `hello` closes with `4503`. Not reached: the reconnect of the TUI after `4403` or `4503`.

The round reproduced no defect: the loop ends.

## Round 2, as protocol 6 (fast mode: failure path and Codex)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Codex (high) | "The TUI decoder maps only three of the five codes; `too_many_projects` and `unknown_project` are contract breaks." | Rejected, not reproduced: `Decode` lists all five in `@error_codes`, and `decode_test.exs` asserts that each of the five decodes to `{:error, code}`; the list of `Helyx.Hub.Access` (`@codes`) holds all five too. |

Failure path: no finding. A stub server of protocol 6 answered every request with each of the five codes; every TUI path that gets the error (the subscribe of a switch, `Link.stop`, `Link.open`, `send_text`, `/model`, `/compact`, an answer, the session list, the abort) gives its notice or text, and the connection stays. The Rust fixtures pass with the new case. Not reached: the reconnect of the TUI after `4403` or `4503`.

## Guarantee table

| Guarantee | Proof |
|---|---|
| The schema block has the SHA-256 of protocol 6, and its first line is `protocol 6` | `plugins/bundled/test/helyx/transport/web_socket_test.exs`, "the schema of the wire doc has the SHA-256 of the protocol number" |
| A client of protocol 5 gets `refused` with the number of the server, then `4426` | `test/fixtures/wire/client_frames.json`, "hello of another protocol, before its proof"; `web_socket_test.exs`, "another protocol number gets refused and 4426"; `web_socket_authority_test.exs`, "a client of another protocol gets 4426 before the authority" |
| Each fixture file names protocol 6 | `plugins/bundled/test/support/wire_fixtures.ex` (`load/1`); `clients/rust/core/tests/common/mod.rs` |
| No authority: the `token` is not read, the proof is | `client_frames.json`, "hello with the proof and a token that is not an id"; "hello with no proof to a server with a token" |
| No authority: a `hub.*` op answers `unknown_op` | `client_frames.json`, "a hub op, to a server with no authority"; `web_socket_authority_test.exs` |
| Under a Hub: a `token` that is not an id, unknown, or revoked closes `4401` | `web_socket_authority_test.exs`; `hub/access_test.exs` |
| `4503` when the Hub call of the `hello` is `busy` or exits | `web_socket_authority_test.exs`; `hub/access_test.exs` |
| `4403` at a change of access and at the next request | `hub/connections_test.exs`; `hub/access_test.exs` |
| `forbidden` for a write of a reader; `too_many_records` at a `start` over the cap | `hub/records_test.exs`; `hub/rules_test.exs` (Hub level) |
| `sessions.saved` 15,000 ms and a `hub.*` op 6,000 ms under a Hub | `web_socket_test.exs`, "under an authority, sessions.saved has 15,000 ms and a hub op 6,000 ms" |
| Both clients take a code of a Hub, and the TUI has a text of at most 27 bytes for each | `server_frames.json`, "an error of a code of a Hub" (both runners); `decode_test.exs`, the five codes |

## Open

- The wait of the TUI client under a Hub: `sessions.saved` and the `check` and `result` of a Hub call are outside the 5,000 ms margin of the client. The TUI first runs under a Hub with the `helyx serve` wiring, the next slice.
- The fixtures cover no server under a Hub (accepted: the README names the tests that hold those rules).
- Round 1 findings 8 (the TUI takes a code of a Hub as a contract break) and the test of finding 6 for the decoder are replaced by the rule of #860: both clients take the codes, and tui-attach.md decision 14 says so.
