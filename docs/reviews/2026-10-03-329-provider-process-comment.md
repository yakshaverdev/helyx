# Review: the tool-call comment of the provider process as a contract and a link (#329)

Date: 2026-10-03. Base: `origin/master` at `67dc9d7`. Scope: the "Helyx tool calls" comment in `lib/helyx/session/provider_process.ex`, the section "Built in #203" of `docs/features/long-lived-harness.md`, and `.credo.exs`.

## Invariant

Every sentence of the new 5-line "Helyx tool calls" comment and every changed sentence of "Built in #203" states the code behaviour of `serve/4`, `tool_request/4`, `run_next/3`, and `end_tools/1` exactly. Every rule of the removed comment is in the feature doc. No code and no test changes.

## Size

`provider_process.ex`: 415 lines before (the ticket said 416), 388 after. The `.credo.exs` entry is removed.

## Round 1 (full)

Bounds sensor: `bounds sensor: 1 candidate functions, 1 flagged, 0 without an answer` / `lib/helyx/session/provider_process.ex:94  WAIT  defp loop(proc) do`. The diff does not change `loop/1`.

Simplify (4 agents): 1 finding, skipped. The pointer at line 27 to "Helyx tool calls" below is not dead: the new comment starts with that name.

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 1 hard, 4 judgement calls | 0 | The doc sentence that started with "So" now reads alone. Not changed: the old name `Helyx.Session.Harness` in other sections (lines 47, 53, 332, 334, 527, 551). The ticket limits the rename to "Built in #203". |
| Spec | 0 missing, 1 implicit | 0 | The doc now gives the reason for the drop of a late result: it never answers a call of a later turn. |
| Failure path | 1 | 1 | The edit had changed "the 8 open requests" to 17. The 8 is `@max_open`, the request pool, not `@max_tools`. Reproduced with 8 open steers: a ninth steer got `{:error, :busy}`, a `tool_result` got `:ok`. Restored to 8. |
| Codex adversarial | 3 | 3 | (1) The comment said "a call id gets one answer"; a reused closed id gets a second answer, a rejection. The comment now says only that an id that got any answer never runs later in the turn. (2) The doc now names the started call as the exception to the `:ok` drop of a result whose pair is not open, and says that a `:dropped` start ask also advances the queue. (3) The doc named `Stream.check/2` and said that the session answers the digit-limit rejection; it is `Stream.check/1`, the loop answers through the provider, and the checks for a turn that is not live, an open id, and a used id come first. |

The Codex review ran before the Codex usage limit of 2026-10-03, so no agent substitute was needed.

## Round 2 (reduced)

The fix changes 2 comment lines in one code file and adds no function, so the round is reduced: spec and failure path only. Brief: find another changed sentence that breaks the invariant.

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Spec | 1 missing, 2 wording | 0 | The doc now says a turn is also live from its `:turn_start` event (#240), and gives the check order "not live, open id, used id". Not changed: "So a call gets exactly one answer" in "The start ask" is old text about a request that the loop sent. |
| Failure path | 0 | 0 | Probes through `Helyx.Test.Connected` confirmed the late result of a started call, the `:dropped` advance, the loop's digit-limit answer, and the check order. Not reached: a `turn_start` that reuses an ended turn id, an overwrite of `started`. Both are old text. |

Round 2 reproduced no defect, so the loop ends.

## Known gaps, not changed

- "17 requests of the turn are open" counts `running` plus `waiting`; a withdrawn running call still counts, but it is not open. Old text.
- The terminal, interrupt, and next-turn `aborted` bullet does not name the started call; "The start ask" gives the exception. Old text.
