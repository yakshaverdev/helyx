# Review: a failed turn shows the provider's text (#746)

Scope: the working tree against `HEAD` (`a8d67072`), the branch point. `origin/master` moved ahead during the work (#739), so a diff against it shows that commit in reverse; the reviewers took the change as `git diff HEAD`. Feature docs: `docs/features/session-lifecycle.md` ("Turn end", step 5) and `docs/features/long-lived-harness.md` ("Errors").

Invariant: every client shows the failed-turn text that Core makes once with `Helyx.Reason.text/1` (the print mode line `the turn failed: <text>`, the TUI cell `error: <text>`); an error result of a harness turn (`Helyx.Provider.ClaudeCode.Turn.terminal/3`, `Helyx.Provider.Codex.Items.terminal/2`) that has a text is a `Helyx.HarnessIO.Error` whose message is `<provider id>: <text>`, the text cut at 2,000 bytes, the subtype or status in the reason for the log only; a result with no text keeps its tuple.

## Reproduction

`plugins/bundled/test/helyx/provider/claude_code/turn_test.exs`, "an error result with the subtype success shows the provider id and its text", on the code before the fix: the `turn_end` error was `{:claude_code, "success", "You've hit your session limit · resets 1am (Asia/Makassar)"}`, the text of the observed run.

## Decision

Core does not change. `-p` (`CodingAgent.Print`) and the TUI (`Helyx.TUI.ViewModel`) already show the `error` of `turn_end`, which `Wait.finish/2` makes with `Helyx.Reason.text/1`, and that function shows an exception as its message. So the one text function is the existing Core one, and the provider gives an exception. The exception is a helper of the two harness providers, which share the result shape `{tag, kind, text}`.

## Simplify

Four agents (reuse, simplification, efficiency, altitude).

| Finding | Resolution |
| ------- | ---------- |
| Both callers wrap the text in `HarnessIO.cap_error/1` | Fixed: `Error.reason/4` cuts it |
| `items.ex` names `Helyx.Provider.Codex` in full over nine lines | Fixed: alias, one line |
| `reason/4` takes the tag and the id of one provider; always return the struct, with `<id>: <kind>` for no text | Skipped: ticket decision 1 keeps `inspect/1` for other reasons, and decision 2 keeps the subtype out of the user text |
| The Codex error answers to a request and the OpenAI errors still show as a term | Skipped: no observed run; the doc names them |
| Reuse, efficiency | Clean |

## Round 1 (full)

Bounds sensor (`--diff origin/master`):

```
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Findings | Reproduced defects |
| ---- | -------- | ------------------ |
| Codex adversarial | 0 (verdict approve) | 0 |
| Failure path | 0; one observation: a text of white space only shows as `claude-code:` | 0 |
| Standards | 0 hard; judgement: tag and id travel together, two reason shapes, the comment of `reason/4` unclear | 0 |
| Spec | 2: the rule covers only the turn result (Codex `failure/2` with `turn/start`, Claude `{:compaction_failed, _}`, `{:initialize, _}`, `{:interrupt, _}`, OpenAI); no Codex test of the 2,000-byte cut | 0 |

Resolution:

- Fixed (wording): the comment of `Error.reason/4` names `cap_error/1` and what it does with a value that is not a string.
- Fixed (test gap): `codex/turns_test.exs`, "the error text of a failed turn is cut at 2,000 bytes, not in a character".
- Accepted (scope): the other provider errors with a text keep their term. The ticket evidence is the turn result of Claude Code; the feature doc names the other terms. Ticket candidate if a run shows one to a user.
- Accepted: a text of white space only shows as `<id>: ` and the subtype goes to the log only. No program is known to send it.
- Skipped (judgement): one shape for every result, as in Simplify.

No round reproduced a defect, so the loop ends after round 1.

## Precommit

The first run failed on Credo `Consistency.ExceptionNames`: the check takes the suffix `Message` from the test exceptions in `test/support/interfaces.ex`, and `Helyx.HarnessIO.Error` is the only exception under `lib/`. Fixed with `# credo:disable-for-next-line` and its reason above the module, a comment with no behaviour, so no review round followed.

## Guarantees

| Guarantee | Test |
| --------- | ---- |
| A Claude error result with a text fails the turn with `claude-code: <text>` | `claude_code/turn_test.exs:426` |
| `is_error: true` with the subtype `success` is an error result; the subtype is in the log | `claude_code/turn_test.exs:441` |
| A Claude result with no text keeps `{:claude_code, subtype, ""}` | `claude_code/turn_test.exs:464` |
| A Codex failed turn gives `codex: <text>` | `codex/turns_test.exs:242` |
| The text is cut at 2,000 bytes, not in a character | `claude_code/limits_test.exs:166`, `codex/turns_test.exs:250` |
| A Codex result with no text keeps `{:codex, status, ""}` | `codex/interrupt_test.exs:40` |
| The print line is `the turn failed: <text>` | `apps/coding_agent/test/coding_agent/print_test.exs:227` |
| The TUI cell is `error: <text>` | `plugins/bundled/test/helyx/tui/view_model_test.exs:331` |
| The message is at most 2,013 bytes, under the 4,000-byte cut of Core, and the render paths keep their clean pass | probe of the spec agent: 5,000 × `é` gave 2,013 bytes; ESC became `?` in the print line |
