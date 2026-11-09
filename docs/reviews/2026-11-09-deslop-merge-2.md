# Review of the second merge of master into the deslop branch, 2026-11-09

Scope: the resolution of the merge of `master` (756cbae1: harness approvals through
`before_tool`, UI blocks, tool sources and MCP, Hub, wire protocol 8) into
`deslop/merge-master` (c7da3f6a, the first merge, `docs/reviews/2026-11-09-deslop-merge.md`).
Merge base 9bebab64. The reviewers read the 71 files that differ from both parents, each
against both parents (`git diff --cached HEAD`, `git diff --cached MERGE_HEAD`).

## The resolution

- `Server.Approvals` and `Server.UIBlocks` (master) are ported from `State.activity` and
  `State.conn` to `State.phase`: `end_turn/2` and `answer/4` match a `%Flow.Up{}` provider.
- `Wait.finish/3`: `Approvals.end_turn/2` and `ToolRuns.end_turn/2` run only with the held
  provider `%Up{}`; the hands get a revoke when the turn is not done, else a cancel when calls
  or approval chains run; the wait holds master's `ui_blocks`.
- `Asks` takes master's answered-call check; `Settle` passes `cwd` and uses
  `State.tool_context/2`; `Connect` uses `state.registry.specs`.
- `Message.JSON` (new, `lib/helyx/data/message/json.ex`) owns the encoded message shape of the
  file and the wire, with master's `ui_blocks` of a tool result; `message.ex` was 419 lines.
- TUI: master's `Wire.fits?/2`, `Wire.carries?/1`, `Frame.max_request/0`, and
  `Ops.deadline/2`; `Link` drops its own size check, as `Connection` checks every request.
- Harness providers: master's Claude Code `Program.turn/2`, `compaction/1`, and Codex
  approvals over the branch's `HarnessIO.Stream`.

## Bounds sensor (round 1, `--diff HEAD`)

```text
bounds sensor: 237 candidate functions, 23 flagged, 0 without an answer
  lib/helyx/interfaces/tool.ex:126  WAIT  def hold(handle) do
  lib/helyx/interfaces/tool.ex:140  WAIT  def unhold(handles) when is_list(handles) do
  lib/helyx/interfaces/tool.ex:252  WAIT  def background do
  lib/helyx/interfaces/tool.ex:271  WAIT  def started(text) when is_binary(text) do
  lib/helyx/interfaces/tool.ex:340  WAIT  def deferred(version, wait_ms)
  lib/helyx/interfaces/tool.ex:355  WAIT  def activate(names) do
  lib/helyx/interfaces/tool.ex:365  WAIT  defp source_call(request) do
  lib/helyx/session/ask.ex:22  WAIT  def await_go do
  lib/helyx/session/ask.ex:40  WAIT  def ask(kind, request) do
  plugins/bundled/clients/tui/lib/helyx/tui/view_model.ex:187  SIZE  defp fold(vm, %Event{type: :model_change, data: data}) do
  plugins/bundled/lib/helyx/hook/command/run.ex:62  SIZE  def run(input, command, cwd) do
  plugins/bundled/lib/helyx/hook/command/run.ex:88  WAIT  def collect(port, out) do
  plugins/bundled/lib/helyx/hub/records.ex:75  SIZE  def handle({:newest, auth, cwd, scanned}, _deadline, state) 
  plugins/bundled/lib/helyx/hub/server.ex:38  SIZE  defp default_owner(mod, store, name) do
  plugins/bundled/lib/helyx/hub/store/sqlite/disk.ex:120  SIZE  defp left_create(path, stat) do
  plugins/bundled/lib/helyx/hub/store/sqlite/records.ex:95  SIZE  def labels(db, session_ids) do
  plugins/bundled/lib/helyx/provider/codex.ex:224  SIZE  defp dispatch(%{"id" => rpc_id, "method" => "item/tool/call"
  plugins/bundled/lib/helyx/subagent.ex:130  SIZE  defp await(child, ref, last) do
  plugins/bundled/lib/helyx/tool/mcp/server.ex:102  SIZE  defp serve(state) do
  plugins/bundled/lib/helyx/tool/mcp/source.ex:75  SIZE+WAIT  defp loop(state) do
  plugins/bundled/lib/helyx/tool/mcp/source.ex:191  WAIT  defp answers(state) do
  plugins/bundled/lib/helyx/tool/session_create.ex:84  WAIT  defp start(env, folder, mode_opts) do
  plugins/bundled/lib/helyx/watchdog.ex:220  WAIT  defp wait_ms(nil), do: :infinity
```

The diff base `HEAD` puts all of master's new code in the scan. The flags are in master's
code, reviewed on master; the resolution changes none of them.

## Round 1 (full)

Simplify: `Settle.finish/3` uses master's `State.tool_context/2`; the TUI `Link` drops its
size check, which repeated `Wire.fits?/2`; `tui-attach.md` names `Frame.max_request/0`.

| Finding | Source | Resolution |
| --- | --- | --- |
| `approvals.ex` comment names the deleted `:ending` status | standards | Fixed: "a provider that is not `%Up{}`" |
| The detach of a switch of a sub that no frame carries gives `:too_large`, so `/new` and `/resume` from that session fail | spec | Fixed in rounds 2 to 4, below |
| `Wait.finish/3` checks `%Up{}`, and `Approvals.end_turn/2` and `ToolRuns.end_turn/2` check it again | standards (judgement) | Kept: `finish/3` reads the held provider, which can be `:none` while `phase.provider` is `%Up{}`; each callee keeps its own precondition, as on both parents |
| `put_turn` is written in two modules and the phase update inline in four more | standards, simplify (judgement) | Not changed: it goes past the merge resolution |
| `sized/4` in `Connection` has a mysterious name | standards (judgement) | Removed in round 2 |
| No test fails a turn and checks the revoke; `session.ex` "`only` opens no tool source" and the client `Ops.deadline/2` have no test | spec | Not merge defects: the first is the follow-up ticket of the first merge; the other two are master's own texts |
| `Message.JSON` gives master's map for a tool result with and without `ui_blocks` | spec | Probe passed (wire and file) |

