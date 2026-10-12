# Review: #522 Reject a plugin module listed twice

Invariant: `Helyx.Core.start_link/1` is the only entry point. Through the shape check of `Helyx.Core.Plugins.resolve/1`, a module listed twice in the plugins value returns `{:error, {:duplicate_plugin, module}}`, a provider too, without a raise, and Core does not start, so a caller that does not trap exits lives. The check runs after every entry is known to be a loadable Elixir module and before any check that calls plugin code. `{:duplicate_provider_id, id, [first, second]}` stays for two different provider modules with one id. Accepted change: a repeat of a plugin without `child_spec/1` was accepted and is now rejected; no plugin list in the repository has a repeat. Open hole, found while this change was built and tracked by #525: two different plugins whose `child_spec/1` return one child id pass `resolve/1`, and the failed supervisor start kills a caller that does not trap exits.

## Round 1 (full)

Simplify: the support test checks the plugin child with `List.keyfind/3` in place of `Enum.filter/2` and a list match (simplification). Skipped: the nil sentinel of the first `cond` form (taken in 1.2 below); the row "a module that implements no interface listed twice" (kept: it pins the order before `not_a_plugin`). Reuse, efficiency and altitude found nothing. Reuse noted that `Helyx.Tool` uses the same `--`/`Enum.uniq/1` form for tool names.

Bounds sensor:

```
bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | author probe | Two different modules whose `child_spec/1` return one id pass `resolve/1`; the caller of `start_link/1` dies when it does not trap exits, and gets `{:error, {:start_spec, {:duplicate_child_name, :same}}}` when it does. Not in the decision of #522 | Open, filed as #525 (needs triage); the checklist rule names it as the open hole |
| 1.2 | standards, simplify | Judgement call: the `cond` form used `nil` from `List.first/1` as "no repeat" and needed a comment to say why that was safe | Fixed: `check_unique/1` matches `[]` and `[module \| _]` |
| 1.3 | standards | Judgement call: the code comment gave the child spec as the reason, but the check rejects every repeat | Fixed: the comment states what the later checks trust (each entry is an Elixir module, listed once) |
| 1.4 | standards | Judgement call: the row "the first of two repeats" pinned an order that no doc stated | Fixed: the `@doc` says the error names the module of the first repeated entry, and the row has that name |
| 1.5 | spec | Nit: the docs said "two providers" share an id; only different modules reach that check now | Fixed: "two different providers" in the Core moduledoc and the `@doc` of `provider_ids/1` |
| 1.6 | spec | Nit: the bounds table of `docs/features/coding-agent.md` has no row for the plugins value. Older than this change (#517 did not add it) | Not fixed here: outside the ticket |
| 1.7 | failure path | Probes through `start_link/1` with a caller that does not trap exits: a plugin with a process listed twice, the order of two repeats both ways, one atom in two spellings, `[false, false]` and `[P, true, true]` (entry check first), 100,000 copies of one module (about 5 ms), 185 distinct modules. #525 reproduced. No redundant check | — |
| 1.8 | Codex | Approve, no findings. Codex ran the Core tests and a probe that a caller without exit trapping survives and that the repeat check runs before `id/0` | — |

Round 1 reproduced no defect of this change: 1.1 is a sibling path outside the decision and has a ticket, and the other findings are judgement calls and docs. The loop ends after round 1. The fixes after the review change the form of one private function (same results, the Core tests pass) and docs.
