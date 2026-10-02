# Review: the OpenAI SSE parser moves to OpenAI.Events (#328)

Date: 2026-10-03. Base: `origin/master` at `9defa53`. Scope: `plugins/bundled/lib/helyx/provider/openai.ex`, the new `plugins/bundled/lib/helyx/provider/openai/events.ex`, the two OpenAI test files, and `.credo.exs`.

## Invariant

The SSE parser moves verbatim from `Helyx.Provider.OpenAI` to `Helyx.Provider.OpenAI.Events`. The entry point `stream/4` of the `Go` and `Zen` plugins calls `Events.events/1` on the Req body chunks. `OpenAI.events/1` is deleted, because only tests called it. The parser-only tests move to an async `events_test.exs`, and only the module name in them changes. No behaviour, bound, or error event changes.

## Size

`openai.ex`: 485 lines before, 198 after. `openai/events.ex`: 293 lines. The `.credo.exs` entry is removed. Tests: `openai_test.exs` 626 lines before, 342 after; `openai/events_test.exs` 304 lines. The 32 `test "` definitions of master are all present (13 + 19).

## Round 1 (full)

Bounds sensor:

```text
bounds sensor: 17 candidate functions, 2 flagged, 0 without an answer
  plugins/bundled/lib/helyx/provider/openai/events.ex:84  SIZE  defp data(payload, acc) do
  plugins/bundled/lib/helyx/provider/openai/events.ex:193  SIZE  defp add_call_delta(delta, acc) do
```

Both flags are on moved code that the diff does not change.

Simplify (4 agents): no code findings. The duplicate test helpers `sse/1`, `delta/2`, and `@not_object` in both test files stay: both files use them, and `test/support` has no fixture helper to follow. Fixed: the `@doc` of `events/1` said "Public so tests can feed chunks", which became false when `OpenAI.stream/4` became a caller in another module.

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 0 hard, 6 judgement calls | 0 | Not changed: the test helper copies (above); the name `Events.events/1` (the ticket keeps the code verbatim); the alias placement; the comment above `@moduledoc false`. The dated review `2026-09-19-ticket-79-large-integer-arguments.md` names `OpenAI.events/1` and stays as a historical record. |
| Spec | 0 missing, 0 scope creep, 0 wrong, 1 wording | 0 | The `openai.ex` moduledoc sentence "The engine lives here" now says that the SSE parser is in an internal module. Line counts go in the PR. |
| Failure path | 0 from the diff | 0 | Byte comparison of the moved code and tests found no change. Two older defects on master, not caused by this diff: `"index": null` merges two calls (`Map.get_lazy` returns `nil` for a present key), and indexes `0` and `"0"` make two calls, the second with an empty id emitted as a `:tool_call`. Not reached: the Core check of an empty tool call id. |
| Codex adversarial | 0 | 0 | Approve. |

No round reproduced a defect from this diff, so the loop ends after round 1.
