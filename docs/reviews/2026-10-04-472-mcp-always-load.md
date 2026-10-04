# Review: the Helyx tools are always loaded in Claude Code (#472)

Date: 2026-10-04. Base: `origin/master` ac6eff9.

Invariant: `Helyx.Provider.ClaudeCode.Mcp.config/0`, the only MCP config of the launch flags, gives the `helyx` server of type `sdk` the key `alwaysLoad: true`, so the harness does not defer the Helyx tools behind its own `ToolSearch`. The user's own MCP servers stay as they are. Evidence: one real run on `claude` 2.1.288, recorded in `docs/research/claude-code-stream-json.md`, "`alwaysLoad` on the SDK MCP server". Accepted hole: no control run without the key on 2.1.288.

## Bounds sensor

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

## Simplify

Reuse, efficiency, and altitude clean. Simplification: three findings, all skipped. The research note citation in the comment is the repo form. The test name and the literal in the test stay, because the ticket asks the test to pin the config text.

## Round 1 (full)

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | The bullet under "Host tools through an SDK MCP server (verified)" stated a general fact from one run on another version | Fixed: the bullet names 2.1.288 and "observed, 1 run". |
| Standards | "at once" in the code comment has two meanings, and the comment stated the effect as a fact | Fixed: the comment states what the run showed. |
| Standards | "a manual test on 2026-10-04" in "Not run" has no version | Fixed: the clause is cut. |
| Standards | Test name, comment as a reason | Kept: judgement calls, no rule breach. |
| Spec | Same bullet as Standards | Fixed, as above. |
| Spec | "the flags of `Helyx.Provider.ClaudeCode`" was not exact: the script left out `--include-partial-messages` | Fixed: the note lists the flags, the one left out, and no `--strict-mcp-config`. |
| Spec | "accepted the key" is an inference | Fixed: "did not reject the key". |
| Spec | `result` subtype and exit status not recorded | Fixed: added. |
| Failure path | No reproduced findings. The config decodes as JSON; `claude_code.ex` is the only caller | None. |
| Codex adversarial | Approve, no material findings | None. |

Not reached: the real `claude` program in the failure-path probes (not allowed by the brief).

No defect was reproduced, only wording, so the loop ends after round 1.
