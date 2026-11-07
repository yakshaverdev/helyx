# Review: before_settle and the continue turn (#880)

Base: `d3840c0c` (the merge base; no commits on the branch before the review). Scope: the working tree, `git diff d3840c0c` and the untracked files. Feature doc: `docs/features/before-settle.md`.

Invariant: after a done turn that is not a compaction, the `before_settle` chain runs as the last part of the wait in a chain Task of the hands, never in the session process; a continue starts exactly one next turn whose user message has the origin kind `:hook`, after a waiting compaction and ahead of the queue, at most 8 in a row until a client message resets the count; a failed hook fails open with a notice; an abort ends the chain, releases its handles with `:cancel`, and starts no turn.

## Bounds sensor

```
bounds sensor: 8 candidate functions, 2 flagged, 0 without an answer
  lib/helyx/interfaces/tool.ex:219  WAIT  def unhold(handles) when is_list(handles) do
  lib/helyx/session/ask.ex:22  WAIT  def await_go do
```

Both are code of #879 that the diff only moves next to (a doc of `context/0`, the new `Ask.asker/2`). The failure-path agent attacked both from a `before_settle` hook: `await_go` is inside the armed kill of the hook's limit, and `unhold/1` acts as from a tool hook.

## Round 1 (full)

Simplify, then standards, spec, failure path, and the Codex adversarial review.

### Simplify

`Settle.due/3` became `Settle.finish/3`, which also dropped a waiting continue at an abort or a failure (replaced in the fix of precommit, below); `max_turns/0` (unused) went; `Hands.Settle.chain/2` returns a task entry as `Hands.tool_call/2`; the test hooks of `before_settle` reuse `Helyx.Test.Hook` with a `points:` option.

### Codex adversarial review

Verdict approve, no material findings. It ran 22 focused tests, with the compaction order, the abort, and the release.

### Failure path

No reproduced defect. Probes through the session API, a hook plugin, and Core start: an abort racing the continue answer (10 runs, 0 to 4 ms), an abort while the hands are busy in a slow release of a settle hook, the provider process killed during the chain, `set_model` during the chain, a steer and a follow-up during the chain, a session stop during the chain, tool-only calls from a settle hook (`background/0`, `unhold/1`, `started/1`), and the name bound at 256, 258, and a multibyte 250 bytes. Noted, not a finding: `Settle.continue/2` has no clause for an exit of the chain Task; the chain Task runs no plugin code and no plugin can see its pid, so only a bug makes it, and the session crashes then (AGENTS.md, "let it crash").

### Standards

