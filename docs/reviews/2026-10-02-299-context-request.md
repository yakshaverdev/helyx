# Review: #299, the context request and no normal exit (one-provider-path step 2)

Scope: `git diff origin/master` on `ticket/299-context-request`. The change builds "The context request" (C1–C5) and L1 of "Process lifetime" in `docs/features/one-provider-path.md`.

Invariant: the provider process accepts the action `{:need_context, turn_id}` only for the live turn with no open context request of it; any other one is a bad action and stops the process. The session answers with the request `{:context, turn_id, result}`, built by a prepare Task of the hands under `prepare_ms` after the session applied every earlier action of the same list. The loop clears the open request at an interrupt, a terminal, the next turn, and a `turn_start`, and it answers a late context `:ok` and drops it. The provider replies inside its callback, or the process stops with `{:context_not_answered, turn_id}`. The provider process never exits with `:normal`: every returned stop exits `{:shutdown, reason}`, a callback `exit(:normal)` becomes `{:shutdown, {:exit, :normal}}`, and the hands report `reason`. The entry points are the provider callbacks `init/3`, `request/3`, and `info/2`, and `Helyx.Session.Server.handle_info/2`.

Accepted holes:

- `Process.exit(self(), :normal)` in a callback still ends the process with `:normal` (the stated limit of L1).
- A callback that calls `exit({:shutdown, x})` is now reported as `x`, not as `{:task_exit, {:shutdown, x}}`. L1 says that `harness_reason/1` (here `down_reason/1`) maps `{:exit, {:shutdown, reason}}` to `reason`, and the loop has no other way to give its reason to the hands. Plugin code is compiled into the node.
- The prepare Task of a context request that is open at a terminal runs to its result, at most `prepare_ms`, and the session drops the result. The Ownership row of the prepare Task says "Released on normal end: its result" and "Released on abort: the cancel of the turn's Tasks". This is also what the first prepare of a turn does today at a failure (`fail_turn/2`).
- L2–L4 and `Helyx.Provider.Loop` are step 3.

## Structure

- `server.ex`, `hands.ex`, and `provider_process.ex` must not grow (`.credo.exs`). The request rules moved to a new module, `Helyx.Session.ProviderRequest`: the send with the armed kill (`ask/3`, was `ProviderProcess.request/3`), the cancel at the answer (`answer/5`), the kind of a request, the replies that a kind takes, and the replies that stop the process (`stop_after/2`). The module owns those decisions. `provider_process.ex` is now 416 lines, and its `.credo.exs` entry goes down from 429 to 416. `run/1` returns the process body as a fun of the connect kill: a direct capture of a `no_return` function failed Dialyzer at the call site in `server.ex`.
- `interrupt/2` moved from `server.ex` to `Wait.interrupt/2`: the wait owns its `interrupt` part and sends it in `next/2`.
- `server.ex` stays at 1182 lines: the first prepare and the context request share `prepare/1`, the two `{:prepared}` clauses of `:preparing` are one clause, and `{:prepare_failed}` is the `{:prepared}` error `{:task_exit, reason}`.

## Round 1 (full)

Bounds sensor, against `origin/master`:

```
bounds sensor: 3 candidate functions, 2 flagged, 0 without an answer
  lib/helyx/session/provider_process.ex:92  WAIT  defp loop(proc) do
  lib/helyx/session/server.ex:458  SIZE  def handle_info(
```

The loop has no deadline of its own: each request has its armed kill. The flagged `handle_info` is the context clause; its result is checked by `Stream.prepare/4`, and its size is the context of a turn, as before `{:turn, ...}`.

| Axis | Findings | Resolution |
|---|---|---|
| Simplify | 1. Five copies of "cancel the kill, then send the reply". 2. A sleep loop with no bound in the test. 3. One test accepted the reason of the other case. 4. The context deadline used the `tool_result` key. 5. `{:prepare_failed}` could be sent as `{:prepared}` by the hands. 6. One central predicate for the kinds outside the pool. 7. `Wait.interrupt/2` moved for line count. | 1. One function, now `ProviderRequest.answer/5`. 2. `SessionCase.await/3`. 3. Each case has its reason. 4. A `context` key in `provider_ms`. 5. Skipped: the moduledoc of `hands.ex` names `prepare_failed`, and #306 edits that moduledoc. 6. Skipped: three modules with three roles. 7. Kept: see "Structure". |
| Standards | 1. The cancel of the kill was in another module than its arm. 2. `stop/2` returns nil for "no stop". 3. The guard `elem(request, 0) in [...]` fails for an atom request without a word. 4. A `case` where AGENTS.md prefers clauses. 5. The kind lists in four places. | 1. `answer/5` moved to `ProviderRequest`. 2. Renamed `stop_after/2`. 3. A comment. 4. Kept: two clauses need three lines, and `server.ex` is at its limit. 5. As simplify 6. |
| Spec | 1. No test of `prepare_ms` for a context request. 2. No test of `{:context_not_answered, turn_id}`. 3. The reason of a plugin `exit({:shutdown, x})` changes. 4. The new module and the move of `interrupt/2` are not asked for. 5. L1 tests of an idle close, a bad action, and an error reply to an interrupt are not there. | 1. and 2. New tests ("a context build that blocks is killed at the bound...", slow, and "a context with no answer in its callback stops the provider process"). 3. Accepted hole, above. 4. See "Structure". 5. Not in the acceptance list; the existing tests of these paths check the stop, and the code path is the one `exit` in `run/1`. |
| Failure path | 1. A terminal leaves the prepare Task of an open context request running until its result. Not reproduced: a kill that comes after the cancel, so that `{:prepared}` and `{:prepare_failed}` both arrive. | 1. Accepted hole, above. Not a defect by the Ownership row. Not reproduced: closed by the OTP timer server. It sends the kill itself (`timer.erl`, `do_apply/2` for `erlang:exit/2`), before its reply to `cancel/1`, and signals from one process arrive in order. So a Task that got the reply to its cancel is never killed by that timer. |
| Codex adversarial | Approve, no findings. | None. |

No finding of round 1 reproduced a defect, so the loop ends after round 1. The fixes of round 1 are judgement and test findings: the move of `answer/5`, the rename to `stop_after/2`, a comment, and two tests. The simplify fixes came before the review agents ran. By the rules of `/ship`, they get no further round.

## After the rebase onto master (#306, #298)

A reduced round checked the moduledocs of `hands.ex`, `session.ex`, and `provider.ex` against the context request. Two texts were no longer true, and they are fixed:

- `hands.ex`: the prepare Task runs at the start of a connected turn and also at each context request.
- `session.ex`: a connected turn fails only when its first prepare Task fails. A failed context build goes to the provider as `{:context, turn_id, {:error, reason}}`.

`provider.ex` was still true. The coordinator accepted hole 1. C4 and the Ownership row of `docs/features/one-provider-path.md` now state it. `hands.ex` is 396 lines and `session.ex` stays at 453.
