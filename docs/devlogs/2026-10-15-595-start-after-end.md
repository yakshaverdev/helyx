# 2026-10-15: #595 a start answer after turn_end

Done:

- `Wait.finish/2` holds `turn_end` while a Helyx tool call of the turn runs; `Wait.cleanup/2` emits it after the hands answer the cleanup request. The hands handle their messages in order, so a start answer that they took first reaches the session before `turn_end`, and its run counts before it. A turn with no running call gets `turn_end` at once.
- The snapshot shows the held turn as running (`Wait.snapshot_turn/1`), so the snapshot still equals the fold of the events (ADR 0006, section 3).
- The accepted hole of `print-background-wait.md` is closed. New accepted holes: the run lives although its call got `aborted`, the release delays `turn_end`, and hands that die in the wait give no `turn_end`.

Broke:

- Three sweep tests (#93) waited for `turn_end` at the start of the sweep of an abort. With a running call, `turn_end` now comes after the sweep; the tests wait for the release instead.
- A `%Wait{}` match in `Events` deadlocked the compile: `Wait` imports `Events`. `Wait` owns the rule now.

Next:

- If the live run matters, stop it at the cleanup: a count of the place (option 2 of the ticket) or a kill of the run that a turn gave `aborted`.
