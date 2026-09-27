# Review: the long-lived harness process (#199)

Base: `cb229e0` (the branch point; `origin/master` has moved since). Round 1 is the first and complete round.

## Change

The Core part of ADR 0007: the optional callbacks `harness_init/3`, `harness_request/3`, and `harness_info/2` with the actions `{:event, ...}`, `{:reply, ...}`, and `{:cancel_tool, ...}`; the loop `Helyx.Session.Harness`; armed kills (`:timer.kill_after/2`) for connect, prepare, turn, interrupt, and close; the prepare Task; the turn states `preparing`, `submitting`, and `submitted` with an abort in each; the close at a model switch and at the session end; the stop. `Helyx.Provider.turn/1` returns `:connected` for an external provider that exports `harness_init/3`. `Helyx.Session.Stream` gives the event check and the capped send to the loop. The fake connected provider is `Helyx.Test.Connected`, and a watchdog harness in `plugins/bundled` tests the stop of a real program group.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Four fixes: `Provider.turn/1` returns `:connected` (the check moved out of `session.ex`); the aborting reply map is built once; `settle/1` binds the pid in its head. Skipped: a direct send from the prepare Task to the harness process (the design has the session send `{:turn, ...}`); one opts helper (the opts lists differ); a table-driven test.

### Standards

Fixed:

- Bare maps with a known shape: the harness handle is now `%Server.Connection{}`, the barrier wait is `%Server.Wait{}` (built with `struct!/2`), and the loop state is a `%Helyx.Session.Harness{}`.
- The `@doc` and the spec of `Stream.check/2` described the rejection as the message; it is `{call, reason}`.
- The loop state variable `h` is now `harness`; the `if` in the `case` head of `Provider.turn/1` is a local variable.

Skipped, judgement calls: the repeated base opts (the lists differ per path); the duplicated arm-then-send of the kill (two lines, two owners); the names `settle/1` and `progress/1` (each has its comment); the nil outcome of a prepare Task in `deliver`; the phase after a failed turn reply (commented).

### Spec

Fixed:

- The row "steer in the local queue of a `preparing` turn" is not built: the ticket queues every steer on a connected turn as a follow-up. The "Built in #199" section says so and names #202.
- The feature doc said "a reply that the loop made in time is never a timeout", but `:timer.cancel/1` cannot tell if the kill already fired. The section now states the exception: a reply at the bound can be followed by the kill, and the turn then fails at `:harness_down`.
- The abort in `submitting` did not check the late reply of the aborted turn. The test now runs a next turn and checks that the old reply and events are dropped.

Accepted: the cap of 8 open requests comes with #202 (at most two requests are open until the steer); the test of a callback killed while the hands are busy suspends the hands, which is stronger than a real release wait; a normal end runs no cleanup until #203.

### Failure path

One finding, fixed. A harness process that ended while the session was idle (a `{:stop, ...}` from `harness_info/2`) left its pid in the session until the hands finished the release and sent `:harness_down`. A prompt in that window reused the dead pid: `Hands.prepare/3` called into the hands blocked in `release/3`, and the session crashed at the call timeout. With a fast release, the new turn would instead submit to the dead pid and fail with the old reason.

Fix: before a message starts a turn and at the end of every turn or wait (`settle/1`), the session checks the harness pid. A dead one is dropped, and the session waits for its `:harness_down` in the barrier; the message waits as a follow-up. A harness process that ends after the check ends during the turn, and its `:harness_down` fails that turn. Test: "a prompt after an idle harness process ends waits for the release of its handles" (the hands are suspended to hold the window open; it fails without the fix).

Invariant restored: no turn starts while the hands still hold the handles of an ended harness process.

Rerun: the fix touches two code files and adds functions and two structs, so round 2 is a full round.

Scope of the round 1 fix, without tests and Markdown: 144 lines added plus removed in four code files. About 55 of them rename the loop variable `h` to `harness`; the fix of the failure-path finding is about 40 lines in `server.ex`, and the three structs are about 30.

## Round 2 (full)

### Simplify

Four agents over the round 1 fix. Fixed: `settle/1` branches once on the wait that `forget_ended_harness/1` can start, so `close_or_start/1` has two clauses; the rejection type of `Stream.check/2` and `send_event/4` is one `@type rejection`. Skipped: the idle prompt through `queue_reply` and `settle/1` (it adds a `queue_update` event and the queue cap to every idle prompt); a helper for the two `wait(..., %{harness: pid})` calls; the rename of `h` (the standards finding asked for it); a split into two commits (one ticket, one commit). Efficiency: clean.

### Standards

No hard violations. Fixed: the patterns now name the structs (`%Wait{}`, `%Connection{}`); `forget_ended_harness/1` is `await_ended_harness/1`, since it also starts the wait; the test aliases `Message`. Skipped: one helper for the two "wait or start" branches (two short `case`s with different actions).

### Spec

Fixed:

- The doc line on a reply at the bound was true only for a turn request. It now states the interrupt case: the abort ends as usual, and the next turn can fail with `:harness_timeout`.
- The idle wait is also found at the end of a turn or a wait, and that path had no test. New test: "a turn that ends as its harness process ends waits for the release before the next turn".
- A steer on a `preparing` turn had no test. New test: "a steer on a preparing turn waits for the next turn".
- A steer during the new wait queues as a steer and goes before earlier follow-ups, as in the wait of an abort. The doc now says so.

