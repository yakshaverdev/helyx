# Review: #261, remove `Session.model/1`, `provider_pids`, and the `spawn_armed` handshake

Scope: `git diff origin/master` on `ticket/261-session-dead-state`. Invariant: the session keeps no state per abort, and no exit signal of a provider Task reaches the vital `:EXIT` clause. The reply clause takes the exit signal that follows the reply. A crashed Task gives a `:DOWN` and an exit signal in either order; the clause of the first one takes the other. An abort flushes an exit signal that came before `Task.shutdown/2` unlinked. `terminate/2` does not flush, because the session ends. The waits in these clauses have no timeout: the link and the monitor guarantee the signal.

## Checked names

- `Session.model/1` and its `:model` handler, `provider_pids`, and `spawn_armed/6` with its `{:helyx_kill, tref}` handshake: all exist as the ticket states.
- `Task.shutdown(task, :brutal_kill)` in Elixir 1.19.5 (`task.ex:1345-1386`): `shutdown_send/2` calls `Process.unlink/1` before `Process.exit/2`. It flushes the reply and the monitor, not the exit signal.
- `Session.snapshot/1`, which the ticket names, does not exist. The only public snapshot is `Session.subscribe/1`, which registers the caller for events. The test callers use `GenServer.call(Session.pid(s), {:snapshot}).model`, the same call that `subscribe/1` makes, with no registration.

## Found while implementing

The ticket lists two places that take the exit signal: the reply clause and the `:DOWN` clause. Two tests failed ("a task crash fails the turn", "a failure after deltas"): a crashed Task's exit signal can arrive before its `:DOWN`, and the vital clause stopped the session. Fixed: a third clause takes an exit signal of the current Task, waits for its `:DOWN`, and fails the turn.

## Simplify

- Reuse, simplification, altitude: the snapshot call repeats in 15 test lines; a test helper or a public reader was suggested. Skipped: the #264 worker edits the same test files, and the orchestrator asked for mechanical edits. A public reader adds to the client contract (ADR 0006).
- Simplification, efficiency: the flush after `Task.shutdown/2` may be dead. Kept: `Task.shutdown/2` does not flush the exit signal, and one can be queued before the unlink.
- Simplification: use `after 0` in all four receives. Kept: in the reply and crash clauses the signal is guaranteed, and a non-blocking receive could miss one that is still on its way.
- Simplification, standards: the test compares `:erts_debug.flat_size` of the state. Kept: it is what fails when state grows per abort; the mailbox check alone would pass with the old set.
- Reuse: `end_work/1` could call `shutdown_stream/1`. Skipped: the session ends there.
- Altitude: `Task.Supervisor.async_nolink` would remove the exit signals. Rejected: an untrappable kill of the session must take the provider Task (ADR 0004, test "killing the session kills the provider Task").

## Round 1 (full)

Bounds sensor: `bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer`.

| Axis | Finding | Resolution |
|---|---|---|
| Standards | the bounds row does not state the wait of the blocking receives | fixed: the row states that the wait has no timeout, and why it ends |
| Standards | `docs/features/long-lived-harness.md` still says the hands arm the connect and prepare kills | fixed: three lines |
| Standards | the snapshot call repeats in 15 test lines; `shutdown_stream/1` also flushes (judgement calls) | kept, see Simplify |
| Spec | the same doc drift in `long-lived-harness.md` | fixed, as above |
| Spec | `Session.snapshot/1` does not exist | recorded under Checked names |
| Spec | the third `:EXIT` clause is not in the ticket | kept: required, see "Found while implementing" |
| Failure path | none reproduced: abort at 66 delays against the reply, crash, and empty ends of a turn; the session stayed up with an empty mailbox each time. Not reached: connected and external turns, a suspended armed Task | none |
| Codex | `shutdown_stream/1` split the two `start_stream/3` clauses, so compilation warns and `--warnings-as-errors` fails (reproduced) | fixed: the `:external` clause moved up |

## Round 2 (reduced)

The fix moves one clause: 12 lines, one file, no function added or removed. Base: the WIP commit of round 1.

| Axis | Finding | Resolution |
|---|---|---|
| Spec | none: the root, `plugins/bundled`, and `apps/coding_agent` compile with `--force --warnings-as-errors`; the changed test files pass | none |
| Failure path | none reproduced: a suspended session with an abort queued before the reply or crash signals of `test/ok` and `test/crash` (10 each), and 20 back-to-back prompt and abort pairs; the session stayed up with an empty mailbox. Not reached: a provider that unlinks its own Task from the session (the blocking receive would then wait; providers are trusted code), a task supervisor that dies during the start | none |

Round 2 reproduced no defect, so the loop ends.
