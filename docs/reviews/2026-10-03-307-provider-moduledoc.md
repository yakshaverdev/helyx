# Review: #307, the moduledoc of provider.ex to contract and link

Scope: `git diff origin/master` on `ticket/307-provider-moduledoc`. The change cuts the `@moduledoc` of `Helyx.Provider` to a short contract and moves every rule to the new section "The provider protocol" in `docs/features/one-provider-path.md`. No code change.

Invariant: the moduledoc of `Helyx.Provider` is a short contract that links "The provider protocol"; every removed rule is stated there; every sentence of the moduledoc and of that section is true against the code.

Status: the first `/ship` pass stopped after round 3 with defects and no commit. The orchestrator decided the open points, and a second pass of at most two rounds ran (below). The commit follows that pass.

Bounds sensor, every round of both passes: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full)

| Axis | Findings | Resolution |
|---|---|---|
| Simplify | 1. "Stops" said "a malformed event" twice. Others: duplication between the short form and the full rules; the place of the protocol section. | 1. Merged. Others skipped: the overlap is the short form by design; the ticket names the feature doc as the place. |
| Standards | No hard violation. Judgement calls: `message_end`, `tool_result`, and the `_not_answered` stop lost their qualifiers; actions not listed; vague deadline wording. | Qualifiers and the action list added; deadline wording changed. |
| Spec | 1. The notice example was lost. 2. "Each callback returns a list of actions" was false for `init/3` and `info/2`. 3. "Every request has a deadline" was false for a `tool_result` request that Core makes itself. Also: Core's `{:error, :busy}` answer stops the process, stated nowhere. | All fixed, in the moduledoc and the feature doc. |
| Failure path | None reproduced. | — |
| Codex | 1. The return contract of `init/3` (as spec 2). | Fixed. |

## Round 2 (full: 28 lines changed in `provider.ex`)

| Axis | Findings | Resolution |
|---|---|---|
| Simplify | Duplication and depth only. | Skipped: the short form by design. |
| Standards | 1. The no-kill hole had no Bounds row. Judgement calls: STE length, `tref` as a contract term. | 1. Bounds row added, "no ticket yet". `tref` replaced by words. |
| Spec | 1. `message_end` short form said every open call gets `aborted`; only calls of earlier messages do. 2. `tool_result` "of a call that ran inside the program" is false for `Helyx.Provider.Loop`. 3. The kill runs from the send until the reply, not only during a callback. 4. The digit-limit error answer was missing from both lists. 5. Only a text over `@max_tool_result_bytes` fails the turn. | All fixed. |
| Failure path | 1. A `:turn_start` that the session drops while a turn runs is not dropped by the provider process: the open tool requests get `aborted`, and a later `need_context` of the running turn stops the process. Reproduced with `Helyx.Test.Connected`. Pre-existing code; the ticket forbids a code change. | Stated as a known gap in "A program turn", no ticket yet. |
| Codex | 1. As spec 1. | Fixed. |

## Round 3 (full: 19 lines changed in `provider.ex`)

| Axis | Findings | Resolution |
|---|---|---|
| Simplify | 1. The Bounds row repeated Deadlines. 2. A repeated sentence in Deadlines. | Both trimmed. |
| Standards | No hard violation. Judgement calls: STE sentence length; "tool result limits" against "the limit of `Helyx.Session.Stream`"; the Bounds row should say "no ticket yet". | Open, not applied. |
| Spec | 1. "`call_id` is the id of the call in the program's own events" is false for `Helyx.Provider.Loop`, which sends a per-turn request id. 2. The Bounds table "Deadlines" row still names `@harness_reply_ms` and `@harness_close_ms` (now `@provider_reply_ms`, `@provider_close_ms`). | Open, not applied. |
| Failure path | 1. "The session applies every event before it in the action list first, so the context holds them" (also C2) is false for content of an open assistant message: the context holds only the transcript, so a delta or a tool call that no `message_end` closed is not in it. Reproduced with `Helyx.Test.Connected`, model `context`. | Open, not applied. |
| Codex | 1. As failure path 1, reproduced with a probe. | Open, not applied. |

All round 3 defects are in sentences that were already false on master (moved text) or outside the moved section; none is made false by this change.

## Orchestrator decisions (2026-10-03)

- The `:turn_start` gap is ticket #319; the feature doc names it.
- The wait on a `tool_result` request that Core makes itself is accepted: the next session request, for example the interrupt of an abort, ends it. The Bounds row says so.
- Apply round 3 items 1 to 3, and the cheap wording items.

## Second pass, round 1 (full)

Applied before the round: "A fresh context" and C2 say that the context holds only the transcript, so an assistant message that no `message_end` closed is not in it; `call_id` may be a request id of `Helyx.Provider.Loop`; the Bounds rows name `provider_process.ex`, `@provider_reply_ms`, and `@provider_close_ms`; #319 and the accepted row; long sentences split.

| Axis | Findings | Resolution |
|---|---|---|
| Simplify | 1. C2 repeated the transcript sentence of "A fresh context". 2. The full `message_end` rule in the doc read as wider than the short form. Others: overlap by design. | 1. C2 links back. 2. The doc names the calls of the earlier messages. |
| Standards | No hard violation. Judgement calls: the busy rule in the moduledoc named only turn and interrupt; STE length; "the helper" in C2. | Busy rule moved to its own paragraph with all four kinds. Others kept. |
| Spec | 1. As standards (busy scope). 2. "A turn ends at its `done` or `error` event:" read as a property of every listed event. | Both fixed. |
| Failure path | 1. "The turn fails with `:provider_timeout`" and "a stop with its reason": Core maps the exit reason, so a callback or a linked process that exits with `:killed` or `{:shutdown, r}` gives the same failure. Reproduced with `conn/hang`. | Deadlines states the mapping. |
| Codex | 1. "At the end of the turn, a provider sends every `message_end` that it did not send yet" is false: `done` closes the last message, and a `message_end` right before `done` adds an empty assistant message (`end_turn/2`). | Fixed in the doc; the Events intro says that `done` closes the last message. |

## Second pass, round 2 (reduced: about 13 lines in `provider.ex`, one file, no function change)

| Axis | Findings | Resolution |
|---|---|---|
| Spec | 1. "Core takes this reason from the exit reason only" misses the release error of an unconfirmed handle (`hands.ex`, `deliver/3`). 2. "a stop with its reason": the reason is the stop reason, such as `{:provider_stop, r}` or `{:provider_init, r}`. 3. A turn also ends when the provider process ends. | All fixed in the doc and the moduledoc. |
| Failure path | 1. A taken steer closes the open assistant message and aborts every open call, the calls of that message too (`take_steer/2`), so "the calls of the closed message stay open" and "an `error` drops the content that no `message_end` closed" were incomplete. Reproduced. 2. As spec 1, reproduced. | Fixed: the steer rule, the `message_end` bullet, the `error` sentence, and the moduledoc deadline sentence. |

Round 2 is the last round of the pass. Its fixes are doc sentences checked against the code (`server.ex` `take_steer/2` and `end_turn/2`; `hands.ex` `deliver/3` and `down_reason/1`; `provider_process.ex` `start/2`). They had no further review round.
