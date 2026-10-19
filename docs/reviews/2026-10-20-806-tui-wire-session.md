# Review: #806, the wire session of the TUI (tui-attach slice 2)

Base: `ad7e578b` (merge base of the branch). The change: `Helyx.TUI.Wire.Connection`, `Helyx.TUI.Wire.Reader`, `Helyx.TUI.Wire.Decode`, two helpers of `Helyx.TUI.Wire` made public, `client_raw/1` in `Helyx.Test.WireClient`, the slice 2 rows of `docs/features/tui-attach.md`.

Invariant: every server frame that the connection reads passes the frame bound, the joined bound, the decode bounds, and the schema of protocol 3 before it reaches the owner as a Core event or a reply; any other frame ends the connection with `{:shutdown, :broken}`.

## Bounds sensor

```text
bounds sensor: 15 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/clients/tui/lib/helyx/tui/wire/connection.ex:155  SIZE  def handle_info({:tcp, socket, data}, %{socket: socket} = st
```

The flag: the buffer of `handle_info({:tcp, ...})`. `Reader.read/2` checks the header of a frame before its payload is whole, so the buffer holds one frame of the bound and one read. The failure-path agent probed a header that claims 5 GB (`:broken`) and random chunking (same messages). Not a defect.

## Round 1 (full)

Simplify: one `send_request/5` for the two request paths, one `sent/2` for the result of a write, `client_raw/1` moved to `Helyx.Test.WireClient`, the parts test built with `Frame.encode/1`.

| Finding | Source | Reproduced | Resolution |
| ------- | ------ | ---------- | ---------- |
| A snapshot with `turn.partial` false or of another role, and a `tool_execution_end` with an assistant message, decode, and the fold crashes | Codex, failure path | yes, through `Connection.subscribe` on the fake server | `Decode` checks the role of each message for its event and the partial (nil or an assistant message); tests in `decode_test.exs` |
| A late reply skips the schema check; the internal `unsubscribe` reply too | Codex, spec | yes (Codex probe of the callback) | every reply goes through `Decode.result/2` first; slow test "a late reply of a broken shape is a contract break" |
| The writes of a large request can stretch the wait of an operation past the deadline and 5,000 ms | Codex | no probe: needs a server that reads each frame just within the send timeout | the moduledoc and the bounds row now count the wait from the moment that the connection takes the request, and state the write bound; accepted hole in the feature doc |
| `tool_call` of `message_update` has no integer cap | spec | yes | `Message.cap_integers/1`, as `Codec.decode/1` does; test |
| Invalid UTF-8 or a tuple from the caller crashes the connection in `Frame.encode/1` | spec | yes | rejected: the TUI is the only caller, and its texts are valid UTF-8 (ExRatatui, `Helyx.TUI.send_message/3`) and its answers come from JSON; a state that only a bug makes crashes (AGENTS.md) |
| The counts that the server keeps (256 items, 1,024 replay events, 64 dropped messages, a 65,536-byte request) are not checked | spec | yes | rejected as code: the frame bounds bound what reaches the owner, and a tail snapshot has no count bound (the newest group); stated as an accepted hole |
| A block of an unknown kind breaks the connection, where wire-protocol.md shows a placeholder | spec | yes | protocol 3 closes the block kinds; stated as an accepted hole |
| "Open, no ticket" breaks the rule "unbounded, ticket #N" | standards, spec | n/a | the hole now says that the report of #806 asks for a ticket; creating a ticket is outward-facing, left to the orchestrator |
| The ownership row of the connection process names no supervisor and no cap | standards, spec | n/a | the row names both |
| Six public operations have no `@doc` | standards | n/a | added |
| The doc says `code` nil for a close of TCP; four more paths give nil | standards | n/a | the moduledoc and the doc name every path; a test of a close frame with no code |
| Missing tests: reserved bit, fragmented ping, ping over 125 bytes, parts out of order, a frame between parts, WebSocket fragments, a header split across reads | standards, spec | n/a | added to `connection_test.exs` |
| `refute_receive ..., 200` with no stated margin | standards | n/a | replaced by a reply of the same connection, then `refute_received` |
| The joined-bound test moves two frames of 25 MiB, about 1 s | standards | n/a | `@tag :slow` |
| "Replaced mechanism" has no line for slice 2 | standards | n/a | "None in slices 1 and 2" |
| Judgement calls: duplicated framing of `Reader` and `Wire.text/3`, the `{op, caller}` tuple, `state.subs[sub] == :live` three times, names `active/1` and `sent/2`, `rem(seq, 1_024)` repeated from `Helyx.Session.ack/2`, the rescue in `Decode` | standards | n/a | kept: slice 1 reads in passive mode with a deadline and the connection in active mode; the rescue follows `Helyx.Session.File.load/3` |