Codex: approve, no finding. Failure path: no defect reproduced. Probes: an ask answered after
an abort, a provider that stops while an approval chain runs, an approval request after
`done`.

## Round 2 (reduced)

The fix of round 1: `Subscriptions.detach/2` drops a sub that no frame carries locally, and
`Connection.unsubscribe/2` sends no request for it.

| Finding | Source | Resolution |
| --- | --- | --- |
| The detach deleted the sub, so the next `event` or `session_end` of that sub from the server broke the connection | spec, failure path (reproduced) | Fixed: the sub is `dropped`, as a late subscribe reply of such a sub is; the test sends both frames after the detach |
| The busy clause ran before the detach, so the detach of a sub that sends no request could give `:busy` | spec | Fixed: the busy check applies only to a detach that sends a request |

## Round 3 (full: a second finding on the detach)

Simplify: comment and moduledoc wording only.

| Finding | Source | Resolution |
| --- | --- | --- |
| A detach that sends a request checks only the 16 requests that wait for a reply, not the 16 request frames that wait for the writer; under writer backpressure it wrote a 17th frame. The branch had the same check before the merge | Codex | Fixed in the small-fix round: the detach checks both bounds, as every request does; the writer-bound test checks a detach too (red before the fix: `:timeout`) |
| The end of a dropped sub at the server's bound of unacked events is a `4408` close of the connection; the row of `tui-attach.md` did not say so | spec | Fixed: the row and the comments name the `4408` close, the end at `session_end`, and the reconnect of decision 11 |

Failure path: no defect reproduced.

## Round 4 (small-fix round)

The fix touches one code file, adds no function, and changes 2 code lines.

| Finding | Source | Resolution |
| --- | --- | --- |
| A late subscribe reply that carries the sub of a live subscription is not a contract break: the late clauses of `Subscriptions.reply/4` come before the `known?` check, so the connection drops the live sub and sends its `unsubscribe` with no `helyx_end` to the owner. Master checked a known sub before the late path; the branch did not, and the merge kept the branch's order | failure path (reproduced with a fake server), spec of round 1 | Open: the small-fix round reproduced a defect, so the loop ends. Only a server that breaks the contract sends it. Ticket |
| "Detach is busy when 16 requests wait for a reply" has no test | spec | Noted; the writer-bound case has its test |

## Precommit, first run

`HELYX_SLOW=1 .claude/skills/ship/precommit.sh` after round 4 failed in two steps:

- Credo: the alias `Flow.Up` in `approvals.ex` was not in order. Fixed.
- The fixture case "message_update: two deltas" of `wire_fixtures_test.exs` (a case that master
  added) expects the connection to end with `{:shutdown, :broken}`; it ended with `:killed`.
  `Connection.terminate/2` killed the linked writer, and the writer's `:killed` reached the
  connection before its own exit. Both parents have this code. Fixed: `terminate/2` unlinks the
  writer before the kill. Two comments of `connection.ex` are shorter for the line limit.

## Round 5 (reduced, past the limit by the owner's decision)

The loop had ended after round 4. The owner decided on 2026-11-09 to fix the race and review
the fix in one reduced round, because the merge does not pass precommit without it.

| Finding | Source | Resolution |
| --- | --- | --- |
| Why only that case lost the race | failure path (measured) | With the old `terminate/2` the writer, idle in its `receive`, exited 2.7 to 13 ms before the connection in each `:killed` run. Padding the event JSON moved the race to a fixed band of lengths for each case ("two deltas": 1 to 3 spaces; "no turn_id key": 49 to 56): the end of the connection's time slice between the kill and its own exit decides it, not the case. With the fix, a sweep of 0 to 120 gives `{:shutdown, :broken}` for both |
| A crash of the writer ends the connection with the writer's reason, not `{:closed, nil}` | spec | Accepted: no input reaches it (`Wire.fits?/2` encodes in the caller, send and encode errors are tuples); a crash there is a bug, and it crashes |
| End reasons with the writer blocked in a send: broken, close 4000, owner death | failure path | Probes passed |

## Precommit

`HELYX_SLOW=1 .claude/skills/ship/precommit.sh` after round 5: Dialyzer rejected the form
`Process.unlink(writer) and Process.exit(writer, :kill)` (`unlink/1` is always `true`); the same
order is now `writer |> tap(&Process.unlink/1) |> Process.exit(:kill)`.

The next two runs each failed one or two other tests of master, a different one each time:
`sessions_edit_test.exs:538` (`Process.info/2` of an ended Task gives `nil`),
`hub/live_test.exs:84` (the wait for 2 messages in the suspended Hub), and
`hook/command/relay_test.exs:45` (the trap of the HUP ran twice). The merge changes none of these
tests or their code (no diff against master), and each passed 5 or 10 runs alone. The 5-minute
load of the 8-core precommit host was 9.86 during the runs and 2.89 after. The run on the quiet
host passed: 1115, 161, and 1649 tests and 4 properties; Credo, Dialyzer, and the Rust steps clean.
