# Claude Code hook format: field names

Date: 2026-11-07. Source: the Claude Code binary 2.1.319 (`claude --version`), `/opt/homebrew/Caskroom/claude-code@latest/2.1.319/claude`, searched with `LC_ALL=C grep -c -a -F <name>`. Ticket #883.

## Observed

Each of these names occurs in the binary; the number is the count of lines that hold it:

| Name | Lines |
|---|---|
| `hook_event_name` | 31 |
| `tool_use_id` | 450 |
| `tool_response` | 27 |
| `permissionDecision` | 49 |
| `permissionDecisionReason` | 20 |
| `additionalContext` | 58 |
| `updatedInput` | 160 |
| `updatedMCPToolOutput` | 14 |
| `stopReason` | 56 |
| `suppressOutput` | 11 |
| `"approve"` | 18 |
| `decision:"block"` | 10 |
| `hookSpecificOutput` | 55 |
| `tool_name` | 136 |
| `tool_input` | 83 |
| `"continue"` | 84 |
| `"ask"` | 274 |
| `"defer"` | 24 |
| `stop_hook_active` | 6 (counted 2026-11-08) |

The function that reads the standard output of a hook as JSON trims it and checks for `{`: `resultStdout?.trim();return n!==void 0&&n.startsWith("{")` occurs once in the binary (`grep -c -a -F`, 2026-11-08; found by a review agent near byte 270,158,000). The caller that parses the result was not read.

The string `Whether Claude should continue after hook (default: true)` occurs in the binary (`grep -a -o -F`), the description of a schema field; which field it describes was not read from the code around it.

The event names `PreToolUse` and `PostToolUse` are in the binary too (`docs/research/provider-parity.md`, "A hook before each model call").

## Not observed

- The meaning of each field but the one description above, the schema that the program checks, and the order in which it reads two decision fields: the search finds names, not code paths. `"ask"` and `"continue"` are common words, so their counts show little. The exit code meanings that Helyx keeps (0, 2, any other) are stated in ADR 0013 §8 with the owner decision of 2026-11-06.
- How the program treats a hook that writes plain text or JSON with another shape on standard output.

`docs/features/command-hook.md` decides what Helyx reads; this note only shows that the names it uses are the names of the format.
