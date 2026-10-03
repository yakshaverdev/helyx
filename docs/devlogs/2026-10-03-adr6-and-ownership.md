# 2026-10-03: ADR 0006 and Core ownership

A third roll-forward `/orchestrate` run on the same day, after `2026-10-03-coupling-pass-two.md`. It had two inputs. The first was the ADR 0006 revision, which the owner discussed and two outside reviews corrected: one Helyx version per client, a tolerant reader by event type, TUI cells built from the messages, and the snapshot through the live fold. The second was an outside Core ownership review (F1 to F6), which I checked against master before the tickets.

## Merged

| Ticket | PR | What changed |
|---|---|---|
| #404 | #409 | ADR 0006 revision. `contract_version` is replaced by one Helyx version per client, checked at connect for a remote client only. A tolerant reader dispatches by event type first. |
| #405 | #410 | TUI tool cells come from the messages, with the label "awaiting result". `Snapshot.turn.running` is removed. |
| #406 | #411 | The tolerant reader: a known type with a broken payload crashes, an unknown type or field is ignored, an unknown block shows `[unsupported block: kind]`. The TUI instance and `seq` guards are removed. |
| #412 | #418 | An 8 MiB bound on the text and thinking of the open assistant message (`@max_message_bytes` in `Turn`). Past it, the turn fails through the generic `TurnLoop.stop_provider/2` path. |
| #417 | #419 | The resume repair drops a tool result with no open call. `Transcript.pair/2` is the one pairing rule. |
| #407 | #420 | The snapshot goes through the live fold. The cells are in an `:array` with a map from call id to a queue of open positions. 30,000 cells: 76 to 92 ms, before 6,556 ms. |
| #413 | #421 | `TurnLoop.admit/3`, `abort/2`, `handle/2` and `work/1` own the turn lifecycle. `Wait` owns the cleanup phase. `server.ex` 367 to 212 lines. |
| #414 | #422 | `Session.Server.Messages` is the only writer of the record. Each operation writes the record and emits its events together. `Record` keeps only the event stream and the snapshot. `server.ex` 212 to 178 lines. |
| #408 | #423 | Small TUI cleanups: the `/model` regex, the test-only API removed, the product lock on ex_ratatui 0.14.1, one `Helyx.TUI.Guard` macro. |
| #415 | #424 | `Steering.steer/2` is the one operation that accepts a steer. `TurnLoop` no longer names `Queue`. |
| #416 | #425 | The tool calls of the open message count in its 8 MiB bound. The size comes from the encode that `Stream.check` already makes. |

Totals from `c6cac48` to `d9c4c0a`: Core +730 / −632, plugins and apps +204 / −312, tests +585 / −398, docs +631 / −30. Core grew a little, because the ownership tickets moved code into modules with one owner. The TUI lost 108 lines net.

## Decisions taken alone

- A `message_update` with no known delta key is ignored, because a new delta kind is a new field.
- The O(n log n) condition of the snapshot fold stays in #407, not in the ADR.
- A result with no open cell crashes in the TUI. My #407 ticket said that only a bug makes this state. That was false: a session file on disk can hold it. The #407 worker caught it, and I filed #417 so that Core repairs the transcript at resume, and merged #417 before #407.
- Ownership review: F1, F2 and F4 accepted (#413, #414, #415), and the delta bound became #412. F3 deferred, because the count shift only moves. F5 not now, because Core test support uses `Provider.Loop` and the root cannot depend on a plugin. F6 is an owner decision (data recovery). The review had a stale `contract_version` row.
- #413: the `Wait` split is accepted, with no rename.
- #414: no rename of `Messages` to `Record` and `Record` to `Events` in this run. The ticket allows the current split, and the rename touches every module that imports `emit`.
- #408 S3: the control character check in the composer stays. Codex reproduced that the kitty sequence `ESC [ 1 u` reaches the composer as U+0001 with no modifier and forges a paste marker. The ticket premise (review-only, #44) was false.
- #408 S7: `mix deps.update ex_ratatui` moved the lock to 0.16.0. The product lock keeps 0.14.1, the version the bundled tests use.
- #415: `Queue.room?/1` and `Queue.sent/4` stay public in the pure `Queue`, and only `Steering` calls them. The provider request cannot run inside `Queue`.
- #416: the waiting tool requests in `Session.Tools` stay outside the ticket. `@max_waiting` caps their count at 16. A tool request does not join the open message, so the message bound does not count its bytes (see Open).

## Escapes

| Ticket | Ship | Codex gate | System change |
|---|---|---|---|
| #404 | r1: 1, r2: 0 | r1: 0 | none |
| #405 | r1: 0 | r1: 0 | none |
| #406 | r1: 1, r2: 0 | r1: 0 | none |
| #412 | r1: 0 | r1: 0 | none |
| #417 | r1: 0 | r1: 0 | see #407 |
| #407 | r1: 1, r2: 0, r3: 0 | r1: 0 | `/implement`: probe every input path of a state before a crash or a removal |
| #413 | r1: 0 | r1: 0 | none |
| #414 | r1: 0 | r1: 0 | none |
| #408 | r1: 1, r2: 0, r3: 0 | r1: 0 | `/implement`: the same rule |
| #415 | r1: 0 | r1: 0 | none |
| #416 | r1: 0 | r1: 0 | none |

Every ticket passed the Codex gate in round 1.

The #407 and #408 escapes have one cause: the ticket, which I wrote, called a state unreachable, and the claim came from a review, not from a probe. The disk and the terminal are boundaries. The `/implement` skill now tells the worker to find every input path that makes the state and probe it, before it makes code crash on that state or removes a check for it.

## Open, no ticket

- The waiting tool requests in `Session.Tools` have a count limit (16) but no byte bound. `Stream.check` computes the encoded size of a request and drops it. The #416 review probed a 9 MB request that is not added to the open message.
- The reconnect `seq` rule has no test until a client reconnects.
- At 300,000 cells the TUI folds grow faster than n log n. The cause is not measured.
- The 128K output-token figure for GPT-5 in the bounds table was not checked against a source.
- `Messages` now writes every record and `Record` holds only the stream; the names no longer match. `Messages.end_turn/3` and `close_turn/3` are near-synonyms.
- `abort_unanswered/2` drops orphan results too since #417; its name says less than it does.
- From the last run, still open: `TurnLoop.program_turn` and the harness terms in `CONTEXT.md`, and the `State.tools` / `Turn.tools` name clash.

## Next

- Owner decision on F6 of the ownership review.
- A rename ticket for `Messages`, `Record` and `abort_unanswered/2`, if the owner wants it.
