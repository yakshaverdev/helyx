# Review: a resume id that arrives after an abort (#518)

Scope: the provider process sends a checked resume id as `{:resume_id, pid, turn_id, id, cut}`, and the session records it from its live provider process in a turn and in the wait that the turn ended (`Helyx.Session.Server`, `Records.resume_id/4`, `Wait.turn`). Owner decision: option 1 of #518 (comment of 2026-10-12). Source of the hole: `docs/reviews/2026-10-12-510-lost-flag.md`.

Invariant: a resume id is recorded only when it comes from the pid in `State.conn` with status `:ready`. Its turn id must be the id of the current turn, or of the turn that the current wait ended (`Wait.turn`). To record means three things: the session file entry, `State.resume_ids` with the assistant count at arrival, and a `:resume_id` client event. The event has `lost` true only for the first new id after a start that passed a resume id. Every other resume id is dropped, and the session does not crash on it: one from an `:ending` process, from another pid, for another turn, or while the session is idle.

Entry points: `ProviderProcess` (the action of a checked `{:resume_id, id, cut}` event), the `{:resume_id, ...}` clauses of `Helyx.Session.Server.handle_info/2`, `Records.resume_id/4`, and `Wait.finish/2`, which sets `Wait.turn`.

Accepted hole: a resume id that the live process sends after the wait ended (idle, or a later turn) is still dropped. Both bundled providers send it while they handle `{:turn, ...}` (`claude_code.ex`, `write_turn/1`; `codex.ex`, `replay/2` from the `{:turn, ...}` request). So it comes before their answer to the interrupt. No provider is known to send it later, and the owner decided only the wait. `Transcript.resumable/3` still decides at the next start whether a stored id is reused.

The test holds the wait open with the held interrupt answer of the test provider ("late_interrupt"), not with `:erlang.suspend_process/1`; the ending test holds the session with `:sys.suspend/1`. Neither sleeps.

## Simplify

Four agents (reuse, simplification, efficiency, altitude).

- Fixed: the two resume id clauses of `Server`, the same but for the activity, became one clause with a guard (simplification). Round 1 then split them again, see 1.4.
- Fixed: the comment on `ProviderConn` named `Records.resume_id/3`; now `/4`.
- Skipped (altitude): record the id from the live process in any activity, also idle and a later turn. It is simpler, but the owner decided the wait only, and no provider is known to send the id after its interrupt answer. Stated as the accepted hole.
- Reuse and efficiency: clean.

## Round 1 (full)

Bounds sensor (`--diff origin/master`; master had moved past the branch base, so the run also saw the changes of #522):

```text
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

Rerun on the branch base (`--diff dfd8981`) after round 2:

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | failure path | In a wait the clause did not check the turn id. A provider that held the interrupt open and sent `{:resume_id, ...}` with a turn id of 1,000,001 bytes that is not UTF-8 got that id into the client event, and the id was recorded. Reproduced through the provider's `{:event, turn_id, ...}` action | Fixed: `Wait.turn` holds the id of the turn that `Wait.finish/2` ended (nil for a wait with no turn), and the wait clause matches the event's turn id against it. The test sends a resume id of another turn first; the mutation that drops the match fails it |
| 1.2 | spec | After the fix of 1.1 the ending test used a switch close, a wait with no turn, so the turn match dropped the event first and no test covered `status: :ready` | Fixed: the ending test stops the process with a second context request (a bad action) in the wait of its turn, and holds the session with `:sys.suspend/1` until the resume id after it is in the mailbox. The mutation that drops `status: :ready` fails it, three runs of three |
| 1.3 | standards | The doc line "both bundled providers send it before the answer to the interrupt" had no test | Kept, reworded to what the code shows: both send it while they handle `{:turn, ...}` (code references in the invariant above). The spec agent confirmed the order by reading both providers |
| 1.4 | standards | Judgement calls: the guard switch on the activity reads unlike the rest of the file; a code comment gave a reason; the "also after the turn" rule was repeated in three comments | Fixed: two clauses again (`%Turn{id: turn_id}`, `%Wait{turn: turn_id}`), and the comments in `Server` and `Records` now state only the rule |
| 1.5 | standards | Judgement call: `{:resume_id, pid, ...}` copies the shape of `{:tool_request, pid, ...}` (Data Clumps) | Kept: two messages; a shared envelope waits for a third |
| 1.6 | spec | `docs/reviews/2026-10-12-510-lost-flag.md` still lists the hole as open | Kept: a review record keeps its state at its date |
| 1.7 | Codex | Approve, no findings (36 state probes of pid, status, activity, and turn id) | — |

Round 1 reproduced one defect (1.1), so round 2 runs. The fix touches two code files and adds a struct field: a full round.

## Round 2 (full)

Simplify, four agents:

- Fixed (reuse): the ending test starts its turn with the helper `context_turn/2` of the file.
- Skipped (simplification): one clause with a guard on both activities. Round 1 chose the two clauses (1.4).
- Checked (simplification, altitude): `Wait.turn` cannot be derived. `ProviderConn.turn` is the turn that started the process, and a reused process keeps it over later turns.
- Efficiency: clean.

Bounds sensor (`--diff ed4bca7`, the commit before the fix):

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | failure path | No defect. The reproduction of 1.1 is in the test. A probe with one process over three turns dropped a resume id of an earlier turn in a later wait and in a later turn, and one with an id that the provider chose; it recorded the one of the current turn once. From the code: a wait with no turn has `turn` nil and the provider process sends only binary turn ids; a wait never gets a new pid, because `connect/1` runs only in a turn | — |
| 2.2 | spec | No test failed when the turn id match of the `Turn` clause was removed: a resume id of an aborted turn that comes in the next turn | Fixed in the test: after the wait, the live process sends a resume id of the aborted turn while idle and in the next turn, and neither records. The mutation that drops the match now fails the test. The pid and `:ready` matches of the `Turn` clause have no test: a sent turn has a `:ready` process, and no other pid gets its id |
| 2.3 | standards | The comment in `ProviderProcess` said the session records the id "also after the turn"; it records it only in the wait after the turn | Fixed |
| 2.4 | standards | The feature doc says a resume id "at any other time" is dropped; idle had no test | Fixed by 2.2, which covers idle |
| 2.5 | standards | Judgement calls: the invariant paragraph of this record was one long sentence; the test name "the client gets lost at once"; "the turn id of the stream event" in `Records`, where the message is no longer a stream event; a short line in the `Event` doc | Fixed |
| 2.6 | standards | The round 1 sensor ran on `origin/master`, which had moved | Rerun on `dfd8981`, above |
| 2.7 | Codex | Approve, no findings | — |

Round 2 reproduced no defect, so the loop ends. The fixes after it are a comment, docs, and a test.

## Gate r1 (Codex): 0 findings

Verdict approve, after a rebase on master with #514 and #522. #514 changed only doc text in the files that this diff also changes (its executable ASTs were unchanged), so the rebase got no reduced round. The ids that arrive after the wait stay dropped, as accepted.
