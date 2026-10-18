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

## Merge gate finding: the ask id

The Codex merge gate reproduced a defect (`.git/orchestrate/744-codex-gate-1.txt`): asks were keyed by the call id, so with two clients and one call that asks twice, a late answer to the first ask resolved the second. Owner decision: each ask has its own id, made by the session, the key of `ask`, `ask_end`, the snapshot, `Helyx.Session.answer/3`, and the wire `answer` op; protocol 3 stays, and the schema SHA changes.

The regression test ("a late answer to an ended ask is refused; the next ask of the call stays open", `test/helyx/session/ask_test.exs`, model `ask_twice`) failed first on the code of `95f35d0b`: the late answer got `{:late, :ok}`, and the tool result was `{"n":1}\n{"n":2}`.

### Round A (reduced: spec and failure path), base `95f35d0b`

The first fix made the id from the call id and a count of the asks of the turn. Counts: spec 1 defect and 1 stale doc, failure path 2 defects.

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | spec, failure path | the count restarts with each turn, so a call id reused in a later turn gives the same ask id, and a stale answer reached the new ask | yes (Test provider, abort, then a new turn) | the ask id is a new random id (`Helyx.Session.Id.new/0`); the counter is gone |
| 2 | failure path | two open asks of one call (a tool that asked from a second process with a copy of the private `:helyx_call` key) crashed the session in `take/3` | yes | `call_end/2` ends every ask of the call with `split_with`; the state is not reachable through a public path (round B, standards), so it has no test |
| 3 | spec | the `Helyx.Tool.ask/1` doc said the event carries the call id and the tool name | read | fixed |

### Round B (full), base `95f35d0b`

The fix of round A changes two code files and removes a field, and it is the second finding on one mechanism: a full round.

Simplify (4 agents): applied `ask_id` inline in the regression test and the `Helyx.Session.Id` comment. Skipped: a single late client instead of two (the owner asked for two clients), entries `{from, ask}` with one predicate (the key lookup with `List.keytake` stays). The empty-asks clause of `call_end/2` (efficiency) was added, then removed in this round: standards and failure path showed that it changes nothing.

Bounds sensor (base `HEAD`):

```text
bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer
```

Counts: Codex 0 (verdict approve), standards 2 hard (docs) and 7 judgement calls, spec 0 defects, failure path 1 window older than this change. No defect in the change was reproduced, so the loop ends.

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | standards (hard), spec | decision 7 and the bounds row described more than one ask for each call, with no bound, but `Helyx.Tool.context/0` holds only in the Task of the call | read | the text and the bound are back to one ask for each running call, at most 8; the `ask_together` test tool and its test are removed |
| 2 | standards | the doc paragraphs of `Helyx.Event` and `Helyx.Tool.ask/1` were not wrapped; a test file was not formatted | read | fixed |
| 3 | failure path | an answer after the asking Task died and before its result reached the session gets `:ok` and `answered`, and the call never takes it | yes (hands suspended) | accepted hole, stated in decision 5: the window is older than this change, and the Task dies in an ask only by a crash or a kill |
| 4 | standards, failure path | the empty-asks clause of `call_end/2` is redundant | read | removed |
| 5 | standards | `ended/2` reads as a predicate | read | renamed `end_asks/2` |
| 6 | spec | no test that a second ask of the same call gets a fresh picker | read | test added in `plugins/bundled/test/helyx/tui/question_test.exs` |

