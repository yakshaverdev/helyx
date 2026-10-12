# Review: #515 Delete the required interface option

Invariant: `Helyx.Core.start_link/1` is the only entry point. It refuses to start with `{:missing_plugin, Helyx.Provider}` when the resolved plugin table holds no `Helyx.Provider` plugin, an empty plugin list included (`providers/1`). `use Helyx.Interface` takes only `:mode` and raises `ArgumentError` at compile time on any other option, so a leftover `required: true` fails instead of doing nothing. Accepted change: a list with no provider that also fails a resolve check now returns that resolve error. Before, `{:missing_plugin, Helyx.Provider}` came ahead of a `:mode_violation`. `:not_a_plugin` and `:missing_callbacks` came first already. Either way Core does not start. Open hole older than this change, tracked by #517: a plugins value that is not a list of module atoms raises in `start_link/1` (1.6).

Decision source: `docs/reviews/2026-10-12-domain-review.md`, finding C6.

## Round 1 (full)

Simplify: `check_mode/1` matches one table entry with two or more plugins, in place of a tuple `case` that kept only one real clause (simplification). Skipped: `declaration/1` returns the bare mode atom (the ticket deletes the field and keeps the declaration shape). Reuse, efficiency, and altitude found nothing.

Bounds sensor:

```
bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | standards, failure path | `docs/agents/review-checklist.md`, "Plugins and Core", still named "no plugin for a required one" and "the fixed list it checks at boot" | Fixed: "no provider plugin", and Core names no interface except `Helyx.Provider`, of which `start_link/1` requires one plugin |
| 1.2 | standards | Judgement calls: the declaration is a one-key map; `providers/1` reads the table shape that `Helyx.Core.Plugins` builds; the error tag `:missing_plugin` now has one interface | Kept: the ticket keeps the error and puts the check in `start_link` |
| 1.3 | spec | `Keyword.validate!/2`, the empty-list test, and the error order are outside the ticket text | In scope: a silent `required: true` is the failure the ticket names; the empty list is the case of the #2 review; the ticket sets no order between two faults |
| 1.4 | failure path | Seven plugin lists through `start_link/1` (empty, no provider, two single plugins with no provider, duplicate entries, two providers with one id, the interface module itself, one provider): each bad list returns `{:error, _}` | — |
| 1.5 | Codex | Approve, no findings | — |
| 1.6 | Codex (checklist rule) | The rule "bad configuration returns `{:error, reason}` from `start_link`; it never raises" is broader than the code: `plugins: nil` raises `Protocol.UndefinedError`, `plugins: [123]` raises `FunctionClauseError`. Reproduced through `start_link/1` | Open, not in this change: both raise in `group/1` and `Helyx.Interface.implemented_by/1`, which this diff does not touch, and the #393 review recorded the second as an open hole. Tracked by #517 |

No round reproduced a defect of this change, so the loop ends after round 1. The checklist fix is Markdown; Codex reviewed it as a rule for agents (1.6).

## Gate r1 (Codex)

| # | Finding | Resolution |
| - | ------- | ---------- |
| G1.1 | `docs/agents/review-checklist.md`, "Plugins and Core": the rule says bad configuration never raises, but `plugins: nil` and `plugins: [123]` raise (1.6). Confirmed | Fixed by narrowing the rule to a plugins value that is a list of module atoms; the other shapes still raise (#517). The code is not changed |
