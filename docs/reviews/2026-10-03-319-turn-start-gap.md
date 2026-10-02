# Review: #319, a `:turn_start` during a turn

Scope: `git diff origin/master` on `ticket/319-turn-start-gap`.

Invariant: the provider process drops a `:turn_start` action while a turn is live, as the session does, so the live turn keeps its open Helyx tool requests and its open context request. With no live turn, the program turn becomes live as before. A bad id still stops the process. The dropped turn's tool requests get `aborted`, and a `need_context` of it is a bad action (C3 of `docs/features/one-provider-path.md`). The entry point is the `:turn_start` clause of `action/2` in `Helyx.Session.ProviderProcess`, reached from the provider callbacks `request/3` and `info/2`.

Decision (ticket step 2): a caller can make this state. The provider's program starts a turn when it likes (a Claude background task that ends), and the `provider.ex` moduledoc allows a program turn "at any other time". So the loop rejects the second `:turn_start` and keeps the running turn. It does not crash.

Accepted hole (unchanged, `docs/features/long-lived-harness.md`, "Built in #240"): the session also drops a program turn during its waits when the loop has no live turn, and the loop then makes it live.

Structure: `provider_process.ex` goes from 416 to 415 lines, and its `.credo.exs` entry follows.

## Round 1 (full)

Bounds sensor, against `origin/master`:

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

Simplify: four agents, no findings. The reuse and altitude agents suggested a function clause in place of the `cond`; skipped, because the `cond` keeps the file within its line limit.

| Axis | Finding | Resolution |
|---|---|---|
| Standards | The comment on the clause is in the passive voice | Fixed: "the loop drops it, as the session does" |
| Standards | "it" in the test comment depends on the `describe` | Fixed: names the program turn |
| Standards | The rewritten bullet in "Built in #240" puts a condition in mid-sentence | Fixed: split in two sentences |
| Standards | `message` is built before the checks | Kept: a small tuple, and the binding keeps the clause on one line per branch |
| Spec | No test that the dropped turn's tool request gets `aborted` | Kept: the existing not-live clause of `tool_request/4`; the failure-path probe 1 confirmed it |
| Spec | The bullet in "Built in #240" keeps the names before the rename (`harness_id?/1`, `:program_turn`, harness process) | Kept: the whole section is history of #240, and the rename table in `one-provider-path.md` maps the names |
| Spec | The `provider.ex` moduledoc does not say that a dropped turn's tool requests get `aborted` | Kept: the sentence there stays true, and #307 rewrites that moduledoc; C4 holds the rule |
| Failure path | No defect. Probes: a dropped turn's tool request gets `aborted` and the live turn's runs; a dropped turn's terminal leaves the live turn's tools; the same id as the live turn is dropped with `seen` kept; a 257-byte id stops the process; a 256-byte multibyte id is dropped | None |
| Codex | Approve, no material findings | None |

The round reproduced no defect, so the loop ends.
