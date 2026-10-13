# Review: #559 Model limits and prices from config

Invariant: the usage of each `done` has a list cost only when every model call since the previous `done` of the provider process is priced and counted. `Helyx.ModelInfo.lookup/3` gives the config window and prices of the ref in use (the catalog step is empty until #560). It fails a bad entry with the path of its key, at Codex and Claude Code `init/3` and at the OpenCode `stream/5`. `Helyx.ModelInfo.cost/2` takes the whole price set of the tier with the largest size under the prompt. Codex prices each `tokenUsage.last` alone. Its `done` gets cost nil after a turn that ended `interrupted` or `failed`, a usage notification that adds nothing to the sum (any shape), a call with `cacheWriteInputTokens` above 0, or a turn that started a sub-agent. `Helyx.Provider.Loop` gives cost nil to the next usage after a model call that an abort or a stream error ended. The serving side window wins over config.

Accepted: sub-agent tokens are not in the totals (a permanent ceiling, marked by cost nil, stated in the feature doc). A provider process that ends before its next `done` loses its sum. Claude Code takes only the window from config; its cost stays `total_cost_usd`. A malformed Codex usage notification sets the flag and does not stop the provider, as a value outside the wire bound does. A test of "a price set comes whole from one source" against a second source waits for the catalog of #560; the tier test covers the config half.

## Round 1 (full)

Simplify, four agents. Fixed: `Helyx.Usage.unpriced/1` in Core, used by `Loop` and Codex `Items`; one accumulator in `cost/2`; `check/3` prepends; `OpenAI.Events` prices the usage at its chunk. Skipped: a redesign of a priced zero; the events default that only tests use; the duplicate `models/1` test helper; one lookup per OpenAI call (it reads the app env only).

Bounds sensor (after simplify):

```
bounds sensor: 10 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | Codex, failure path | **A Codex usage notification with a bad shape (`last` null or missing, `tokenUsage` not a map) did not set the flag**, so a `done` after it had an exact `:list` cost that left the call out. Reproduced by both | Fixed: a bad shape sets the flag. Test: `usage_test.exs`, "a usage notification with a bad shape sets the flag" (five shapes). Codex asked to stop the provider; the flag is kept, as for a value outside the wire bound |
| 1.2 | failure path | A model that is not a binary raises in `lookup/3` | Rejected: the spec types the model as `String.t()`. In the `Loop` Task a raise is a `task_exit` turn error; in `init/3` it fails the start |
| 1.3 | spec | "A price set comes whole from one source" has no test against a second source | Deferred to #560 (the catalog step is a stub). Accepted above |
| 1.4 | spec | The sub-agent test sent the started and the completed lines | Kept: the flag is set at the first line |
| 1.5 | spec | The `Loop` flag after a `stream/3` refusal had no test | Fixed: the model `refuse_int` in `loop_test.exs` |
| 1.6 | spec | The feature doc said that each provider prices with `price/2` | Fixed: `codex` and the OpenCode gateways |
| 1.7 | spec | `cost/2` relied on the tiers that `lookup/3` sorted | Fixed: `cost/2` takes the largest size under the prompt, whatever the order; the tier test runs both orders |
| 1.8 | standards | `info` was a bare map | Fixed: the struct `%Helyx.ModelInfo{}` |
| 1.9 | standards | Stale `Meter` comment `start/1`; the field `config` | Fixed: `start/2`, `config_window` |
| 1.10 | standards | Judgement: the name `lose/2`, `wire_window?` for a tier size, the `price_set` flag argument, the terms of the flag, the nil-or-add copy, the events default, the duplicate test helper, the `call_cost` constants | Kept |

Round 1 reproduced a defect (1.1).

## Round 2 (full: the fix changed 73 code lines in four files and added a struct and a clause)

Simplify, four agents. Fixed: the bad-shape check moved into the one `with` of the usage clause (one `else` sets the flag); the tier choice is `Enum.max/2` with an empty fallback; `check/3` calls `check_key/4` (Credo nesting depth). Skipped: none.

Bounds sensor (base: the state before the round 1 fix):

```
bounds sensor: 6 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | Codex, spec, failure path | **A `last` map with no `inputTokens` or `outputTokens` was priced as a call of 0 tokens, and the flag stayed clear** (`Map.get(last, key, 0)`). Reproduced by all three: a priced call, then `last: {}`, gave a `:list` cost | Fixed: `inputTokens` and `outputTokens` are required; a missing cache count is 0 (the fake and older lines leave them out). Test: three more shapes in the bad-shape test of `usage_test.exs` |
| 2.2 | standards, spec, failure path | **A usage notification of this thread with no `turnId`, a `turnId` that is not a string, or the id of another turn was dropped with no flag** (`codex.ex`, the last `turn_notification/3` clause). Reproduced through the provider process with `CodexFake`: the `done` had a `:list` cost without the dropped call. The research note states that each such notification has the running turn's id | Fixed: the clause calls `Items.stray/2`, which sets the flag for a usage notification. Test: `harness_config_test.exs`, "a usage notification with no running turn id makes the cost nil" (nil, 7, another id; it fails without the fix). `codex.ex` stays at 527 lines (a comment reflow) |
| 2.3 | standards | The feature doc named only a value outside the wire bound for the `codex` flag | Fixed: it names each case |
| 2.4 | standards | Tiers with equal sizes: `Enum.max` compares the price maps | Kept: the choice is the same for each order (probes of the spec and failure-path reviewers); the doc rule "the largest size wins" holds |
| 2.5 | spec | The struct return of `lookup/3` had no test (a map pattern) | Fixed: the test matches `%ModelInfo{}` |
| 2.6 | spec | No test sets config prices for `claude-code` and checks that its cost stays `total_cost_usd` | Kept: `claude_code.ex` passes only `info.context_window` to `Meter.start/2`; the prices do not reach `Meter`. Low |

Round 2 reproduced defects (2.1, 2.2), so round 3 is the last round.

## Round 3 (full: the fix added `Items.stray/2` and touched two code files, 17 lines added and 7 removed; last round)

Simplify, the four angles in two agents. No fix. Skipped: one `lose/1` for `stray/2` and `sub_agent/1` (the clause in `codex.ex` would pass its line limit); a call of `Items.notification/3` with nil params in place of `stray/2` (it hides the reason).

Bounds sensor (base: the state before the round 2 fix):

```
bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 3.1 | standards, spec, failure path, Codex | **A usage notification with no `threadId`, or `threadId` null, is dropped by `dispatch/2` with no flag**, so the next `done` keeps a `:list` cost without the call. Reproduced through `CodexFake` and `Codex.info/2`. The research note states that every notification has `threadId`, so the line breaks the contract | Open at the limit of three rounds. Fixed after it by owner decision, and reviewed in round 4 |
| 3.2 | Codex | **The OpenCode usage chunk maps a missing or null `prompt_tokens` or `completion_tokens` to 0** (`openai/events.ex`, from #557), and `price/2` now gives that call a `:list` cost: `usage: {}` gives cost 0.0 | Open at the limit of three rounds. Fixed after it by owner decision, and reviewed in round 4 |
| 3.3 | failure path | A child thread runs past its parent's turn (research note: the first child notification came 0.77 s after `turn/completed`). The first `done` has cost nil, the flag clears, and a later `done` has a `:list` cost without the child's calls | Kept: the sub-agent ceiling of the feature doc. The `done` of the turn that started the child has cost nil, so the footer total shows `≥` while that message is in the session. The feature doc now says so, and names `dispatch/2` as the place that drops the child's notifications (standards) |
| 3.4 | spec | Guarantee table of the `codex` flag sentence: interrupted or failed (`usage_test.exs`), a bad shape and a missing count (`usage_test.exs`), outside the wire bound (`usage_test.exs`), no running `turnId` (`harness_config_test.exs`), a sub-agent (`child_threads_test.exs`), the `done` clears the flag (`usage_test.exs`) | — |

Round 3 reproduced defects (3.1, 3.2), and it is the last round. The first commit (`a30ac38`) held only reviewed code and reported 3.1 and 3.2 as open.

Precommit (`HELYX_SLOW=1`, after round 3): passed. Root 506 tests, bundled 679 tests and 2 properties, `coding_agent` 34 tests, Dialyzer 0 errors.

## Round 4 (reduced: spec and failure path; an owner-approved exception to the limit of three rounds)

The owner decided on 3.1 and 3.2 (coordinator message, 2026-10-13): fix both now and run one reduced round. 3.1: a Codex `thread/tokenUsage/updated` with no `threadId`, or `threadId` null, sets the flag: the last `dispatch/2` clause calls `Items.unrouted/2`. Test through the provider: `harness_config_test.exs`, "a usage notification with no thread id makes the cost nil". 3.2: an OpenCode usage chunk with a missing or null `prompt_tokens` or `completion_tokens` gives cost nil; the count is 0 as before. `Events` prices the usage where it maps it. Test: `events_test.exs`, "a usage with a missing or null prompt or completion count has no cost" (`{}` and four partial usages). Both tests fail without the fix. The feature doc names both cases. Invariant of the brief: a usage has a list cost only when every model call since the previous `done` is priced and fully counted; any missing or unreadable count makes the cost nil.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 4.1 | spec, failure path | **A Codex usage line with no readable thread id other than a missing key or null is dropped with no flag**: `threadId` 42 or `""`, `params` null, no `params` key (reproduced through `CodexFake`: each `done` had a `:list` cost), and `params` that are not a map (`Items.unrouted/2` called with the line). The research note states that every line has a string `threadId` | Open at round 4 (owner rule for that round). Fixed after it by owner decision, and reviewed in round 5 |
| 4.2 | failure path | Two cases need an owner decision: a usage line with a string `threadId` of a thread that is not in `state.agents` (now dropped, as a child thread's); a usage line sent as a request, with an `id` (`dispatch/2` answers "not supported" and drops the count) | Owner decision: no change. A good usage line with a string `threadId` of an unknown thread stays dropped, under the documented child-thread ceiling. A usage line sent as a request keeps the generic "not supported" answer |
| 4.3 | spec, failure path | No defect in the OpenCode path: `{}`, partial and null counts give cost nil; a later usage chunk replaces an earlier one; a stream with no usage chunk gives the unknown usage. `Loop` sets the flag on an error, `:stream_ended`, `:provider_behind`, a killed Task, and a Task `:DOWN`. Not reached: a retry after a transport error before the headers (no evidence of billing), a gateway whose `completion_tokens` leaves out reasoning tokens (no recorded chunk) | — |
| 4.4 | spec | "(the count is then 0)" for a missing OpenCode count has no assertion | Kept: `field(usage, key, 0)` is unchanged from #557, and its tests cover it |

Round 4 reproduced a defect (4.1). By the owner rule, the reviewed fixes of 3.1 and 3.2 were committed (`494c233`), and 4.1 and 4.2 were reported as open.

Precommit (`HELYX_SLOW=1`, after round 4): passed. Root 506 tests, bundled 681 tests and 2 properties, `coding_agent` 34 tests, Dialyzer 0 errors.

## Round 5 (reduced: spec and failure path; a second owner-approved exception)

The owner decided on 4.1 (coordinator message, 2026-10-13): one catch-all clause. Every `thread/tokenUsage/updated` line that is not the one good shape (a map `params`, a `threadId` that is a string and not empty, a map `tokenUsage.last`) sets the flag. The owner also decided 4.2 (see that row). The change: one `dispatch/2` clause in `codex.ex` sends every usage line to `Items.usage/4`. `Items.usage/4` adds a line of the running turn of this thread, drops a good line of another thread, and sets the flag for any other line. It replaces `Items.stray/2`, `Items.unrouted/2`, and the usage clause of `Items.notification/3`. `codex.ex` stays at 527 lines (two comments are shorter). Test through the provider: `harness_config_test.exs`, "a usage line with no readable thread id makes the cost nil" (no `threadId`, null, 42, `""`, no `params`, `params` null, `params` a list); it fails on the code of round 4. Invariant of the brief: a usage line that is not the good shape never leaves a known cost. The brief closed per-shape findings by the catch-all, and asked for evidence for a handler of a shape that no real Codex sends.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 5.1 | spec | No defect. Every usage line reaches `Items.usage/4`; a line with an `id` gets the generic "not supported" answer (owner decision 4.2). Probe through the fake: a good child line is dropped with a known cost (the ceiling); a good line of the running turn is added; a child line with a bad `last` sets the flag. Guarantee table: no readable thread id (`harness_config_test.exs`), no count, a value outside the bound, and no running `turnId` (`usage_test.exs`), a good line of another thread (`usage_test.exs`, unit only), the good path (`harness_config_test.exs`, `usage_test.exs`) | — |
| 5.2 | spec | Optional: no committed test sends a good child line or a usage line with an `id` through `dispatch/2` | Kept: the probe covers both; the clause order is the same as for every other line with an `id` |
| 5.3 | failure path | No defect. Probe through the fake and the session: a good line of the running turn is added; a good child line (ASCII and multibyte id) is dropped; a child or own line with a bad `last`, no `tokenUsage`, `tokenUsage` null, or no `turnId` sets the flag; a line with `"id": null` is a request (JSON-RPC 2.0) and gets "not supported". A child line with a bad shape now sets the flag (before: dropped). Not reached: a late line after `turn/completed` (path unchanged), a line before the `turn/start` answer, a failed resume | — |

Round 5 reproduced no defect.

Precommit (`HELYX_SLOW=1`, after round 5): passed. Root 506 tests, bundled 681 tests and 2 properties, `coding_agent` 34 tests, Dialyzer 0 errors.

## Round 6 (reduced: spec and failure path; the rebase on master `8b6698b`)

Master merged #552 (harness `/compact`), #564 (Claude Code meter: open `Agent` calls), and #558 (TUI footer). The three commits of the branch were squashed into one and rebased. The rebase was not mechanical in `codex.ex`, `codex/items.ex`, `claude_code/meter.ex`, `usage-and-limits.md`, and `footer_usage_test.exs`. `Items` keeps both `compact?` and `lost?`: a compaction turn ends `done` with usage nil, and `next/2` keeps the sum and the flag. `Meter` keeps both `config_window` and `agents`. `footer_usage_test.exs` calls `Items.usage/4`. `codex.ex` stays at the 496 lines of `.credo.exs`: four comments are reflowed and one blank line is gone. New test: `usage_test.exs`, "a priced compaction call goes into the cost of the next done, once". Invariants of the brief: a usage has a `:list` cost only when every model call since the previous `done` is priced and fully counted, and every usage line that is not the good shape sets the flag (#559); the compaction call's cost lands once in the next `done`, and a compaction turn does not reset the sum (#552).

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 6.1 | spec | No defect. Code, tests, and both feature docs agree with the two invariants and the #564 rule; no "waiting for #559" text is left; the #552 and #564 text survived. Probe through the fake with config prices: the `done` after a priced compaction costs two calls, the next one call; a bad line in a compaction turn makes the next cost nil; a good child line keeps it known | — |
| 6.2 | failure path | No defect. Probe through the fake and the session: a compaction turn that ends `completed`, `interrupted`, or `failed`; a bad line and a sub-agent in a compaction turn; a late line after `turn/completed`. The compaction call is counted once, and the flag survives into the next `done`. Unit probe of `Meter`: `config_window` with an open `Agent` call at `aborted_tools` gives cost nil and the config window; a `/compact` result does not move the mark. Not reached: a usage line while `turn` is `:compact` (the code sets the flag; `turn/started` comes first, research note) | — |
| 6.3 | spec | Note outside #559: `harness-compaction.md` says "Until Helyx shows a window, there is no limit that the program must match"; Helyx now shows a window. The text is about `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | Not changed here: the decision belongs to the footer and compaction tickets |

Round 6 reproduced no defect.

Precommit (`HELYX_SLOW=1`, after round 6): passed. Root 526 tests, bundled 729 tests and 2 properties, `coding_agent` 34 tests, Dialyzer 0 errors.
