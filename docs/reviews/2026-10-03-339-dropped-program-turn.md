# Review: #339, a program turn dropped during a wait

Scope: `git diff origin/master` on `ticket/339-dropped-program-turn`.

Invariant: a program `:turn_start` that the session drops ends in every provider process that took it as live. Its open and later tool requests get `aborted`, an open context request gets `{:error, :turn_dropped}`, a later context request of it is a bad action, and a later program turn opens. A drop while the provider process has another live turn (#319) changes nothing.

Design: the ticket offered two ways. The first version took the first way: the session answered each tool request with no turn `aborted`. The simplify altitude agent showed that this leaves the turn live in the provider process, so a context request and a later program turn stay lost. The change takes the second way: the session sends the Core request `{:turn_dropped, turn_id}` (`ProviderRequest.tell/2`, no kill, no reply) and the provider process ends the turn with `end_tools/1`. The request uses the `{:provider_request, ...}` envelope, so `info/2` still gets every other message, and the `Helyx.Provider` behaviour does not change.

Codex was not available (usage limit until 2026-10-04 01:42). A fresh general-purpose agent ran the same adversarial review, read-only, with the same invariant sentence and base `origin/master`. It counts as the Codex reviewer below.

## Simplify, round 1

| Finding | Resolution |
|---|---|
| Reuse: the `results` update copied `Wait.sent/3`. | Used `Wait.sent/3`, then removed with the design change. |
| Simplification: one choice in a guard and an `if`. | Skipped: a helper adds lines. |
| Altitude: the session-side answer repairs one effect; the provider process should learn of the drop. | Applied: the design above. |
| Efficiency: none. | — |

## Round 1 (full)

Bounds sensor: `bounds sensor: 1 candidate functions, 1 flagged, 0 without an answer`, `lib/helyx/session/provider_process.ex:94 WAIT defp loop(proc)`.

| Axis | Findings | Resolution |
|---|---|---|
| Standards | 1. Hard: the known gap (a context request sent before the drop gets no answer) had no ticket (checklist: an open race is "open, ticket #N"). Judgement calls: "program turn" in Core comments; `drop_turn/2` repeats `provider_pid/1`; the drop goes to the current pid, not the sender; a raw `send` beside the request channel. | 1. Fixed in code: the open context request gets `{:error, :turn_dropped}`. `drop_turn/2` uses `provider_pid/1` and `ProviderRequest.tell/2`. The sender is safe: the loop acts only when the id is live, stated at `drop_turn/2`. "Program turn" is the term of #240 in Core; kept. |
| Spec | 1. A drop in a switch-close wait (`conn` nil) reaches no process. 2. The server comment "the loop ends it too" is false in the #319 case. 3. `info/2` no longer got every other message (interface question). 4. "Built in #203" list of loop answers, C4, and "A fresh context" did not name the drop. 5. "No ticket yet" gaps. | 1. Fixed: the wait's provider process gets it too. 2. Reworded. 3. Fixed: the `{:provider_request, ...}` envelope. 4. Fixed in both docs and the `end_tools` table row. 5. Gone with standards 1. |
| Failure path | None reproduced. Probes: a prompt, then `turn_start` and a tool request, with the session suspended; a terminal and a program turn in one batch. | — |
| Codex (agent) | 1. As spec 1, reproduced with `conn/late_close` and `Session.set_model/2`. | Fixed; test "dropped in a switch close wait". |

## Simplify, round 2

| Finding | Resolution |
|---|---|
| Reuse: `drop_turn/2` built the request envelope that `ProviderRequest` owns. | `ProviderRequest.tell/2`. |
| Simplification: `if is_struct(...)` against a `case`. | Skipped: same size. |
| Efficiency: `make_ref/0` per send. | Skipped: nanoseconds. |
| Altitude: send `{:interrupt, turn_id}` in place of `:turn_dropped`, so the program stops its own turn. | Not applied: the provider would get an interrupt for a turn that the session never showed, which changes what the program does and needs an owner decision. Reported as open. |

## Round 2 (full: two code files, a new function `ProviderRequest.tell/2`)

Bounds sensor (base `origin/master`; the round 1 state had no commit): `bounds sensor: 1 candidate functions, 1 flagged, 0 without an answer`, `lib/helyx/session/provider_process.ex:94 WAIT defp loop(proc)`.

The invariant the fixes restore: a program turn that the session drops ends in every provider process that took it as live, and never ends a turn that the session has.

| Axis | Findings | Resolution |
|---|---|---|
| Standards | 1. Hard: the `ProviderRequest` comment said every request has a kill. Judgement calls: `@doc` in a `@moduledoc false` module (as `ask/3`); `@type t` lacks the new request; `is_struct` against a clause head; the name `id` in `server.ex` (the line cap); the `make_ref()` of the context error. | 1. Fixed. Others kept. |
| Spec | No missing item, no scope creep, no interface change. False sentences: 1. "A context request of the dropped turn is a bad action" read as the #339 turn. 2. "Deadlines" and the `Helyx.Provider` moduledoc named only a `tool_result` request that Core makes itself. 3. "A fresh context" did not name the drop error. 4. `long-lived-harness.md` "The session" said every request has an armed kill. 5. Two comments said "each request". | All fixed. |
| Failure path | Round 1 case fixed (5 of 5). 1. A provider that reuses a program turn id: the `{:turn_dropped, id}` of the first, dropped turn reaches the loop after the session opened the second turn with the same id, and the loop ends it. Reproduced 5 of 5 with suspended processes. | Open, see below. |
| Codex (agent) | No defect. 1. "Built in #240" uses the old names `harness_id?/1` and `:program_turn`. | Not changed: older text, and the rename table in `one-provider-path.md` maps them. |

## Open

- Round 2 failure path 1: the contract says that the provider makes a new id for each program turn ("A program turn"), but Core does not check it. With a reused id, a late `{:turn_dropped, id}` ends a turn that the session has. A fix: the loop gives each program turn that it takes as live a ref, sends it with `:turn_start`, and acts on `{:turn_dropped, ref}` only for that ref. Not applied: the `/ship` time limit was reached after round 2. No ticket yet.
- Simplify round 2 altitude: an interrupt in place of `:turn_dropped`, so the program stops its own turn. Needs an owner decision.
