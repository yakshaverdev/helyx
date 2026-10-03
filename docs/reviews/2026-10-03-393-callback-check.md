# Review: one generic required-callback check for every interface (#393)

Date: 2026-10-03. Base: `origin/master` at the branch point (`f0a6905`). Scope: `lib/helyx/core/plugins.ex`, the `Helyx.Core` moduledoc, and `test/helyx/core_test.exs`.

## Invariant

`Helyx.Core.start_link/1` calls `Helyx.Core.Plugins.resolve/2`. It refuses a plugin that does not export every required callback of each interface it declares with `@behaviour`, as `{:missing_callbacks, plugin, interface, missing}`. The required callbacks are `behaviour_info(:callbacks)` minus `behaviour_info(:optional_callbacks)`, and `missing` is sorted. The check runs after the `:not_a_plugin` check and before the mode check. An interface without `@callback` has no `behaviour_info/1` and requires nothing. `provider_ids/1` only maps ids: the provider-only check of `init/3`, `request/3` and `info/2` and the `{:invalid_provider, plugin}` error are gone. Accepted hole: the check proves exports only, not return shapes. Open hole outside the ticket: a plugin entry that is not an Elixir module raises in `Helyx.Interface.implemented_by/1` (older than this change).

Deleted test: "a provider without init/3, request/3, and info/2 stops the start". It tested the removed provider-only check. The generic test "rejects a plugin that does not export a required callback of an interface" replaces it.

All plugins pass the new check. A throwaway test ran `resolve/2` on every module that implements an interface, in the root (test support), `plugins/bundled` (bundled plugins and test support), and `apps/coding_agent`. It found no plugin that misses a callback, apart from the module that the new test compiles on purpose.

## Round 1 (full)

Bounds sensor:

```text
bounds sensor: 7 candidate functions, 0 flagged, 0 without an answer
```

Simplify (4 agents): reuse, efficiency and altitude found nothing to change. Simplification: the filter of the missing callbacks became one `Enum.reject/2`. Not taken: inlining `not_a_plugin/1` (it reads fine), and moving the check to `Helyx.Interface` (it has one caller).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 4 judgement calls, 1 process note | 0 | Fixed: the comment above `group/1` was cut to the boundary note; the `Helyx.Core` moduledoc sentence was reworded; the test says why the plugin also implements `Test.Multi`. Not taken: the `{plugin, interfaces}` and `{interface, plugin}` tuple order (older than this diff). The process note asks for a "Replaced mechanism" section. This refactor has no feature doc, so this record names the replaced check and the deleted test. |
| Spec | 0 | 0 | Items 1 to 3 met. |
| Failure path | 1 | 1 | An interface with `use Helyx.Interface` and no `@callback` has no `behaviour_info/1`, so Core start raised `UndefinedFunctionError`. Before this change, the same plugin list started. Fixed: such an interface requires no callback, and a new test starts Core with such a plugin. |
| Codex adversarial | 0 | 0 | Verdict approve. |

## Round 2 (reduced)

The fix changes 4 code lines and 2 comment lines in one file. It adds no function and changes no spec, so this is a reduced round (spec and failure path). Both briefs named the invariant: Core start never raises from the callback check, and it refuses a plugin only for a missing required callback.

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Spec | 1 older defect, 1 test note | 0 in the change | A plugin entry that is not an Elixir module (`:lists`, `"Foo"`) raises in `Helyx.Interface.implemented_by/1`. This is older than the branch and outside the ticket, so it is reported for a new ticket. Not taken: the fixed module names in the compiled test modules (the existing tests compile modules the same way). |
| Failure path | 0 in the change, the same older defect | 0 in the change | The original reproduction now starts. Probed with no failure: an interface with only `@macrocallback` (the missing macro is named `"MACRO-m": 2`), an interface with only optional callbacks, gaps in two interfaces, and a plugin listed twice. |

No reproduced defect in the change, so the loop ends.
