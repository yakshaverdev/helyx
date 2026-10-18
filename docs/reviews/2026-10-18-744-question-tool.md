# Review: the question tool (#744)

Feature doc: `docs/features/question-tool.md`. Base of round 1: `HEAD` (`9787a062`, the branch point). `origin/master` moved to `a7160116` (#471 skills) after it, so `git diff origin/master` also shows those files as reverts. Base of round 2: `b85448b9`, a commit object of the round-1 tree, made with `git commit-tree`, so that the diff holds only the round-1 fixes.

Invariant: a running tool call of the current turn can ask the clients with `Helyx.Tool.ask/1` only while a subscriber with `answers: true` is subscribed; the session emits `ask` and keeps the ask in the snapshot, gives the first valid answer (a JSON object of valid UTF-8, at most 16 KiB) to the call, and ends each ask with exactly one `ask_end` before `turn_end`, also when the call ends first.

## Round 1 (full)

Simplify (4 agents): applied before the review; see the devlog.

Bounds sensor (base `HEAD`):

```text
bounds sensor: 21 candidate functions, 3 flagged, 0 without an answer
  lib/helyx/interfaces/tool.ex:218  WAIT  def unhold(handles) when is_list(handles) do
  plugins/bundled/clients/tui/lib/helyx/tui/view_model.ex:215  SIZE  def apply(vm, %Event{type: :ask, data: data}) do
  plugins/bundled/lib/helyx/tool/agent.ex:48  SIZE  def run(%{
```

The flags: `unhold/1` and `agent.ex` are code of #735, which the diff touches only at the tool list; the asks of the view model hold at most one entry for each running call (8, the cap of #734).

Counts: Codex 2 (medium), failure path 1 (the same as Codex 1), spec 5, standards 1 hard and 7 judgement calls.

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | Codex, failure path | the picker took an earlier answer so large that a later question could not be answered under 16 KiB, and the send failed after the last question | yes | `fits?/2`: an answer goes on only while the answers so far and the longest option of each later question fit; test "an answer goes on only with room for each later question" |
| 2 | Codex | an ask stayed open after its Task died: no `ask_end`, and the snapshot kept it | yes | `Asks.call_end/2` in `ToolRuns.result/3`; test "a call that ends while it asks ends its ask" |
| 3 | spec | Escape went to a search that the picker hides | yes | Escape aborts also over a hidden search; test |
| 4 | spec | the Other line showed less than fits the row | yes | the tail by columns; test at 64 columns |
| 5 | spec | the result text did not match the feature doc | read | the doc states the exact text |
| 6 | spec, standards (hard) | a wire `answer` that is not an object gave `invalid_answer`, not `bad_params` | yes | `object/1` in the ops; test |
| 7 | spec, standards | guarantees with no test: multi-select Enter with no mark, the picker of another tool, the rows in the room, the fold and the snapshot | read | tests added |

Judged and not changed: the subscriber entry stays a 4-tuple (one more field on the existing shape); `:invalid_limit` for a bad `answers` flag (the existing subscribe error); the agent tool names `question` (ticket decision 8); test helpers not shared; the JSON walker of `Input` kept (it checks the answer at the boundary).

## Round 2 (full)

The fix diff (without tests and Markdown) changes about 100 lines in 5 code files and adds functions (`call_end/2`, `object/1`, `fits?/2`, `longest/1`, `tail/2`): a full round.

Simplify (4 agents): applied one Escape clause in `Helyx.TUI` (it was copied in `Helyx.TUI.Question`; reuse, simplification, and altitude agents), `Helyx.Message.encoded_size/1` in `fits?/2` (reuse), `finish/1` through `call_end/2` (simplification). Skipped: a budget cap while typing (altitude; Enter checks it, and the footer says why), `longest/1` sizes cached in `sync` (efficiency: at most 16 small encodes at Enter).

Bounds sensor (base `b85448b9`):

```text
bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer
```

Counts: Codex 0 (verdict approve), failure path 0 defects and 1 duplicate check, spec 0 defects, standards 2 hard (docs) and 4 judgement calls. No defect was reproduced, so the loop ends.

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | standards | the bounds rows of the answer in both feature docs still said `invalid_answer` for a value that is not an object | read | fixed |
| 2 | standards, spec | "read from at most 4 bytes for each column" in the feature doc had no test | read | the doc row states only the shown tail, which a test checks; the read bound is a comment at the code line |
| 3 | standards | `@max_other_bytes` also bounds the whole answer | read | renamed `@max_answer_bytes` |
| 4 | failure path, spec | `reject(:invalid_answer)` cannot run: `fits?/2` makes the same size check before the send | yes (call tracer) | kept: it is the answer to the result of the Core boundary, which the TUI does not own, and a terminal paste is not proven valid UTF-8 |

Judged and not changed: `tail/2` stays in the picker (one caller); `fits?/2` keeps room for the longest option, so each later option can still be picked (the doc states it); the ask test reads the asks of the session state to find the Task (no other seam names the caller); the Escape guard names the order of picker over search (the comment states it).

### Guarantee table (round 2 spec agent)

| Guarantee | Proof |
| --------- | ----- |
| a call that ends while it asks gets `ask_end :ended`; a later answer gets `not_waiting` | `test/helyx/session/ask_test.exs:115` |
| `ended` when the call or the turn ended first (wire doc) | `ask_test.exs:115`, `:79` |
| the result text | `plugins/bundled/test/helyx/tui/question_test.exs:113`, `:124`; `plugins/bundled/test/helyx/tool/question_test.exs` |
| Escape aborts, also over a hidden search | `tui/question_test.exs:135`, `:172` |
| an answer goes on only with room for each later question | `tui/question_test.exs:155` |
| the Other text is at most 16,384 bytes | `tui/question_test.exs:147` |
| the Other line shows the tail that fits the row | `tui/question_test.exs:185`, and the agent's CJK and ZWJ probe |
| a wire `answer` that is not an object gives `bad_params` | `plugins/bundled/test/helyx/transport/web_socket_answer_test.exs:108` |
| `Input` also checks the request of a tool | `ask_test.exs:134`, `:142` |

Open: the `not_waiting` and `session_not_found` footer texts of the picker have no test.

## Round 3 (full)

The precommit after round 2 failed on Credo strict: "Struct has more than 31 fields (32 found)" (`Helyx.Session.Server.State`, the new `asks` field) and an alias order in `asks.ex`. The fix moves the open asks into `Helyx.Session.Turn`: an ask exists only for a running call of the running turn, so the asks go with the turn. Base: `71f86d41`, a commit object of the round-2 tree with the three files before the move. The fix changes three code files, so the round is full.

Simplify (4 agents): applied one reader `asks/1` and one writer `put_asks/2` in `Asks` (simplification), which also removed the two fallback clauses; rewrapped the `Turn` comment (altitude nit). Skipped: the asks inside `ToolQueue.running` (altitude, not advised by the agent: it puts `GenServer.from` in the pure queue); `finish/1` emitting directly (simplification, optional).

Bounds sensor (base `71f86d41`):

```text
bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer
```

Counts: Codex 0 (verdict approve), failure path 0, spec 0 defects in the delta and 1 older hole, standards 0 hard and 4 judgement calls. No defect in the delta was reproduced, so the loop ends.

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | spec | a background Task of an earlier turn whose call id a later turn reuses can ask in the later turn: `Asks.ask/5` checks the call id only, and that Task waits with no reply | yes (a throwaway provider that reuses `x1` across turns) | accepted hole: it needs a provider that reuses a call id, which `lib/helyx/session/tool_queue.ex:39` states no real provider does (#369), and a background run that asks; no bundled tool does. No evidence of a real case, so no handler (`docs/agents/review-checklist.md`, "Inputs from plugins") |
| 2 | standards | `put/2` is a bare verb | read | renamed `put_asks/2` |

Judged and not changed: `ask/5` reads the asks through `asks/1`, not from its head (one reader); the ask entry stays a tuple (8 entries at most, read only in `Asks`); the ask test matches the turn as a map. The failure-path agent also saw that a second `subscribe` without `answers: true` clears the answer flag of the subscriber: that is the documented rule, each subscribe states it.

## Rebase and round 4 (reduced)

The branch was rebased onto `origin/master` `485c9452` (#471 and #745 skills, #769, #776). One conflict: the plugin list of `apps/coding_agent/lib/coding_agent.ex` takes both `Helyx.Tool.Skill` and `Helyx.Tool.Question`. The skills code added three lines to `Helyx.TUI.mount/1`, so `tui.ex` had 403 lines. The Escape clause became a `do:` form with `tap/2`, and the mount comment over the overlay fields went (the render `cond` names them), which brought the file back to 400. Master's `:helyx_session` key for `Helyx.Tool.transcript/0` stays as master has it; `Helyx.Tool.ask/1` keeps the session by its registry name.

The fix changes 7 lines in one code file, with no added function: a reduced round (spec and failure-path agents). Counts: spec 0, failure path 0. The spec agent drove Escape and Enter with a real skill in the composer: Escape aborts, Enter answers the question and does not submit or expand the composer. The failure-path agent drove 12 Escape cells (picker, search, key kind) and the picker render at widths and heights from 1 to 14. Open: no test asserts that `CodingAgent.plugins/0` holds both tools.
