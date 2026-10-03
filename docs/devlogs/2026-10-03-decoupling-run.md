# 2026-10-03: decoupling run

A roll-forward `/orchestrate` run of about four hours, with full cleanup authority from the owner. The input was the SRP and coupling review of Core and one owner decision: the session owns the live turn and its Helyx tool calls, and the provider process is a checked pipe.

The rule of the run: tests record the old assumptions, not the spec. A rule stays only with evidence that its case is real: an observed run, a research note, a bug report, or a safety bound against resource growth or data loss. A rule that only a reviewer imagined is a deletion candidate, and its tests go with it. #360 wrote this rule into `AGENTS.md`.

## Merged

| Ticket | PR | What changed |
|---|---|---|
| #360 | #363 | `AGENTS.md`, ship, orchestrate, checklist: a contract break gets one generic answer; a case-specific handler needs evidence. Findings about the generic path, Core races, and safety bounds stay findings. |
| #359 | #364 | One steer owner: `Session.Queue` in `State.queue` replaces `Queues` and `Steers`. The states `taken` and `noticed` became `settled`; `ended` became `sent` with the turn id. |
| #358 | #370 | The session owns the turn and its tool calls (`Server.Tools`). Removed `tool_start`, `turn_dropped`, `seen`, the loop's `end_tools` and `write_result`. `provider_process.ex` 398 to 193 lines. New contract sentence: a tool result can arrive after the interrupt or the next turn of its turn; each call still gets exactly one result. |
| #368 | #371 | OpenAI and tools: one shape check and `Text.cap/3`. `@max_call_index` stays (safety: empty deltas grow the map). |
| #365 | #372 | Codex: removed `Order`, the held events, and the retries, about 836 lines. |
| #362 | #373 | `Provider.Loop` sends all tool calls of a message at once. |
| #366 | #374 | Claude Code: removed the branches for output that no run showed. An `init` without both capabilities stops the provider (claude 2.1.287 lists both in every init). |
| #361 | #375 | No drain of old replies between turns, no tool pool; the session monitors its provider. A provider of an earlier turn that ends while the next turn prepares gets a reconnect, once per turn (#198). |
| #367 | #376 | Watchdog: the safety lock and the group kill stay (ADR 0004). Removed six review-only hardening paths and 15 tests. The go-ahead is one byte; a failed `exec` gives exit 127 with its reason. |
| #369 | #377 | The session owns the tool-call ids: an open id is a bad action, an answered id runs again. Removed `Turn.ids` and both providers' `used` sets. `user_message` carries the steer id only. |

## Decisions taken alone

- #358 treats a reused call id as a contract break and keeps the armed kill per request. #369 later moved the id check to the session and made it check only open ids.
- #359 ran in parallel with #358; the second to merge rebased.
- #361: the worker first accepted a hole: a provider that ends right after its terminal makes a queued follow-up fail. I rejected the hole, because Codex does this at a turn end with an open command (#198), so it is a real path. The fix reconnects for the same turn. The hands' `:provider_down` stays the release signal, because a start call would wait behind a release of up to 20 s.
- #362: the session limit of 16 waiting calls now applies to the calls of one model message. A message with more than 17 calls gets error results for some of them.
- #366: one Codex finding in ship was rejected, because it asked for a handler of output that no run shows.
- #367: a failed `exec` is an ok bash result with exit 127, as a shell gives it, not a tool error. A watchdog killed from outside before the go-ahead gives exit 137.
- #369 was rebased onto #361 and #367 with three mechanical conflicts (`Turn` fields, a feature doc paragraph, a pool test that #361 deleted). The Codex gate reviewed the rebased branch instead of a reduced ship round.

## Escapes

| Ticket | Ship | Codex gate | System change |
|---|---|---|---|
| #360 | n/a (docs) | r1: 1 (rule too broad), r2: 0 | ship: a Markdown change to an agent rule gets the Codex review |
| #359 | r1: 0 | r1: 0 | none |
| #358 | r1: 1 (pool counted tool results) | r1: 0 | none; #361 removed the pool |
| #368 | r1: 1, r2: 3, r3: 0 | r1: 0 | none |
| #365 | r1: 1 | r1: 0 | none |
| #362 | r1: 0 | r1: 0 | none |
| #366 | r1: 1, r2: 0 | r1: 0 | none |
| #361 | r1: 2, r2: 1 (doc), r3: 1 | r1: 0 | none; the orchestrator caught the hole before the gate |
| #367 | r1: 0 | r1: 0 | none |
| #369 | r1: 0 | r1: 0 | none |

Every code ticket passed the Codex gate in round 1. One defect class repeated: a mechanism that the old design needed made the defect (the pool in #358). The fix was to delete the mechanism, not to add a guard.

## Not ticketed: owner decision needed

- The TUI items of the plugin audit: they need ADR 0006.
- `HarnessIO.keep_port/1`.
- The paste-marker editing in the TUI composer.

## Held from earlier

#351, the `TurnLoop` module in `server.ex`, #345, and #339. #358 removed `turn_dropped`, so most of #339 no longer applies.

## Next

- The owner takes the held decisions and the items that are not ticketed.
- `server.ex` is still over the 400-line limit (621 lines, with an entry in `.credo.exs`). The `TurnLoop` decision decides its split.
