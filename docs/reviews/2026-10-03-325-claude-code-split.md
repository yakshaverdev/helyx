# Review: #325 split claude_code.ex and share the tool admission

Scope: `plugins/bundled/lib/helyx/provider/claude_code.ex`, the new `Mcp`, `Replay`, and `Turn` modules under `plugins/bundled/lib/helyx/provider/claude_code/`, `Helyx.HarnessIO.admit/4`, `plugins/bundled/lib/helyx/provider/codex/tools.ex`, `.credo.exs`, the "Claude Code" section of `docs/features/long-lived-harness.md`, and one row each of `docs/features/coding-agent.md` and `docs/features/tool-text-out-of-core.md`.

Invariant: the split and the shared admission change no wire line, event, error term, event order, or bound. Every entry point (`init/3`, `request/3`, `info/2`, `translate/2`, the `tools/call` clause of `Mcp.message/3`, `Codex.Tools.call/3`) writes the same stdin lines and gives the same events and stops as on master. The call id goes into `used` before any error answer, and the three error texts do not change. No call id goes into `used` when no Helyx turn runs or when the call names no id. A steer start keeps the order `close_message`, held notice, `user_message`, and the steer wait stays 5,000 ms.

Step 1: #316 has not merged, so there was no rebase. Line counts: `claude_code.ex` 1000 before, 573 after. `mcp.ex` 134, `replay.ex` 98, `turn.ex` 162. `codex/tools.ex` 99 before, 96 after. `harness_io.ex` 218 before, 240 after. The `.credo.exs` entry is 573. The ticket said "about 550 to 600".

Known failures, not from this diff: `claude_code/turn_test.exs:25` fails locally on macOS (the watchdog text of a 3,200-byte path is 493 bytes, not 2,000). `codex/commands_test.exs:148` fails locally on master too (see the #324 record). The diff changes neither `init/3` nor the Codex line reading. Both pass in `HELYX_SLOW=1 .claude/skills/ship/precommit.sh`, which passed with no warnings (plugins/bundled: 503 tests and 1 property, 0 failures).

Codex was at its usage limit for this round (until 2026-10-04 01:42). On the orchestrator's instruction, a fresh read-only general-purpose agent ran the same adversarial review, with the same invariant and the base `origin/master`, and counts as the Codex reviewer.

## Round 1 (full)

Bounds sensor (`--diff origin/master`):

```text
bounds sensor: 14 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/lib/helyx/provider/claude_code.ex:125  SIZE  def request(
```

The flag is the steer clause. Only its calls changed (`Replay.user_line/2`). The session's steer queue of 32 entries limits the steers, as on master.

| Axis | Findings | Resolution |
|------|----------|------------|
| Simplify | Three copies of the JSON line encoder; `admit/3` took nil for no turn and gave it back, so each caller restored `used` in its own way; Mcp read the turn's `used` and `started?` itself; the comment on `mapped?` depended on clause order in another module; the `calls` tuple described three times; two styles for the call id; a short line in the `HarnessIO` header. Skipped: an `emit/2` clause for an unchanged turn (no measurable cost); tags through `cap_replay` (code moved without change) | `Replay.line/1` is public and the only encoder; `admit/4` takes `running?` and always gives back `used`; `Turn.admit/3` owns the started rule; the `admit` comment says that `mapped?` runs only for a call id of a running turn; `State` points to `Mcp` for `calls`; `Codex.Tools.call_id/1`; header reflowed |
| Standards | No hard violation. Judgement: `line/1` lives in `Replay` but also frames control lines; two `control_response` writers; the `admit/4` flag argument; `HarnessIO` takes a tenth job; `Turn.steer_start/2` updates the `Interrupt` of the provider; a reason in an Mcp comment; two new doc bullets repeat facts of "Idle close" and "Built in #246"; the credo reason names "turn" | Kept: the `Replay` comment names the JSON line; the ticket fixes the seams and puts the admission in `HarnessIO`; the ticket keeps `Interrupt` in the provider and gives the credo reason; step 2 asks for every moduledoc fact in the "Claude Code" section |
| Spec | No missing requirement, no behaviour change. The tools bullet said that every error case records the call id; the moduledoc said that one `claude` serves the provider process, but a lost session gets a fresh one. Scope: the `codex.ex:408` reference also updated | Both sentences fixed in the step 2 commit; the Codex reference is correct and stays |
| Failure path | No reproduced defect. Probed `admit/4` with no turn, a nil id, a used id, an unmapped call, and a 70 kB multibyte id: `mapped?` did not run in any error case | None |
| Codex adversarial (stand-in agent) | Approve. Clause-by-clause equal to master; `mapped?` stays lazy, so no input that master never reached can now raise. Doc: the same tools bullet as the spec finding, and it left out the error for a bad `name` or `arguments` | Bullet fixed: it names the four error cases and records the id only when a Helyx turn runs and the call names an id |

The round reproduced no defect, so the loop ends.
