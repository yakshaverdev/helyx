# Review: the session owns the turn and its Helyx tool calls (#358)

Date: 2026-10-03. Base: `origin/master` at the branch point (`da4ff6a`). Scope: `lib/helyx/session/` (`provider_process.ex`, `provider_request.ex`, `server.ex`, the new `server/tools.ex`, `state.ex`, `stream.ex`, `turn.ex`, `wait.ex`), `lib/helyx/interfaces/provider.ex`, a comment in `plugins/bundled/lib/helyx/provider/claude_code/mcp.ex`, their tests, `test/support/interfaces.ex`, and `docs/features/one-provider-path.md` and `docs/features/long-lived-harness.md`.

## Invariant

The session is the only owner of the live turn and its Helyx tool calls. Every tool request that reaches the session (`{:tool_request, pid, turn_id, call, rejection}`, sent by `Helyx.Session.ProviderProcess` after `Stream.check`) gets exactly one `tool_result` request with an armed kill: its run result, a rejection or too-many error, `aborted` for a turn that is not current, or `aborted` at every turn end (abort, normal end, failure) before the interrupt or the next turn. `cancel_tool`, a reused call id (a bad action: the turn fails and the session stops the provider process with `{:shutdown, reason}`), and `need_context` checked against `Turn.phase` are handled only in the session. The provider process keeps no turn state; `write_result` is removed, because every `tool_result` and `context` request has an armed kill.

Accepted: the `aborted` answer to a request of a turn that is not current is not awaited by the wait, so only the mailbox order puts it before the next turn, and its armed kill can fire during the next turn. Waiting calls get `aborted` after the hands' cleanup, together with the running call, not at once; the order before the interrupt holds. A `need_context` of a turn that is not current is dropped, not a bad action, because it can cross the interrupt. `Turn.ids` grows with the calls of one turn, as `seen` did.

## Round 1 (full)

Bounds sensor:

```text
bounds sensor: 8 candidate functions, 3 flagged, 0 without an answer
  lib/helyx/session/provider_process.ex:80  WAIT  defp loop(proc) do
  lib/helyx/session/server.ex:293  SIZE  def handle_info(
  lib/helyx/session/server/tools.ex:81  SIZE  defp answer(%State{activity: turn, conn: %{pid: pid}} = stat
```

Simplify (4 agents): `Stream.check` returns the `%ToolCall{}`, so the provider process does not build it again; `Tools.request` checks the id before it writes `ids`; the stream comment names the session. Not changed: a timer per answer (the armed kills are the point), a context flag in place of the `:context` phase (the ticket names `Turn.phase`), a shared `aborted` helper, and one field for `tool` and `killed?`.

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 2 docs, 7 judgement calls | 0 | The "Replaced mechanism" table in `one-provider-path.md` still said "kept" for the removed rows, the #358 paragraph broke the table, and the `Wait` and phase rows were old. `long-lived-harness.md` listed the `:tool_start` reply kind. Fixed. Judgement calls not taken: an `open_ids` helper, the phase lists, the `aborted` literal, the stop reason shape, the unused pid on the current-turn path (needed for `late/4`), and `put_in` chains on `Turn`. The Credo entry of `server.ex` goes to 629. |
| Spec | 2 docs, 2 deviations | 0 | `long-lived-harness.md` still described the loop that makes a program turn live (#339) and the #203 rules in the loop. Fixed. Deviations kept and recorded: waiting calls are answered after the hands' cleanup, and a `need_context` of a turn that is not current is dropped. The session stops the provider with `Process.exit/2`; the hands then release it, as for any exit. |
| Failure path | 0 defects, 1 comment | 0 | Eight probes (cancel then end, cancel twice, cancel before a finished result with the session suspended, a program turn during a turn, a rejected id used again, a waiting cancel then abort, a reused open id, the context phase) gave one result per call. The comment on `Tools.answer/3` said no turn starts while its kill is armed; `late/4` is the exception. Comment fixed. |
| Codex adversarial | 1 defect | 1 | Tool result and context requests were in `open`, and the guard counted them against the pool of 8. With eight late tool result answers, the interrupt of an abort got `{:error, :busy}` and the provider stopped before its interrupt callback ran. Fixed (below). |

Fix: the loop counts the pool in a `pooled` field; `tool_result` and `context` requests are in `open` but not in `pooled`. The model `conn/tools_late` (a tool result answers after 100 ms) is back in the test support, and the test "an abort with 8 tool results open still reaches the interrupt callback" fails on the old guard and passes on the fix. Fix diff: about 20 code lines in one file.

## Round 2 (reduced, after the rebase on #359)

The rebase on `origin/master` with #359 (PR #364) had mechanical conflicts in `turn.ex`, `wait.ex`, `server.ex`, `wait_test.exs`, `.credo.exs`, and `one-provider-path.md`: #359 moved the steers out of `Turn` and `Wait`, so `Wait.after_turn/2` and `Wait.answer/4` return only the wait. The Credo entry of `server.ex` is 622.

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Codex adversarial (pool fix and the #359 interaction) | 0 | 0 | Approve: pool count, armed kills, the shared turn-end wait, and a steer in the `:context` phase held in 37 focused tests and 4 probes. |
| Precommit | 1 test | 1 | `apps/coding_agent` `helyx.graph_test.exs` named the removed `Server.run_on_hands/2`; it now names `Server.Tools.run/2`. |

No reproduced defect in the code, so the loop ends.
