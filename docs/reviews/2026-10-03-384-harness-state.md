# Review: providers stop keeping session-owned tool and steer state (#384)

Date: 2026-10-03. Base: `origin/master` at `0ff66c4` (after #381). Scope: `plugins/bundled/lib/helyx/harness_io.ex` (`admit/3` removed, `close/2` added; `keep_port/1` unchanged), `provider/codex.ex`, `provider/codex/check.ex`, `provider/codex/tools.ex`, `provider/claude_code.ex`, `provider/claude_code/mcp.ex`, `provider/claude_code/turn.ex`, `lib/helyx/interfaces/provider.ex`, `lib/helyx/session/provider_process.ex`, `lib/helyx/session/server.ex` (the two `cancel_tool` clauses only), the test fake, their tests, `docs/features/long-lived-harness.md`, and `docs/features/one-provider-path.md`.

## Invariant

The harness providers keep no state that the session owns. Entry points: Codex `info/2`, where an `item/started` of a `userMessage` item of the running turn with a string `clientId` gives `{:user_message, clientId}`, and an `item/tool/call` is admitted only when it maps to an open `dynamicToolCall` item of the running turn with the schema's shape; and `ClaudeCode.Mcp.message/3`, where a `tools/call` is admitted only in a started Helyx turn with a string tool use id, a string name, and arguments that are an object or absent. Every other call gets the one text `the call does not map to a tool use`. The action `{:cancel_tool, call_id}` carries only the call id; the session drops an id that is not open in its running turn (`Tools.cancel/2`). `HarnessIO.close/2` writes the NUL and sets `closing`.

Accepted holes:

- Claude Code does not keep tool use ids; the session checks the call id against its turn.
- A `userMessage` item with a string `clientId` that is not a Helyx steer counts as an item that closes the assistant message in the Codex order check. Not seen in research.
- The Claude Code `calls` map has no bound of its own (unchanged by this diff).

The `{:cancel_tool, ...}` lookup uses `Tools.cancel/2` as master has it; it reads `turn.tool` and `turn.waiting`, not the open calls that #379 changes.

## Removed, and the tests deleted with it

| Removed | Origin | Deleted tests |
|----|----|----|
| Codex `steers` (the set of sent steers) and its use in `Check` | #198, #365 | none; `steer_test.exs` "gives :ok, then its user_message once" and "that the program takes while a call of a closed message runs stops the provider process" pass unchanged |
| `HarnessIO.admit/3`, `ClaudeCode.Turn.admit/3`, the text "no Helyx turn is running" | #243, #246, #369 | none; the call before a turn stays in both admission tests with the one text |
| `turn_id` in `{:cancel_tool, ...}` and in the Claude Code `calls` entries | #198 | none; the withdrawal tests expect the new shape |

Kept: the session's ledger (`Queue.take/2`), `Tools.cancel/2`, `keep_port/1`, `message_end` handling (#385).

## Round 1 (full)

Bounds sensor:

```text
bounds sensor: 4 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/lib/helyx/provider/claude_code/mcp.ex:48  SIZE  def message(%{"method" => "tools/call", "id" => id} = messag
```

The flag is the `calls` map, which this diff shrinks (two ids instead of three) and does not make grow; it is the unchanged accepted hole above.

Simplify (1 agent, covering the four angles): the `HarnessIO` header rewrapped; `Mcp` imports `Turn` by its full name, with no half-used alias. Not changed: one shared error text (each provider keeps its literal, so the two providers share no admission code); one shared steer-item predicate for `Check` and `Codex` (a one-line condition; a shared helper couples the order check to the provider dispatch).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 0 hard, 4 judgement calls on docs, 5 smells | 0 | The `Check` comment names the `item/started` of a `userMessage` with a string `clientId`. `Mcp.call?/2` is now `helyx_call?/2`. The feature doc section is split into one fact per sentence and cites the research note for `item/started` before `item/completed`. Not taken: the shared predicate (as above), returning the values from the check (the match after it is one line), a struct for `{request_id, rpc_id}`, the `#369` references (existing style). |
| Spec | 0 missing, 0 wrong, 3 stale doc lines, 1 test rule note | 0 | `one-provider-path.md` lines 58, 79, 89 and `long-lived-harness.md` "Held events" now give the new shape and rule. The test rows of the call before a turn stay: the case still exists, only its text changed. |
| Failure path | 1 stale doc (same as spec) | 0 | As above. Probed: `params` nil, a list, no `arguments`, `arguments` not a map, a tool use id not a string, a turn nil or not started; `turnId: null` between turns; a cancel of an old turn. Not reached: a Codex `userMessage` with only `item/completed`, the `:slow` and `:real_claude` tests. |
| Codex adversarial | 0 | 0 | Approve. Run again with `CODEX_COMPANION_APP_SERVER_ENDPOINT` unset (the shared broker can review another worktree); the second run named the files of this change and approved too. |

No reproduced defect, so the loop ends. The fixes are doc, comment, and naming fixes of a round with no defect, so they get no further round.
