# 2026-11-06: review of the session start option `:model_context` (#854)

Invariant: a session uses the ModelContext plugin that its start names with `:model_context` (`Helyx.Session.start/2`, `Helyx.Sessions.start/2`), or the first registered one when the option is nil or absent. Any other value gives `{:error, :invalid_model_context}` before any file or process exists. `Helyx.ModelContext` is `:multi`. A resume gets the first registered one, because the header does not keep the option. `Helyx.Tool.context/0` carries the session's plugin, and the agent tool starts the child with it. The wire has no field for it (`docs/features/session-model-context.md`).

## Round 1 (full)

Base: `738c3c07`, the merge base.

Simplify made five changes:
- The start check now leaves nil as nil. `Open.start_child/3` resolves nil to the first plugin, so one place holds the default and the resume needs no step of its own.
- `Input.model_context/2` became private.
- `Input.child/1` was renamed to `start_options/2`.
- Doc lines were wrapped again.
- The feature doc was aligned with the code.

It left `session.ex` at 400 lines, the limit.

```text
bounds sensor: 3 candidate functions, 2 flagged, 0 without an answer
  lib/helyx/interfaces/tool.ex:219  WAIT  def unhold(handles) when is_list(handles) do
  plugins/bundled/lib/helyx/tool/agent.ex:52  SIZE  def run(%{"description" => description, "prompt" => prompt},
```

The failure-path agent checked both flags: the diff adds one map key next to `unhold/1` and one option that `run/2` passes through. Neither adds a wait or a buffer.

Counts:

| Reviewer | Defects | Other findings |
| --- | --- | --- |
| Codex | 0 | verdict approve |
| Standards | 0 hard violations | 4 judgement calls, 5 guarantees with no test |
| Spec | 0 defects | 2 doc or test gaps |
| Failure path | 0 | none |

No round reproduced a defect, so the loop ends after this round.

| # | Finding | Source | Resolution |
| --- | --- | --- | --- |
| 1 | `session.ex` is at exactly 400 lines and has no `.credo.exs` entry. | standards | Kept. The file is within the limit. The next change that adds a line must make room. |
| 2 | `start_options/2` returns an anonymous 4-tuple; `parent`, `only`, and `model_context` travel together (Data Clumps). | standards (judgement) | Kept. It has one caller, and a struct for one call site is more code than the tuple. |
| 3 | The `Marked` macro in `agent_test.exs` defines two identical test plugins. | standards (judgement) | Kept. The two modules must differ only in name, and the macro states that. |
| 4 | Replaced mechanism 2 said that the core_test row "now checks" the start. The row was removed and a new test was added. | standards | Fixed: the doc names the removed row and the new test. |
| 5 | `harness-no-state.md` still called the three plugins "single-mode". | spec | Fixed: it lists the three plugins by name. |
| 6 | The doc claims that the wire `start` op rejects any other key, but only `sessions.live` had a test for an unknown key. | spec | Fixed: `web_socket_test.exs` sends `start` with a `model_context` key and gets `bad_params`. |
| 7 | Guarantees with no test: an attach on resume keeps the running session's ModelContext; a resumed parent passes the first one; `Tool.context/0` is nil with no plugin; the check does not load the module. | standards | Covered by the spec agent's probes (table below). The last one is shown by the code, `module in Helyx.Core.plugins(...)`. |

Guarantee table, from the spec agent:

| Guarantee | Proof |
| --- | --- |
| A Core with two ModelContext plugins starts and lists them in registration order | `core_test.exs`, "boots with two model context plugins and lists them in registration order"; `model_context_test.exs`, first test |
| No option, or nil, gives the first plugin | `model_context_test.exs`, "a session gets the ModelContext that it names, the first by default" |
| A named module is used, by `Session.start/2` and by `Sessions.start/2` | the same test; "Helyx.Sessions.start/2 passes the option" |
| Any other value gives `:invalid_model_context`, before any file or process | "a value that names no registered ModelContext starts nothing"; failure-path probe with `false`, `true`, a pid, a tuple |
| The check runs after `:parent`, `:tools`, and `:provider_opts` | probes of the spec and failure-path agents |
| A Core with no ModelContext takes only nil | "a Core with no ModelContext takes only nil" |
| A resume gets the first plugin | "a resume gets the first ModelContext: the header does not keep it" |
| `resume/2` ignores the option, as it ignores `:tools` | spec probe: `resume(..., model_context: :bad)` gives `{:ok, _}` |
| `Tool.context().model_context` is the session's plugin, or nil with none | spec probes: named, default, and nil |
| A resumed parent passes the first plugin to its child | spec probe: the context after a resume holds the first |
| A child gets the parent's ModelContext | `agent_test.exs`, "a child gets the ModelContext of its parent" |
| Compaction and Memory stay `:single` | `core_test.exs`, the refusal rows "two compaction plugins" and the rest |
| The wire `start` op has no field for it | `web_socket_test.exs`, "an unknown op, a bad param, and an unknown key get their errors" |

Accepted hole (feature doc, decision 4): a resumed session, a coordinator session too, gets the first ModelContext.