The round 1 state was not saved as a stash or a commit before the fixes; round 2 reads the whole diff against the merge base, with the fixed functions named.

## Round 2 (reduced: spec and failure path)

Base: the merge base; the round 1 state was not saved. A commit object of the tree after round 2, `cded3427`, is the base of round 3.

| Finding | Source | Reproduced | Resolution |
| ------- | ------ | ---------- | ---------- |
| A `compaction` with `tokens_before` 10^400 decodes; `ViewModel.apply/2` raises in `tokens/1` | spec, failure path | yes | `Helyx.Usage.wire_tokens?/1`, the bound of `Helyx.Session.Stream` |
| A snapshot `usage.cost` of 1.0e305 decodes; `Footer.widget/5` raises | spec, failure path | yes | a cap of the total cost (see round 3) |
| A snapshot with an unpaired tool result decodes; `from_snapshot/2` raises | spec, failure path | yes | the snapshot is checked with `ViewModel.from_snapshot/2` itself |
| A `tool_execution_end` result with no `tool_call_id` raises in any state | failure path | yes | a tool result must have its call id |
| A model ref of 1,000,000 bytes or with white space reaches the owner | spec | yes | `Helyx.ModelRef.parse/1` for `model_change` and the snapshot model |
| `start(conn, model: nil)` gives `bad_params` | spec | n/a | wording, fixed: the doc says that `model:` is an optional key and a nil value is `bad_params` |
| An unsubscribe that fails with another code than `unknown_sub` forgets the sub | spec | no (read only) | kept: the server answers `unsubscribe` of a sub that it holds with `{}` |
| The send timeout is the `timeout` argument of `connect/4` | spec | n/a | judgement: `CodingAgent.Attach` passes 5,000 ms, the only caller |

The second finding on one mechanism (round 1: roles and the partial; round 2: counts, costs, model refs, pairs): `Decode` checked the JSON shape only. Round 3 is a full round, and the fix changes the mechanism: `Decode` takes the guards of Core that the fold trusts and checks a snapshot with the fold.

## Round 3 (full: simplify, spec, failure path, Codex)

Simplify: `import Helyx.Usage, only: [wire_tokens?: 1]`, a `subscribe/1` helper in the decode test.

| Finding | Source | Reproduced | Resolution |
| ------- | ------ | ---------- | ---------- |
| The cap of 10^12 USD on the total cost of a snapshot is the bound of one usage; two messages of 10^12 give a total that the client refuses | spec | yes, `Totals.of/1` of two such messages | fixed in the small-fix round, by the decision of the orchestrator of 2026-10-20 |
| An `ask` of the `question` tool with a request that the tool did not make crashes `Helyx.TUI.Question.sync/1` | Codex, spec | yes | rejected as code: a case-specific check of one tool's request, and no evidence that a real server sends it; the tool checks its own request, and the TUI in the node crashes the same way. Stated as an accepted hole |
| Queue counts, `elapsed_ms`, and context fields have no upper bound; 200,000 digits make the footer slow | spec | no: the decode bounds of the transport refuse an integer of more than 1,024 characters, and the failure-path agent measured 2 ms for a snapshot of 1,022-digit counts | rejected |
| The slice 2 bounds table has no row for the new checks; the hole "each event alone" | spec | n/a | wording, fixed |