### Failure path

One finding, on the same mechanism as round 1. The `Process.alive?/1` check cannot close the race with an exit: a harness process that ends just after the check puts the hands into its release, and the synchronous `Hands.prepare/3` call of the new turn then times out after 5 s while the release runs (up to 20 s). The session crashed in 3 of 4 probe runs.

The two-findings rule applies, so the fix is to the mechanism: the session no longer waits in a call for hands that can be in the release of a harness process. `Hands.prepare/3` is now a cast. The hands take it in order after earlier messages of the session, so a later `request_cancel/2` still finds the Task, and the prepare kill is armed when the Task starts. `Hands.connect/3` stays a call: it runs only when the session holds no harness process, after the `:harness_down` of the last one. The alive check stays, so a prompt after an idle end waits instead of failing; a harness process that ends after the check fails the new turn at its `:harness_down`, as the comment says. The test "a steer on a preparing turn waits for the next turn" suspends the hands, and the prompt still returns with the turn `preparing`. The probe of the finding now passes 50 of 50 iterations, one of them in the race window.

Rerun: the round 2 fix is 58 code lines in two files and changes the call to a cast, and the two-findings rule applies, so round 3 is a full round.

## Round 3 (full)

### Simplify

Fixed: the last two bare `%{pid: ^pid}` patterns name `%Connection{}`; the busy-hands test was a subset of the steer test and is removed; the server comment points to `Hands.prepare/3` instead of a third copy of the reason; the `@doc` of `Hands.prepare/3` names why `connect/3`, `stream/4`, and `run/3` stay calls. Skipped: a helper for the shared lines of two tests; a split into two commits (one ticket, one commit). Efficiency: clean (the closure copies the context as the call did).

### Standards

No hard violations. The cast in `Hands.prepare/3` keeps its documented reason (AGENTS.md prefers a call; here a call blocks the session for a release, and one prepare per turn needs no back-pressure). Skipped judgement calls: the session reason in the public `@doc`; the `:ok =` match on a cast; `:sys.get_state` in the tests, as in the rest of the file.

### Spec

Fixed, docs and tests only:

- The wait of the prepare cast behind a release had no bound row. The Bounds table now has it: one release, up to 20,000 ms, so a `preparing` turn lasts at most about 30,000 ms.
- "A turn never starts while the hands still hold the handles of an old harness process" contradicted the accepted cases. It now says that a new harness process never starts before the release; a turn that starts on an old process that then ends fails at its `:harness_down`.
- The interrupt reply at the bound applies to a connected next turn, and it is now stated as accepted: the turn fails at a bound, and no request reaches a new harness process before the release.
- The "Context preparation" line said the hands reply with the pid of the prepare Task. It now says the start is a cast.
- New tests: "a harness process that ends after the check fails the new turn at its release" and "a steer during the wait for an ended harness process goes first".

### Failure path

No findings. The probe of round 2 passed 50 of 50 (2 iterations in the race window). Probes that hold, with the hands suspended during the release: a harness process that ends after the check (the session answers a snapshot and an abort); a switch to a local model while the ended process is in release; a switch while it is alive; a stop during `preparing` with `block_prepare` (the cancel finds the prepare Task). No barrier wait has a timeout that falls through to the act.

Round 3 changed only tests and Markdown, so there is no rerun round.

## Invariant

No turn of a connected provider submits to a new harness process, and no new harness process starts, while the hands still hold the handles of an ended one; every harness request, the connect, and the prepare Task are bounded by a kill armed at the OTP timer server; the session never waits in a call for hands that release a harness process. Entry points: `Helyx.Session.Harness.request/3`, `Hands.connect/3`, `Hands.prepare/3`, and `await_ended_harness/1` before a turn starts. Documented exceptions: a harness process that ends after the alive check, or a kill that follows a reply at the bound, fails the turn that started on it at its `:harness_down`. Deferred: the cap of 8 open requests and the steer of a `preparing` turn (#202), turn cleanup at a normal end (#203).

## Follow-up from the orchestrator

- Ticket numbers: steer delivery is #202 and the Helyx tools are #203 (#200 is the Claude Code provider, #201 the Codex provider). The references to #200 and #201 in the "Built in #199" section, this record, and the code comments now name #202 and #203.
- The hands crash at a Core stop with an open harness process: the Core stops the session supervisor, then the task supervisor. The session closes an idle harness process in `terminate/2`, and the hands can take its `:closed` end after the task supervisor stopped, so `release/3` fails in `Task.Supervisor.async` and the hands log a crash. It showed 3 times in the root precommit log with `Helyx.Test.Connected`. Nothing leaks: the harness process owns the port through the keeper of `Helyx.HarnessIO.keep_port/1`, which closes it when the harness process ends, and the watchdog then ends the group. Two new tests in `plugins/bundled` stop the Core with a real program under the watchdog, one with an idle harness process and one during a turn; in both the group is gone (3 of 3 runs each). The feature doc states it as a documented exception in Bounds and Ownership; the shutdown order gets its own ticket. Only tests and Markdown changed, so there is no rerun round.
