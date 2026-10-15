# Review: #571 `:openai_req_options` is checked at the start of each model call

Invariant: `Helyx.Provider.OpenAI.stream/5`, through the Go and Zen plugins, checks the `:openai_req_options` app env of `helyx_plugins` at the start of each model call, after the `Helyx.ModelInfo` lookup and before the API key and any request. A value that is not a keyword list fails the call with `{:error, {:bad_config, [:openai_req_options]}}`. A keyword list goes to Req unchanged, after the options of the provider, so it can replace them. Accepted hole, as for the `req_options` of `:model_catalog` (#560): the names and the values are Req's to check, so an unknown name or a bad value fails the turn in the model call when Req raises.

Files: `plugins/bundled/lib/helyx/provider/openai.ex`, `plugins/bundled/test/helyx/provider/openai_test.exs`, `docs/features/coding-agent.md` (one row of "Bounds").

## The app env keys of `helyx_plugins`

The triage asks for this list. A grep of `plugins/bundled/lib` finds three keys.

| Key | Read in | Start check |
| --- | ------- | ----------- |
| `:models` | `Helyx.ModelInfo.lookup/3` | each lookup, at the provider start (`init/3` of a harness provider, the start of `stream/3` of a model provider): `{:error, {:bad_config, [:models, ...]}}` |
| `:model_catalog` | `Helyx.ModelInfo.Catalog.lookup/2` | each lookup, with the `:models` check (#560): `{:error, {:bad_config, [:model_catalog, ...]}}` |
| `:openai_req_options` | `Helyx.Provider.OpenAI.stream/5` | each model call, after the lookup (#571, this change): `{:error, {:bad_config, [:openai_req_options]}}` |

Before the change, a value that was not a keyword list raised `ArgumentError` in `Req.new/1` inside `stream/5` (probe at `origin/master`: `:foo` and `%{plug: 1}` gave "argument error"), and `Helyx.Provider.Loop` failed the turn with the raise.

## Round 1 (full)

Base `origin/master` (`ad87a11`). Bounds sensor: `bounds sensor: 3 candidate functions, 0 flagged, 0 without an answer`.

The first version checked the option names against `Req.new().registered_options`, with the path `[:openai_req_options, name]` for an unknown name.

Simplify, four agents. Applied: one `on_exit` for the test, not one for each case; the `check/3` comment named its new caller. Skipped: a name check for the `req_options` of `:model_catalog` (out of scope, see "Open"); a reverse in `ModelInfo.check/3` (it changes the duplicate-key rule of `:models` and `:model_catalog`); the second `Req.new` for the name set (a few microseconds per model call).

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | standards, spec, failure path | Valid Req options failed the check: `:headers`, `:adapter`, `:url`, `:method`, `:body`, `:into` are request fields that `Req.merge/2` splits off, not registered options. Reproduced: `[headers: [{"x-a", "1"}]]` gave `{:bad_config, [:openai_req_options, :headers]}` | Fixed in round 2: the six names joined the name set |
| 1.2 | Codex | Approve, no findings | n/a |
| 1.3 | spec | A bad value of a known option still fails during the turn | Accepted hole, as for the `req_options` of `:model_catalog` (#560) |
| 1.4 | standards | `ModelInfo.check/3` is a general config checker in a module named for model data | Judgement; not changed |

### Fix size

5 code lines in one file, no function added. Round 2 is a reduced round.

## Round 2 (reduced)

Bounds sensor (base `origin/master`; the pre-fix state was not kept): `bounds sensor: 4 candidate functions, 1 flagged, 0 without an answer`, `plugins/bundled/lib/helyx/provider/openai.ex:62  SIZE  def stream(provider_id, model, context, opts, base_url) do`.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | spec, failure path | `:plugins` failed the check, but `Req.new/1` takes it before `Req.merge/2`; an option that a Req plugin registers failed too. Reproduced: `[plugins: [fn r -> r end], plug: f]` gave `{:bad_config, [:openai_req_options, :plugins]}` | Fixed in round 3 by removing the name check |
| 2.2 | spec | The env `method` has no effect, because `Req.post/1` sets the method after the merge | A value of a known option; accepted hole |

The second finding on one mechanism, so round 3 asks whether the mechanism needs to exist. The name check copies the option rules of Req, which live in three places of Req's code and in its plugins. The `req_options` of `:model_catalog` checks only the keyword shape. Round 3 does the same: the names go to Req, as the values do.

## Round 3 (full)

Bounds sensor (base `origin/master`): `bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer`.

Simplify, four agents. Applied: the `on_exit` of the second test comes first. Skipped: the doc row of the retries calls `:openai_req_options` a test seam; it is one.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 3.1 | Codex | Approve, no findings | n/a |
| 3.2 | spec, failure path | Round-2 reproduction passes; no path breaks the invariant. Probes: Zen and Go, no API key, `nil`, a string, a tuple, an improper list, a string key each give `[:openai_req_options]`, and a `Req.default_options` plug gets no request | n/a |
| 3.3 | failure path | Doc: "a later key wins" is false for `plugins`, where `Req.new/1` keeps the first. Reproduced: `[plugins: [p1], plug: ok, plugins: [p2]]` runs only `p1` | Fixed in the row: `headers` merge by name, and the first `plugins` wins |
| 3.4 | standards | Doc: "goes after the options of the provider" had no test | Fixed: the test sets `auth: {:bearer, "other"}` and checks the header |
| 3.5 | standards | Doc: "a bad value raises" is not always true: `receive_timeout: "x"` with the plug adapter gives an empty stream | Fixed in the row: "fails the turn when Req raises" |
| 3.6 | standards | The comment compared the check with the catalog, whose merge order is the opposite; the local `env` held options | Fixed: the comparison is gone, and the local is `options` |

Round 3 reproduced no code defect, so the loop ends. 3.3 to 3.6 are doc, test, and naming fixes, and get no further round.

## Guarantee table

| Guarantee | Proof |
| --------- | ----- |
| A value that is not a keyword list fails the call with `{:error, {:bad_config, [:openai_req_options]}}` | `openai_test.exs` "an :openai_req_options value that is not a keyword list fails the call with its key before any request" (atom, map, `[1]`, string key, improper list) |
| The check comes before the API key and any request | round 3 spec probe (no API key gives `bad_config`; a `Req.default_options` plug gets no request); the `with` returns before `request/6` |
| Zen fails the same way | round 3 probes |
| A keyword list reaches Req unchanged: a later key wins, `headers` arrive | `openai_test.exs` "a keyword list in :openai_req_options goes to Req as it is, and a later option wins" (two `plug` keys) |
| The env comes after the options of the provider | the same test (`auth` replaces the bearer key) |
| The first `plugins` wins | round 3 failure-path probe |
| Names that Req accepts and no check knows pass (`plugins`) | round 3 spec and failure-path probes |

## Open

- The `req_options` of `:model_catalog` and `:openai_req_options` both leave the names and the values to Req. A bad one fails in the model call (or in the catalog refresh) with Req's error, not with the env key.

## Gate (orchestrator, 2026-10-15)

Codex adversarial review, base `origin/master` (`34cbcb22`), on the rebased commit. Gate r1 (Codex): verdict approve, no finding. It did not run tests (read-only workspace).

The orchestrator accepted the check at each model call, not at app start: it is the place and the shape check of `:model_catalog` (#560), which the triage named.
