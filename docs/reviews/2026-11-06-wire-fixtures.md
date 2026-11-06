# Review: wire conformance fixtures (#855)

Base: `738c3c07` (merge base). Change: `test/fixtures/wire/` (README and three JSON files), the runners `plugins/bundled/test/helyx/transport/web_socket_fixtures_test.exs` and `plugins/bundled/test/helyx/tui/wire_fixtures_test.exs`, the helper `plugins/bundled/test/support/wire_fixtures.ex`, and the section "Conformance fixtures" of `docs/features/wire-protocol.md`. No `lib/` code changes, and no protocol change.

Bounds sensor, round 1: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full: simplify, standards, spec, failure path, Codex)

Simplify: the close of a case must be the next frame (it skipped frames before); the `session_end` reason comes from the fixture; the fake welcome uses `WebSocket.protocol()`.

| # | Axis | Finding | Reproduced | Resolution |
|---|---|---|---|---|
| 1 | Failure path, standards | The client-frame runner passes a case with an empty `expect`, an unknown key, or an unknown `phase`; a case with no `close` does not check that the connection stays open | yes, three cases in a copy of the runner passed | Fixed: the runner checks the keys of a case, its phase, and its `expect`; with no `close`, it sends `sessions.live` and needs its reply as the next frame. README states the open rule |
| 2 | Codex | The reply and event checks read only the payload: an event frame with no `sub` still passed, though the client ends the connection on it | yes, the `notice` case with no `sub` passed | Fixed: every `res`, `event`, and `session_end` case runs through `Helyx.TUI.Wire.Connection` against a fake server; checked by removing `sub` from the `notice` case, which then fails |
| 3 | Spec | No fold starts from a snapshot with a `turn`, though the README states `running` for it | n/a (missing case) | Fixed: a fold of a snapshot during a turn |
| 4 | Spec, standards | The doc bullets on the model ref and on the session id have no test | probe | The model ref is in `test/helyx/tui/wire/decode_test.exs:327-329`; the session id now has a test in `web_socket_fixtures_test.exs`. Both stay open in the doc, so neither is a fixture |
| 5 | Spec | The `req` with an id of 65 bytes gets a `res` that carries that id, against the schema `id` of 1 to 64 bytes | yes | The code follows the bounds row ("`bad_params`") and the existing test `web_socket_test.exs:427`. The doc lists the mismatch as open; no behaviour change (ticket notes) |
| 6 | Spec | No `history` or `sessions.live` reply among the server frames | n/a | Not fixed: the client of the TUI does not send these ops, so no Elixir client checks their results. README states that their shapes are in the schema only |
| 7 | Spec, standards | The fold steps `close`, `session_end`, and an error reply run no client code | n/a | Wording: README states that the Elixir run gives the view model no input for them, and names the test of the connection side |
| 8 | Spec | The 16,777,216-byte case is a cut test of `History`, not a snapshot frame | n/a | Accepted: the README names `history_test.exs` as the test at the bound, and the fixture bound asks only that it is not stored |
| 9 | Standards | Smells: the snapshot reply found by its case name; the bundled tests read the root folder | n/a | Fixed: the first valid snapshot reply; README states the path |

The fix of round 1 is over 100 lines of test code (the client runner moved from the decoder to the connection), so its scope is wider than the finding: it is reported here before round 2.

## Round 2 (reduced: spec, failure path)

Both round-1 reproductions fail now, as they must.

| # | Axis | Finding | Reproduced | Resolution |
|---|---|---|---|---|
| 1 | Failure path, spec | The fold runner checks only the payload: an event with another `sub` or none, a `session_end` of reason `"gone"`, and a replay to a `subscribe` with no `after` pass, though the client ends the connection on each | yes, in copies of the runner and the folds | The second finding on one mechanism, the check of a frame apart from the client, so the mechanism changed: each fold runs through `Helyx.TUI.Wire.Connection` against a fake server, one connection up to each close step, and the events, replies, `session_end`, and the close reach the view model as the client gives them. Checked by mutation: another `sub`, another reason, and no `after` each fail |
| 2 | Failure path, spec | The client runners skip a case with a missing key (`for` patterns filter) and ignore an unknown key | yes, three cases passed | Fixed: each case is matched in the loop body and checked by `WireFixtures.keys!/3`, in both runners |
| 3 | Spec | No `resume` reply case, and no `ok: true` reply of an op whose result is `{}` | n/a | Fixed: `resume` and `steer` pairs |
| 4 | Spec | The fold of `instance_changed` used `history`, which no Elixir client sends | n/a | The fold now shows a reconnect with `after` of an instance that changed; README states why no fold has the `history` error |

A close code in a fold is an input of the fake server, not an expectation: a mutation of it passes, and README states it as what the server sends.

## Round 3 (reduced: spec, failure path)

Every round-2 reproduction fails now, as it must.

| # | Axis | Finding | Reproduced | Resolution |
|---|---|---|---|---|
| 1 | Spec, failure path | The fold runner does not compare the request that the client sends with the `client` step: a step of another `type`, or with params that the client does not send (`tail`, `bogus`, `answers: false`), passes, and `after` is checked against the state of the runner, not the frame on the wire | yes, in copies of the runner and the folds | Open. A third finding on one mechanism, the fidelity of the fold runner, so the small-fix round of `/ship` does not apply: the code is committed as round 3 reviewed it, and the finding goes to the caller |
| 2 | Failure path | A `client` step with no reply step passes after the deadline of the client (`{:error, :timeout}` is not refused) | yes, 11.2 s | Open, as finding 1 |

The fix of both is in the fold runner only: match the frame that the fake server reads against the `client` step with its `id` mapped, and refuse a result other than a reply. The fixtures as they are pass both checks: each `client` step of `folds.json` is a `subscribe` with the params that `Helyx.TUI.Wire.Connection.subscribe/3` sends, and each has its reply step next.

## Precommit

`HELYX_SLOW=1 .claude/skills/ship/precommit.sh`: the first run failed on one Credo warning, the unused return of `Enum.reduce/3` in the fake server of the fold runner; it is bound to `_ids`, with no change of behaviour. The second run passed.