The failure-path agent reproduced no defect: every round 2 reproduction gives `:error` or `{:shutdown, :broken}`, and a mutation probe of about 50 extreme values for each JSON node of the events and snapshots, through `Frame.decode/2`, the fold, the composer, the footer, the question picker, and the transcript, crashed only on the accepted holes (a result of a call that is not open, the `question` request).

The loop reached its limit here: three rounds and 45 minutes. Commit `667e245b` held the code of round 3.

## Precommit

The first run of `HELYX_SLOW=1 .claude/skills/ship/precommit.sh` failed on `mix credo --strict`: two alias lines out of order (`decode.ex:14`, `decode_test.exs:6`). The fix swaps the two lines. The second run passed: `found no issues`, `Total errors: 0` for the three Dialyzer runs, and `783 tests, 0 failures`, `113 tests, 0 failures`, `4 properties, 1117 tests, 0 failures (1 excluded)`.

## Small-fix round (reduced: spec and failure path)

Orchestrator decision of 2026-10-20: the cost cap is the small-fix round of `/ship`; the round also reviews the alias swap and the doc edits after round 3; the hole of frames over the client bounds is ticket #814, which blocks slice 3 (#807).

The fix: `cost_or_nil?` in `decode.ex` caps the total cost of a snapshot at 10^300, not at 10^12, the bound of one usage. One code file, no new function, 8 lines with the comment. `decode_test.exs` decodes a snapshot whose total is `Totals.of/1` of two messages of 10^12 each (2 × 10^12); the old code refuses it. Base of the round: `667e245b`.

| Finding | Source | Reproduced | Resolution |
| ------- | ------ | ---------- | ---------- |
| The defect of round 3 | failure path | yes on `667e245b`; closed by the fix, through `Decode.result/2` and `Connection.subscribe/2` on the fake server | fixed |
| The test of the cap checks 1.0e300 and 1.001 × 1.0e300 only: a guard of 1.0005e300 passes it; an integer total is reachable | failure path | yes, a copy of the module with that guard | test: the first float over the cap, `trunc(1.0e300)` taken and `trunc(1.0e300) + 1` refused |
| No test draws the footer at a decoded total over 10^12 | spec | no defect: the probe draws `>$99999` at 1.0e300, also after a later message of 10^12 | test: the footer at the cap, before and after a `message_end` of 10^12 |
| The review record still says that the cost cap is open | spec | n/a | fixed |
| The `question` hole says that the tool checks its own request; question-tool.md says that it checks its arguments and makes the request | spec | n/a | wording, fixed |
| "it blocks slice 3 (#807)" has no source in the repo | spec | n/a | kept: the body of #814 says "Blocks #807" |

Both agents found no other path that breaks the invariant: the float and integer totals at the cap fold, take 2,000 later messages of 10^12 with no raise, and draw `>$99999`; `1e400` and an integer of 1,025 digits fail the decode bounds of the transport. The alias order passes Credo; the old order is flagged. The round reproduced no defect of the fix, so the loop ends; its test and wording findings are fixed here with no further round.


## Rebase and precommit of the small-fix round

Rebased onto `650c5e3c` (origin/master). One conflict: `client_frame/1` of `Helyx.Test.WireClient`, where #805 put every read through the capped `read/2`. Resolved: `client_raw/1` uses `read/2`, and `client_frame/1` calls it. The tests of the change pass on the new base (34 tests, 0 failures, with the slow ones).

`HELYX_SLOW=1 .claude/skills/ship/precommit.sh` passed: `found no issues`, `Total errors: 0` for the three Dialyzer runs, and `783 tests, 0 failures`, `113 tests, 0 failures`, `4 properties, 1124 tests, 0 failures (1 excluded)`. The test output of `plugins/bundled` also holds the stderr line `erl_child_setup: failed with error 32 on line 284`.
