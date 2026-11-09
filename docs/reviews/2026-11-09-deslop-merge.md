# Review of the merge of master into the deslop branch, 2026-11-09

Scope: the resolution of the merge of `master` (9bebab64, the hooks: `before_tool`, `after_tool`,
`before_settle`, the continue turn) into `deslop/2026-11-06` (c816f3c9, `State.phase` from
`Helyx.Session.Server.Flow`, the revoke of background runs, the `Queue` ledger). Merge base
b67f4ea2. Each reviewer read every hand-resolved file against both parents
(`git diff HEAD`, `git diff MERGE_HEAD`).

## The resolution

- `Server.Settle` and `Server.Asks` (master) are ported from `State.activity` to
  `State.phase`: a running wait is `%Waiting{wait: %Wait{}}`, a turn is `phase.turn`.
- `Wait.finish/3` ends in `Settle.finish/3`; `Wait.abort/2` ends in `Settle.abort/1`;
  `TurnLoop.progress/1` starts a due chain when the wait has no other part, and settles only
  with `settle: nil`.
- A background entry in the hands keeps its turn id (branch), with master's
  `{:started, {status, text}}` call and `{:started, result, pid}` result.
  `Hands.Outcome.of/4` takes a background end of any turn id.
- `Queue` keeps the branch's ledger with master's `continue` and `hook_turns`; `Queue.Sent` and
  `Queue.Ends` go to their own files, which their module names name.
- `TUI.Wire.Decode.origin_kind!/1` is one clause with a guard, and the file is at 399 lines.
- Tests: the branch's revoke tests take master's start answer and `FakeSession`; the slow
  test of `Wire.Connection` reads `subs.subs` (the branch made `subs` a
  `%Subscriptions{}`; the precommit of the branch did not run slow tests); the 100,000-file
  recall keeps master's load margin, and the branch's write guard is `@load_write_ms`.

## Bounds sensor (round 1, `--diff HEAD`)

```text
bounds sensor: 49 candidate functions, 7 flagged, 0 without an answer
  lib/helyx/interfaces/tool.ex:175  WAIT  def unhold(handles) when is_list(handles) do
  lib/helyx/interfaces/tool.ex:232  WAIT  def background do
  lib/helyx/interfaces/tool.ex:249  WAIT  def started(text) when is_binary(text) do
  lib/helyx/session/ask.ex:22  WAIT  def await_go do
  lib/helyx/session/ask.ex:38  WAIT  def ask(kind, request) do
  lib/helyx/session/file/scan.ex:96  SIZE  def locate(dir, id) do
  lib/helyx/session/hands/chain.ex:112  WAIT  defp step(module, ms, point, input, record) do
```

All flags are in master's own code, reviewed on master. The merge does not change them.

## Round 1 (full)

Simplify: three cleanups (a redundant head match in `Settle.finish/3`, one alias line in
`Wait`, a comment reflow in `TurnLoop`).

| Finding | Source | Resolution |
| --- | --- | --- |
| `close_switched/1` moved to `Connect` for the line limit; it makes a `Flow` transition, and `TurnLoop` is their one owner (AGENTS.md, a split only where a module owns its decisions) | standards | Fixed: back in `TurnLoop`; `arm_idle/1`, a timer, stays in `Connect` |
| `TurnLoop` moduledoc leaves the `before_settle` chain out of the wait | standards | Fixed |
| `Asks.started/3` comment says the hands drop the run from the turn; they keep its turn id for the revoke | standards | Fixed |
| `Settle.put/2` names nothing; its fallback `abort/1` hides the Waiting precondition | standards | Fixed: `put_wait/2`, and `abort/1` matches `%Waiting{}` |
| `Hands` moduledoc and `Helyx.Tool.started/1` lost master's statements (the chain Task runs hooks, the go after the start answer, `:not_running` after the start) | spec | Fixed |
| `session-lifecycle.md` item 6, `wait.ex` moduledoc, `tool-resource-release.md`, `print-background-wait.md` name only the cancel; an abort or a failure revokes | spec, standards | Fixed |
| No test decodes the `hook` origin after the fold of `origin_kind!/1` | spec | Fixed: `decode_test.exs` event list |
| An abort during a running settle chain replaces a pending `wait.hands` request | Codex (high) | Rejected: the chain starts only from the `progress/1` clause with `hands: nil, reply: nil`, and nothing sets `hands` while it runs; the failure-path agent confirmed it by probe. Master's own logic, unchanged |
| An abort during the chain cancels and does not revoke the done turn's background runs (ADR 0014, invariant 4) | spec | Not a merge defect: `before-settle.md` states it and the branch's abort in a wait does the same. Open question for the owner |
| No session test fails a turn and checks the revoke; no session test holds a due chain behind a Dying provider | spec | Not merge defects. The probe of the chain gate passed. Follow-up tests |

Failure path: no defect reproduced. Probes: an abort during the chain with a live
background run of the same turn; an abort during an `after_tool` hook on a background start
answer; an abort that races a counted start answer (session suspended). Not reached: a
provider-error failure (abort covers the same revoke branch), master-side flagged functions.

## Round 2 (reduced)

Spec and failure path on the fix of round 1 only. No defect reproduced, so the loop ends.

| Finding | Source | Resolution |
| --- | --- | --- |
| The `TurnLoop` moduledoc (branch text) calls it the one owner of the `Flow` transitions; `Wait.finish/3` and `Compaction.submit/1` make one each | spec | Fixed: the moduledoc names them |
| No session test revokes the background runs of a failed turn | spec | Repeat of round 1; follow-up test |

Failure path: every caller of `Settle.abort/1` passes a Waiting phase (`Wait.abort/2` only);
every write of `phase:` outside `TurnLoop` is listed, and `Compaction.admit/2` during a turn
always leaves a wait with a hands request (`compaction_test.exs:81`). Not reached: a
compaction during a running chain with a concurrent abort.

## Precommit

`HELYX_SLOW=1 .claude/skills/ship/precommit.sh` after round 2: passed (919, 1192, and 159 tests; Credo and Dialyzer clean).
