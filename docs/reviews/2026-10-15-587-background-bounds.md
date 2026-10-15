# Review: #587 Background ends: count bound, crashed-session folder, stale hold

Invariant: a background run keeps its place among the 16 places of `Helyx.Session.Background` from `Helyx.Tool.background/0` until a turn takes its end, so the places bound the live runs and the waiting ends together in every turn phase. The end joins the transcript at the send of a turn (`Steering.append_steers/1`) or at the `user_message` of its steer (the `{:take, {:end, text}}` effect), and both call `Hands.taken/2` with the id. A call with no start answer frees its place when its Task ends, or when a cancel kills it. A give-back (`Queue.answer/4`, `Queue.provider_down/2`) sets `hold` only when no turn that takes ends is open (`open?` is derived from `activity`: a `%Turn{compact: nil}`), because the open turn delivers the end. `run_tool/3` moved without change from `Helyx.Session.Hands` to `Helyx.Session.Hands.Run`: `hands.ex` was at its 400-line limit and is now 387.

Accepted holes: a crashed or killed session leaves its background folder in the system temp folder (owner decision in #587). The lost ends of a resume free no place and come on top of the 16. An end is delivered at least once, not exactly once (feature doc).

Files: `lib/helyx/session/background.ex`, `lib/helyx/session/hands.ex`, `lib/helyx/session/hands/run.ex` (new), `lib/helyx/session/queue.ex`, `lib/helyx/session/server/steering.ex`, `lib/helyx/interfaces/tool.ex` (doc), two comment lines in `wait.ex` and `turn_loop.ex`, the tests, and `docs/features/background-bash.md`, `coding-agent.md`, `session-lifecycle.md`, `print-background-wait.md`.

Bounds sensor, round 1, base `origin/master`: `bounds sensor: 9 candidate functions, 1 flagged, 0 without an answer` / `lib/helyx/interfaces/tool.ex:182  WAIT  def hold(handle) do`. The diff changes only the `@doc` of `background/0` next to it; `hold/1` is unchanged.

## Simplify

Four agents. The four agents started as background agents by mistake (no `run_in_background: false`); all four finished in this session.

Applied:

- The stored `open` field of `Helyx.Session.Queue` (first form) became an `open?` argument of `answer/4` and `provider_down/2`, derived from `activity` in `Steering.open?/1`: no second record of the turn life (reuse and simplification agents).
- `Background.id/1` and `head/1` share one private `parse/1` (reuse).
- `Steering.taken/2` is a side effect called with `Enum.each/2`, not a reduce over an unchanged state (simplification).
- One `:sys.get_state` read of the hands in a session test removed; the trace of the `{:taken, id}` cast checks the same fact (simplification).
- A comment in `Hands.State` reflowed (simplification).

Skipped:

- One `{:taken, ids}` cast per drain (efficiency): at most 16 small casts at a send.
- The id beside the end in `Queue.ends`, or `{:background_end, id, text}` (efficiency, altitude, standards): changes the shape of the ends and the ledger; `lost/1` already treats the fixed line as the contract.
- One call site of `taken` through `{:take, {:end, text}}` effects of the drain (altitude): `Records.take_steer/2` also aborts open calls, so the drain at the send cannot go through it without a change in behaviour. The two sites are the two places where an end joins the transcript, and the feature doc names both.

## Round 1 (full)

Base `origin/master` (`ad87a11`).

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | Codex | Approve, no material findings | n/a |
| 1.2 | failure path | No defect reproduced. Probed: a place with no start answer then a cancel or a normal end; `kill/3` and `taken/2` on a running run; a crash end; `taken/2` twice with one id; the idle wake path frees the place after `turn_end`. Not reached: a late answer in a `submitted` turn with full steers or `rejected` set; the 16 places with held ends through a whole session; the bash and watchdog state table (code not changed) | n/a |
| 1.3 | standards | `background-bash.md` named `Queue.give_back/2`, now private and of arity 3 | Fixed: the doc names `Queue.answer/4` and `Queue.provider_down/2` |
| 1.4 | spec | `session-lifecycle.md` still stated "unbounded in theory" for the waiting ends | Fixed: the row states the 16 places |
| 1.5 | spec | Stale arities: `Queue.answer/3` in `wait.ex` and `turn_loop.ex` comments and in `print-background-wait.md`, `Queue.provider_down/1` in `session-lifecycle.md`; `print-background-wait.md` said the give-back always holds | Fixed |
| 1.6 | spec | No test that a give-back in a compaction turn holds (`open?/1` with `compact != nil`) | Fixed: test "an end given back by a late answer in a compaction turn holds"; it fails when `open?/1` drops `compact: nil` |
| 1.7 | spec | No test refuses a start in a `submitted` turn while ends wait | Not added: the place count is in the hands and does not depend on the turn phase. `hands_test.exs` refuses the 17th start while an end waits, and the session test "an end during a submitted turn goes to the provider as a steer" shows that a sent end keeps its place in a `submitted` turn until its `user_message` |
| 1.8 | spec | No test shows a later end waking the session after the turn that took a given-back end | Not added: the test asserts `hold: false` after that turn, and the idle wake with `hold: false` has its own test ("an end while idle opens a turn") |
| 1.9 | standards | `:ok = taken(...)` and `Enum.each` differ in style | Fixed: one form |
| 1.10 | standards | Judgement calls: "a turn that is not a compaction" is matched in three places; `taken` reads like a predicate (precedent: `Tool.started/1`); tests read `:sys.get_state`; `taken/2` is a cast (its `@doc` states the order with `run/3`) | Kept |

Round 1 reproduced no defect, so the loop ends. The fixes of 1.3 to 1.9 are docs, tests, and one line of style in `steering.ex`.

## Gate (orchestrator, 2026-10-15)

Codex adversarial review, base `origin/master` (`34cbcb22`), on the rebased commit. Gate r1 (Codex): verdict approve, no finding. It ran the 27 queue tests and did not run precommit.