Judged and not changed: the ask entry stays a tuple with the id as its key; the kill test reads the asks of the session state to find the Task; `test = self()` as in the other tests of the file. Accepted: the id is random (72 bits), as every other id of the session; a provider that reuses a call id across turns is outside the contract (#369), and the Test provider runs no tool for such a call.

### Rebase onto `3c289be0` and round C (reduced)

The rebase brought #779: the connection checks the params of a request with `Ops.check/3` before its worker, and runs the returned closure in the worker. The `answer` op became a `check/3` clause that returns `{:ok, fn -> Session.answer(session, ask_id, answer) end}`, the only conflict. The schema SHA still matches the doc, and the protocol stays 3. Counts: spec 1 defect and 1 stale doc, failure path 1 defect (the same mechanism).

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | spec, failure path | `check/3` checks only that `answer` is a map, so a worker holds the whole decoded value of a frame of up to 25 MiB, 8 to 13 times its JSON text, against the bounds row "params of a request worker" of #779; `Input.json_object/2` then walks and encodes the whole value before it compares the size with 16,384 bytes. A 26 MB `answer` peaked at 2.2 to 4.0 GB of VM memory | yes (closure size with `:erts_debug.flat_size`; a 26 MB answer over the wire) | **open**. This is round 3 of this fix, and the fix (a size walk that stops past the bound in `Input.json_object/2`, and the same bound at the check stage before the worker) touches two code files and changes a function, so the small-fix round does not apply: the code stays as reviewed, and the defect goes to the orchestrator |
| 2 | spec | `docs/adr/0008-client-server-wire.md` lists the operations and did not name `answer` | read | fixed |

The defect is older than the rebase: the walk and the encode of a large answer were there since the wire op came in round 1; #779 states the worker bound that makes it visible.

## The answer bound: the fix of round C (orchestrator round, full)

Owner decision of 2026-10-18: the round C defect is in scope, with one round past the `/ship` limit. Invariant: no answer reaches a session or holds a worker past its stated bound.

The fix:

- `Helyx.Session.Input.json_object/2` checks an answer, and the request of `Helyx.Tool.ask/1`, in one walk that counts the exact bytes of the JSON encode and stops past the bound. A string over the budget is neither read nor encoded, and a map is read one key at a time with `:maps.iterator/1`. `Helyx.Session.check_answer/1` is the public check, and `Helyx.Session.answer/3` goes through it, so the TUI and the wire get the same check.
- The transport: the op of a request is a key in its JSON text, so `Helyx.Transport.WebSocket.Frame.decode/2` decodes every frame in the connection before anything knows its op; to read the op before the decode would need a second parser of the frame text. That decode is the existing codec of master for every op, with its own bound (a joined frame of at most 25 MiB, the decoded frame stays in the connection). The smallest change that keeps the worker bound: `Ops.check(core, "answer", params)` runs `Helyx.Session.check_answer/1` in the connection, before a worker exists, and a refused answer gives its worker a closure that holds only the error. No frame size goes through the codec, and the check is exact, so a pretty-printed answer under the bound is not refused.
- Tests: "the size check of an answer is exact at its bound for every shape" and `check_answer/1` at 16,384 and 16,385 bytes (`test/helyx/session/ask_test.exs`); "a 25 MiB answer is refused before its worker, which holds only the error" (`plugins/bundled/test/helyx/transport/web_socket_answer_test.exs`). The 25 MiB test failed first on the old code in both halves: with the old walk, the check took 199,373,503 reductions; with the old op, the worker's closure measured 36,044,831 words with `:erts_debug.flat_size`, as round C measured it.

Simplify (one agent): merged the scalar clauses of the walk and wrote `items/3` as a `with`. Skipped: a size of strings through `Message.encoded_size/1` (it rescues), a direct `res` from the connection for a refused answer (a new return of `check/3`, a connection clause), a skip of the second check in `Session.answer/3` (it is the public in-node boundary).

Bounds sensor (base `HEAD`, `b39b91d7`):

```text
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

Counts: Codex 1 defect (medium), spec 0 defects and 5 doc or comment findings, failure path 0 defects in the diff, 1 defect outside the diff, and 1 wrong comment. A defect was reproduced, so by the owner's rule only the reviewed code is committed, and the findings stay open.

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | Codex | the walk checks an integer with `Message.big_integer?/1`, which calls `abs/1`: for a large negative integer, `abs/1` copies the whole magnitude before the refusal (262,152 bytes allocated for a 262,144-byte integer; none for the positive one), so the check costs more than its bound for that shape | yes (allocation probe) | **open**: compare with the positive and the negative limit, with no `abs/1`, and add a test of a large negative integer |
| 2 | spec, failure path | the comment of the 25 MiB test says the reduction margin is several hundred times the walk to the bound; measured, the walk takes 352,000 to 406,000 reductions, so the margin is about 2.5 times (a full walk takes about 200 million) | yes | **open**: state the measured margin, or raise the bound to about 10 million |
| 3 | spec | `docs/features/wire-protocol.md`, the row "params of a request worker": its "over the bound" cell still says `bad_params` and no worker, but a refused answer gets a worker that replies `invalid_answer`; and "the one checked object is the answer" is not true, because `origin` is an object too | read | **open** |
| 4 | spec | the `@doc` of `Helyx.Session.answer/3` no longer says that an ask that got an answer, or whose call or turn ended, gives `not_waiting` (cut to keep `session.ex` at 400 lines); the bounds row of the feature doc still states it | read | **open** |
| 5 | spec | no test of an accepted answer's worker heap (the agent measured 87 to 218 KB for the worst 16 KiB answers), and no test of exactness for a map of more than 32 keys, an empty string, or an integer of 100 digits (a fuzz of 20,000 values found no mismatch) | probe | **open** |
| 6 | failure path | outside this diff: `Frame.json/1` lets `JSON.decode/3` raise `SystemLimitError` on an integer of about 4 million digits, so the connection ends with 1011 and takes its subscriptions down; no worker holds the value | yes (socket probe) | **open**, master's codec: a ticket for the transport |
| 7 | spec | the decode in the connection of a 20 MiB answer frame raised VM memory by 801 MiB | probe | accepted: it is the documented codec of every frame ("the decoded frame stays in the connection"), not this change |

## The last round: the small-fix round of the `abs/1` defect (owner decision of 2026-10-18)

The fix (`lib/helyx/data/message.ex`, 8 lines added with one blank line from the formatter, and 3 removed; no added function): `big_integer?/1` and the guard of `cap_integers/1` compare with `@integer_limit` and `@integer_floor` (`-@integer_limit`, a constant), so no part of a large integer is copied. Both used `abs/1`.

Other items of the decision: the comment of the 25 MiB test states the measured margin; the wire doc cell for a refused answer names the worker that replies `invalid_answer`; "the one checked object" is gone; the `@doc` of `Helyx.Session.answer/3` states the `not_waiting` cases in short form (`session.ex` stays at 400 lines); the exactness test has a map of 40 keys, an empty string, and 100-digit integers of both signs. The frame decoder is not touched (a transport ticket).

The new test "a large integer is refused with no copy of its magnitude" (`test/helyx/session/ask_test.exs`) checks both signs in a process with a heap limit of 4,000 words. The integers are literals, on no process heap, so a copy of 10,383 words is the only large term that the check could make. A first form with the integer on the heap was flaky: the heap of a process grows in steps, and the positive case was killed 4 times in 20 with the fix. The literal form, 30 runs of each sign: old code, the negative case killed 30 times and the positive case normal 30 times; new code, both normal 30 times. The test failed on the old code ("1 test, 1 failure").

Round D (reduced: spec and failure path, and Codex). Bounds sensor (base `HEAD`, `4772480d`):

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

Counts: Codex 0 (verdict approve), spec 0 defects and 3 wording findings, failure path 0 defects. No defect was reproduced, so the loop ends. The first spec and failure-path agents of this round stopped at a usage limit before they reported; both ran again.

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | spec | the 25 MiB test comment said 350,000 to 410,000 reductions; a warm run of the test measured 90,000 to 159,000, a first call 372,000 | yes | the comment states 90,000 to 410,000, so the bound is at least 2.4 times the walk to the bound |
| 2 | spec | the heap test comment said the limit is "far over" the rest of the check, which takes 1,500 to 1,600 words | yes | the comment states about 2.5 times the 1,600 words |
| 3 | spec | the `@doc` of `answer/3` named only the asks that were open before, not an id that never was | read | "any other id" gets `not_waiting` |
| 4 | failure path | the review record still marked the `abs/1` finding open | read | this section closes it |

Probes with no finding (the two agents): the old and the new compares agree on 2,055 integers around ±10^100, and on 10^k±2 for both signs at every boundary; the walk equals `byte_size(JSON.encode!/1)` on 4,000 random shapes at the bound and one under; a map of 1,000,000 keys, a list of 3,000,000 items, a list 1,000,000 deep, and a 25 MiB string (valid and not) each cost about 80,000 reductions or less; through `json_object/2`, `Ops.check/3`, `Session.answer/3`, and `Tool.ask/1`, a 200,000-digit integer of either sign is refused with no copy.

Status of the open items of the round before: the `abs/1` defect, the test comment, the wire doc cell, the `@doc` of `answer/3`, and the exactness cases are closed. Open: no test of the worker heap of an accepted answer (probed: 87 to 218 KB for the worst 16 KiB answers); the frame decoder's `SystemLimitError` (a transport ticket of the orchestrator).