| Finding | Resolution |
|---|---|
| Hard: the `Helyx.Hook` moduledoc said "A failed hook there is a `:notice`, and the session settles", but the chain goes on with the next hook, which can continue | Fixed: "the chain goes on with the next hook; with no continue the session settles" |
| Hard: `collect_until_quiet/1` in the new test waits a fixed 100 ms for a message that must not come | Fixed: it waits `@load_ms` |
| Guarantees with no test: the provider turn (#240), the compaction before the continue, the steer that joins the continue turn, the drop of a waiting continue at an abort, the reset by a queued follow-up, the continue past the count in the file, the notice with no turn id, the context keys | Tests added (`test/helyx/session/before_settle_test.exs`): "a turn that the provider started by itself runs the chain", "a compaction that waits starts before the continue turn", the steer and the count reset in "goes ahead of the follow-ups", "an abort while a continue waits for a switched provider's close drops it", 9 entries in the count test, `turn_id: nil` in the limit test, the full context in the ask test. The release of a hook Task at the death of its chain Task (`Hooks.orphans/3`) is the path of #879 and no boundary can kill a chain Task: no test, stated in the review |
| Judgement: `Ask.asker/2` moved out of `hands.ex` for its line count | Kept: the kind of a record is a decision of the caller check of an ask, which `Helyx.Session.Ask` owns; `hands.ex` only sends it. The move came with a new rule (`{:settle, _}` has no record), not alone |
| Judgement: `{:settle, ref}` matched in five places | Kept: each place is its own concern (the record kind, the message to the session, the call id of an entry, the caller of a hook start, the tool call lookup) |
| Judgement: duplicated context map with `ToolRuns` | Kept: two fields differ (no tool, no call id), and a shared helper would put a hook concept in `ToolRuns` |
| Judgement: names `continue`, `take/1`, `count/2`, `settle` | Kept: `continue` is named for the answer that made it, as `pending_compact` for the request. `take/1` went in the fix of precommit, below |
| Judgement: `Wait.settle` running as a bare ref | Kept: the ref is the match key of the answer, and `progress/1` needs only the due form |

### Spec

| Finding | Resolution |
|---|---|
| Three guarantees with no test (the drop of a waiting continue, the provider turn, the late answer after an abort) | Tests for the first two (above); the late answer is matched by its ref (`Settle.answer/3`, second clause), and the failure-path probe of an abort racing the answer covered it (10 runs) |
| The `Helyx.Message` moduledoc lists no `:hook` | Fixed |
| The wrong sentence of the `Helyx.Hook` moduledoc | Fixed (as standards) |
| An abort while the chain is due drops it, not documented | Documented in the feature doc, "Failure, abort, and stop" |
| Print mode misses a continue turn, no ticket | Kept open and reported: the ADR names no settle event; the coding agent registers no hook today |
| Decisions the ADR does not make: `{:invalid_hook_name, module}`, the count of 8, the compaction before the continue, no notice for a failure after an abort | Stated in the feature doc; the last one follows the rule of #879 for an `after_tool` answer after its turn; none contradicts the ADR |

Guarantee table of the spec agent (each row proved by a test or a probe of the round): fail open with notice and entry (`before_settle_test.exs`, "fails open"); no chain after an abort, a failure, or a compaction; the hook input and the context; the origin of the continue message and its read back; ahead of the follow-ups; the first continue ends the chain; the count of 8 with the exact notice and the reset; the text bound at 4 MiB and one over; the `before_settle` limit at 1, 600,000, 0, and 600,001 (`hook_test.exs`); the name at 256 and 257 bytes of two-byte characters, and no check on a tool point; a hook past its limit with its handles released with `:cancel`; the ask of a settle hook gets `:not_running`; the abort during the chain; the entry with `call_id` and `reason` null and no settle entry; the session `running` with no snapshot turn during the chain (probe); the steer that joins (probe, then test); the compaction first (probe, then test); 9 entries past the count (probe, then test); the notice cut and with no turn id (probe); the refusal after an unconfirmed release (probe); the session API and the wire refuse a `:hook` origin (probe, `client_frames.json`); protocol 4 and the TUI decode (`client_frames.json`, `server_frames.json`, `web_socket_test.exs`).

A round that reproduced no defect ends the loop: the fixes above are wording, docs, and tests, with no change to the code of `lib/` but two moduledocs.

## Precommit, and the fix

The first precommit run failed one Credo check: `Helyx.Session.Server.State` had 33 fields, over the 31 of `Credo.Check.Warning.StructFieldAmount` (a struct of more than 32 keys is no longer a flat map). The two new fields `continue` and `hook_turns` made it. The check does not misfire, so the design changed: both moved into `Helyx.Session.Queue`, the state that a turn start and an abort already change. `Queue.drain/1` gives a waiting continue first, `Queue.abort/1` drops it (an abort, and an abort or a failure at the end of a turn through `Queue.end_turn/3`), `Queue.count/2` keeps the count, and `Steering.continue/2` and `count/2` write them, so `Steering` stays the only writer of the queue. The clause of `TurnLoop.start_queued/1` for a continue, `Settle.take/1`, `Settle.count/2`, and the drops in `Settle.finish/3` and `Settle.abort/1` went.

## Round 2 (reduced)

Spec and failure path, on the fix. Invariant: a continue starts exactly one next turn after a waiting compaction and ahead of the queued steers and follow-ups, an abort or a failed turn drops it and never gives it back, and the count goes up at a continue turn, to 0 at a turn that a client message starts, and past 8 the session settles.

### Spec

No defect. Probes: the order of `drain/1`; `abort/1` and `end_turn/3` at an abort drop the continue, `end_turn/3` at done and `provider_down/2` keep it; an abort gives no `{:dropped, _}` for a lone continue; an abort of a compaction turn with a continue, a steer, and a follow-up behind it gives back only the steer and the follow-up and starts no turn; `counts/1` ignores the continue, so no `queue_update` and no snapshot change; two continues with a compaction between them count 2.

| Finding | Resolution |
|---|---|
| This record named `Settle` as the writer of `continue` and kept `take/1` | Fixed above |
| `session-lifecycle.md`: `Queue.drain/1` gave "every queued steer together, or with none the first follow-up", and the continue went "ahead of the queue" | Fixed: a waiting continue first; "ahead of the queued steers and follow-ups" |
| The comment of `queue` in `State` named only the queues and the sent steers | Fixed |
| A resume starts the count at 0 (a fresh queue), not documented | Documented in the feature doc |

### Failure path

The first agent of the round died at the usage limit of the model account with no report; it was rerun.

The rerun reproduced no defect. Probes through the session API, hook plugins, and the test providers: a background end during the chain joins the continue turn at its send, with no wake turn of its own, and the count is 1; a model switch during the chain and a continue turn that fails give back only the queued follow-up, not the continue, keep the count at 1, and the next prompt sets it to 0; a steer rejected in a continue turn joins the next continue turn once; a held steer rejected late while the chain runs joins the continue turn once. Code reading: `Open` is the only other writer of the queue (a fresh queue at a resume, a count of 0, documented); no turn can start beside a waiting continue; no new check duplicates a boundary check. Not reached: the count of a wake turn at run time (read only, `Queue.count/2` with no user message), a provider death while the continue turn prepares, and a provider turn between continue turns at run time.

A round that reproduced no defect ends the loop.
