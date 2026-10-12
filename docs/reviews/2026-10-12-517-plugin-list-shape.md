# Review: #517 Return an error for a plugins value that is not a list of modules

Invariant: `Helyx.Core.start_link/1` is the only entry point. A plugins value that is not a proper list returns `{:error, {:invalid_plugins, value}}`, and an entry that is not an atom naming a loadable Elixir module (an integer, a string, nil, an Erlang module such as `:lists`, a module that does not exist) returns `{:error, {:invalid_plugin, entry}}`, before any other check and without a raise, and Core does not start. The checks after it trust the shape: `Helyx.Interface.implemented_by/1` lost its clause for a module that cannot be loaded. Accepted change: a module that does not exist was `{:not_a_plugin, module}` and is now `{:invalid_plugin, module}`; ADR 0005 says so. Open hole older than this change, tracked by #522: a plugin with `child_spec/1` listed twice passes `resolve/1`, and the failed supervisor start kills a caller that does not trap exits. Out of scope by the ticket: the return shapes of plugin callbacks, and `start_link` options other than `plugins`.

## Round 1 (full)

Simplify: `check_shape/1` uses `Enum.find_value/3` with `:ok` as the default, as `Helyx.Tool.check_available/1` does, in place of `Enum.reject/2` and a `case` (reuse, simplification); `Code.ensure_loaded?/1` in place of a match on `Code.ensure_loaded/1` (reuse); one comment reflowed. Skipped: one merged doc for the error shapes (the Core moduledoc is the public contract, the `@doc` of the internal module stays next to the code); `module_info(:attributes)` in place of the Elixir module check (the ticket rejects an Erlang module); a check of the `opts` value (outside the ticket). Efficiency found nothing.

Bounds sensor:

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | standards | The new checklist rule says a bad plugins value never raises, but a plugin with `child_spec/1` listed twice passes `resolve/1`, `Supervisor.init/2` fails with `{:start_spec, {:duplicate_child_name, M}}`, and the link kills a caller that does not trap exits. Reproduced through `start_link/1`. Older than this change | Open, not in this change: the ticket does not decide between a repeat check in the shape check and accepting repeats. Tracked by #522; the rule names the hole |
| 1.2 | standards, spec, failure path | The Core moduledoc said "not a list"; the code rejects an improper list too | Fixed: "not a proper list" |
| 1.3 | spec | The checklist rule does not name the function that does the shape check ("Specs and bounds") | Fixed: the rule names `Helyx.Core.Plugins.resolve/1` |
| 1.4 | spec, standards | "Core does not start" was asserted only for the shape cases; the two rejection tables used two assertion styles | Fixed: one table, and a `reject/1` helper asserts that no process holds the Core name after each rejection |
| 1.5 | spec | No test leaves `plugins` unset; the ticket names `[123]`, `["Foo"]` and `[:lists]` as bare lists | Fixed: a test for an unset value, and the rows use the bare lists |
| 1.6 | Codex | No test of the order: a mutation that reported `{:not_a_plugin, Test.NoInterface}` for `[Test.NoInterface, 123]` passed all tests | Fixed: a row asserts `{:invalid_plugin, 123}` for `[Test.NoInterface, 123]` |
| 1.7 | standards | Judgement call: `:invalid_plugins`, `:invalid_plugin` and `:not_a_plugin` are close names | Kept: the ticket names the two new errors |
| 1.8 | failure path | Probes through `start_link/1`: a map value, a tuple entry, `true`, a multibyte alias that does not exist, a module whose `@on_load` fails, a charlist, an interface module, a protocol and its implementation, one provider listed twice. Each returns an error tuple | — |

Round 1 reproduced no defect of this change: 1.1 is older and has a ticket, and the other findings are tests and docs. The loop ends after round 1. The fixes change tests, Markdown and one moduledoc line. The rule text for agents changed after the Codex review, so Codex reviewed the final diff once more (below).

## Codex on the final rule text

Approve, no findings. Codex ran the 26 Core tests and its own probes of the boundary and the check order.
