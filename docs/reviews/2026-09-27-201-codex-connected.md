# Review: Codex connected provider (#201)

Invariant: one Codex program serves the harness process of a session; each `{:turn, ...}` gets exactly one reply and one terminal, or the harness process stops; a request goes out only when no answer with its id is due, so each answer belongs to one request, whatever the order of the answers and the turn's notifications; an interrupt with an open `commandExecution` item answers `{:error, :command_running}` and the program stops, otherwise `turn/interrupt` stops the turn and the program stays; a turn that ends with an open `commandExecution` item, whatever its status and whether or not an interrupt is pending, stops the program, so no new turn starts on a program while a command of an earlier turn can still run. Entry points: `Helyx.Provider.Codex.harness_init/3`, `harness_request/3`, and `harness_info/2`, which Core calls from `Helyx.Session.Harness`; every program line goes through `HarnessIO.lines/3` under the 16 MiB line cap and then `in_order/2` under the 10,000 held events cap. Documented exceptions: events of a turn can go out before its `:ok` reply ("Turn states"); a line over the cap, the held events over the cap, and the program's exit stop the harness process and drop the held events. Accepted holes: a codex that does not exit within the 5,000 ms TERM grace is KILLed and can leave a command group running (row "Codex program"); stderr is dropped. Open holes, not seen with the real program: a command of a sub-agent thread is not tracked, and an open tool item of another type is dropped at the turn's end ("Built in #201"; they wait for a decision).

Feature docs: `docs/features/long-lived-harness.md` (sections "Codex" and "Built in #201"), `docs/features/coding-agent.md` (Codex rows).

## Manual run with the real program

`codex-cli 0.157.1`, model `codex/gpt-6-luna`, through `Helyx.Session` (script in the worker scratchpad, not in the repo), 2026-09-27:

- Turns 1 ("ONE") and 2 ("TWO") ran on one harness process and one watchdog OS pid.
- An abort during model output (a 200-word essay) returned in 10 to 17 ms. The program stayed, and turn 3 ("THREE") ran on it.
- An abort during the command `sleep 23.417 && echo slept` returned in 60 to 78 ms. The command's `zsh` and `sleep` processes were gone when the abort returned. No `turn/interrupt` was sent.
- Turn 4 ("FOUR") started a new harness process and program, and resumed the thread (no `harness_session` event).
- After the run, no `sleep 23.417` process was left.

A direct callback probe saw the `turn/start` result before `turn/started`, the reuse of request ids 5 and 6 across turns with no error, and the interrupt result `{}` then `turn/completed` with `interrupted`; the reply `:ok` went out about 4 ms after the request.

The ticket's line "an abort during a command leaves the program alive" predates the owner decision on #201 ("stop the program when a command of the turn is open; interrupt otherwise"). Under the decision the program stops.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: `origin/master`.

Simplify (four agents):
- Reuse: the `keep_port` note in `Helyx.HarnessIO` named only Claude Code. **Fixed**. Skipped: `handshake/1` through `harness_info/2` (the handshake receives only port messages, on purpose, before Core sends any request); one test driver for `codex_test.exs` and `harness_epipe_test.exs` (the #200 worker changes the epipe test at the same time).
- Simplification: `ended` and the `end_turn/1` call after every line. **Fixed**: `turn/completed` called `end_turn/2`. `in_order/2` repeated `push/2`. **Fixed**. `turn/0` needed a comment. **Fixed**. Skipped: `done?` and `deadline` (`HarnessIO.start/5` and `lines/3` write them); `remaining/1` as private (Claude Code code, another worker).
- Efficiency: 4 small costs. Skipped: each is bounded by a cap or runs once per turn.
- Altitude: `lines/3` with a decode that returns actions, an optional `stream/3` in `Helyx.Provider`. Skipped: changes outside the ticket, in shared code that the #200 worker changes. The rule "an open command gives `{:error, :command_running}`" in two places. **Fixed** in round 2.

### Standards: 0 hard, 9 judgement calls

`@idle` repeated the struct defaults (**fixed**: `@turn_fields` with the defaults of `%State{}`); two long comment lines and two idioms ("and the like", "whichever comes first") (**fixed**); the manual run as a dated log in a feature doc (**fixed**: moved here). Accepted: the repeated `done?: true, terminal:` update (the `HarnessIO` contract), the names `turn` and `turn_id` (the struct doc states them), `command/3`, the `harness_info/2` catch-all (Core passes every other message, `Helyx.Provider`), and the two test drivers.

### Spec: 0 missing, 1 note, 1 gap, 2 doc mismatches

1. The `:item_of_ended_turn` and `:turn_not_asked` stops apply at any time, not only after an interrupt. **Accepted and documented** in "Built in #201": the program runs one turn of its thread at a time.
2. The research note did not record `turn.id` and the observed order. **Fixed**.
3. The held events row said "any terminal sends them all". **Fixed**: the turn's end.
4. The stdin row did not name `thread/inject_items`. **Fixed**.

### Failure path: 1 finding

1. A `turn/completed` before the `turn/start` answer reset the turn, so the late answer stopped the harness process with `:turn_not_asked`, and the terminal of the turn was lost. **Fixed** in round 2 by holding the terminal until the answer.

Checked with no finding: the interrupt barrier (#189), nil and forged values through the callbacks (#199), a different turn id in the answer.

Fix size: 43 code lines in one file, one field added. Round 2 is a full round.

## Round 2 (full rerun)

Bounds sensor: skipped, as in round 1. Base: the tree before the round 1 fix.

Simplify (one agent, four angles): 4 findings. **Fixed**: the three-branch `case`, the two-arm `if`, the redundant helper call. Skipped: `@idle` as a module attribute (a struct of the same module cannot be built at compile time).

### Standards: 0 hard, 4 judgement calls

The review file did not exist yet (**fixed**: this file); a long comment line (**fixed**); the `if` in `turn_notification` (**gone** in round 3). Accepted: the command check in two places (the round 2 simplify removed the helper).

### Spec: 1 partial, 2 wrong, 3 doc mismatches

A `turn/completed` before `turn/started` never ended the turn; events before the reply; doc lines on the order, the manual run, and the research line on `turnId`. **Fixed** in round 3 (see below) and in the docs. Events before the reply are allowed by "Turn states"; the invariant is narrowed to the reply and the terminal.

### Failure path: 4 findings on the same mechanism

1. Events before the reply. **Not a defect**: "Turn states" allows events in `submitting`, and the session drops a late reply (`Helyx.Session.Server`, the `:harness_reply` catch-all).
2. A `turn/completed` before `turn/started` never ended the turn.
3. An interrupt while the terminal was held sent `turn/interrupt` for an ended turn; its error answer stopped the harness process.
4. Two `turn/completed` lines before the answer: the later one won.

This is the second finding on the turn end mechanism, so round 3 replaced the mechanism instead of the path: a `turn/completed` of the running turn always ends the turn at once, with the reply first when the answer is still due (`answer_due`); the late answer is dropped, and the next turn sends its `turn/start` only after it, so one `turn/start` is open at a time; a `turn/completed` of any other turn stops the harness process. The `ended` field is gone.

Fix size: 67 code lines in one file, one field replaced. Round 3 is a full round.

## Round 3 (full rerun)

Bounds sensor: skipped, as in round 1. Base: the tree before the round 2 fix.

Simplify (one agent, four angles): 3 findings. **Fixed**: the repeated tuple in the late-answer clause, the internal detail in the moduledoc, the test sleep. The test sleep is now a gate file (`after_go/3`, `go/1`), so the tests do not depend on timing (standards item 3).

### Standards: 0 hard, 3 judgement calls

1. `answer_due` without `?`. **Gone**: round 4 replaced it with `due`.
2. The repeated `done?: true, terminal:` update. **Accepted**, as in round 1.
3. A `sleep 0.2` ordered the late answer. **Fixed**: a gate file.

### Spec: 1 partial, 1 wrong, 2 doc mismatches

1. The invariant claimed every order; a `turn/completed` before both the answer and `turn/started` stops the harness process. **Fixed**: the invariant and "Built in #201" state this as the documented stop.
2. `turn/interrupt` (id 6) had the same late-answer hole: a late error answered the next turn's interrupt. **Fixed** in round 4 by the mechanism below.
3. "Built in #201" said the reply goes out at the `turn/start` answer only. **Fixed**.
4. The round 2 record said the `turn/started` case was fixed without a condition. **Fixed** by item 1.

### Failure path: 2 findings

1. A `turn/started` while the next turn waited for the late answer was taken as that turn, whose prompt never reached the program.
2. A late `turn/interrupt` error answered the next interrupt, and Core stopped the harness process.

Both are the same mechanism as round 2: request ids are reused, and a late answer was matched to the wrong request. Round 4 fixes the mechanism: `due` holds the ids of the `thread/inject_items`, `turn/start`, and `turn/interrupt` requests without an answer; a request goes out only when no answer with its id is due (a turn waits with its prompt, an interrupt waits as pending); every answer to these ids goes through one `answer/2`; a `turn/started` with a new id counts only while the turn's own `turn/start` is open. Tests: "a turn/started while the next turn waits for the late answer stops the harness process" and "a late turn/interrupt answer does not answer the next interrupt", each checked red without its part of the fix.

Fix size: 145 code lines (78 added, 67 removed) in one file. It passes 100 code lines, so the wider scope is reported to the orchestrator before round 4.

The orchestrator confirmed the wider scope and accepted three owner points: a `turn/completed` before both `turn/started` and the `turn/start` answer stops the program; a late item or an unasked turn stops the program at any time (now a rule in the Codex section and in two Bounds rows of `docs/features/long-lived-harness.md`); the owner decision replaces the ticket line on an abort during a command (now stated in "Built in #201"). Round 4 budget: at most 10 minutes of probes and 20 repeats of one test per agent, no mutation runs, no load generators.

## Round 4 (full rerun)

Bounds sensor: skipped, as in round 1. Base: the tree before the round 3 fix.

Simplify (four agents): reuse clean; efficiency clean; simplification 2 (**fixed**: the prompt is set once in `harness_request/3`, and `replay/2` has no prompt argument; a two-branch `cond` became an `if`); altitude 3 (**fixed**: the moduledoc says an interrupt waits while an earlier answer is due; **accepted**: a helper for the three `due` puts and a named predicate for the open `turn/start`, each with two or three sites).

### Standards: 0 hard, 4 judgement calls, 1 stale comment

The `replay/2` comment. **Fixed**. Accepted: the two forms of the open `turn/start` check (one is a guard, so a function cannot replace it), the `due` checks in two functions, the name `answer/2`, the inline `asked?` argument.

### Spec: 0 missing, 0 scope creep, 1 unreproduced path, 3 doc lines

1. A `turn/started` that comes after the `turn/completed` of its own turn, while the next turn's `turn/start` is open, is taken as the next turn. Not reproduced, and against the order in the research note. **Accepted hole**, stated in "Built in #201": the harness process stops at the next line of the real turn. Closing it needs the ids of ended turns.
2. Two interrupts of one turn: the session sends at most one. **No change**.
3. The State comment on `{:pending, from}`, the moduledoc on unasked turns, and the error answer of a sent interrupt in "Built in #201". **Fixed**.

### Failure path: 0 findings

The round 3 reproductions pass. Probes through the fake program, 5 of 5 runs each: a late `thread/inject_items` answer with an interrupt while the prompt is held; an error answer to `thread/inject_items`; a late `turn/start` answer with no `turn.id`; both late answers of a turn with the next turn asked and interrupted. Read only: a close while an answer is due, an answer that never comes (bounded by the armed kill, no fall-through to the send, #189), the reply values before the cancel (#199).

No reproduced defect, so the wording and judgement fixes end the loop with no further round.

## Codex round 1

One confirmed finding: `end_turn/2` kept the program after a `turn/completed` with no pending interrupt while a `commandExecution` item had no `item/completed` (a failed turn, or any turn that completed with an open command). The command outlives its turn (#198), so the next `turn/start` could overlap it. **Fixed**: every turn end with an open command stops the harness process with `:command_running`, whatever the status and whether or not an interrupt is pending; the Core stop path releases the program before the next turn. Tests: "a failed turn with an open command stops the harness process, and the next turn starts a new program" (the command's group is gone, and the next turn runs a second program) and "a command that starts after the interrupt stops the harness process at the turn's end". Both fail without the fix. The tests whose open item stood for a call with no result use a `webSearch` item now.

The failure-path axis should have caught it: its state table crossed the external command states with the abort, but not with the turn's end. The owner decision named the abort, and the rounds took it as the only place where a command can outlive a turn.

## Round 5 (full rerun)

Fix counted without tests and Markdown: 35 lines in one code file (19 added, 16 removed), so a full round. Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: `e02d822`. Every brief named the invariant and asked for another path where state that tracks live program work is cleared while the work can still run.

Simplify (one agent, four angles): 5 findings. **Fixed**: the moduledoc names the pending interrupt; `@search` is reused in the failed-turn test; the rule is stated once in full ("Built in #201"), and the Codex section refers to it; no review history in the feature doc. **Accepted**: a `stop/2` helper for the seven `terminal` sets (the pattern predates this fix).

### Standards: 0 hard, 3 judgement calls

The `@search` comment wording. **Fixed**. The sub-agent thread and the other open tool items: see the failure path.

### Spec: 0 missing, 0 scope creep, 1 overstated bound, 2 paths

The new Bounds row said the release ends the command; a KILL after the grace leaves the command groups. **Fixed** in the row, in "Built in #201", and in the `end_turn` comment. The two paths are the failure-path findings below.

### Failure path: the finding's reproduction passes, 2 findings on unobserved protocol paths

The reproduction passes for the statuses `completed`, `interrupted`, and `failed`, and with a pending interrupt. Two more paths, reproduced only with the fake program:

1. A `commandExecution` on a sub-agent thread never enters `commands`, because the provider reads only its own thread's lines. The turn ended `:end_turn`, and the next turn ran on the same program while the command ran.
2. An open `collabAgentToolCall` at `turn/completed` is dropped with the turn's fields, and the program stays. Its late `item/completed` stopped the harness process during the next turn with `:item_of_ended_turn`.

**Open**, not fixed: the research note has no run of sub-agent threads or of these item types, and each fix changes a documented design (the thread filter, and "the turn's end sends what is held"). Recorded in "Built in #201"; they wait for an owner decision and a run with the real program.

## Codex round 2

One confirmed finding: the `item/completed` clause removed a command from `commands` whatever its status, so an `item/completed` with `status: "inProgress"` emptied the set; the turn's end then kept the program, and the abort check passed. **Fixed at the mechanism**: every tool item's `item/completed` goes through one status check (`ended?/1`, the schema's final statuses per type, research note) before any state changes; any other status, a missing one included, stops the harness process with `:item_not_ended`. Tests: "an inProgress completion of a command stops the harness process before the turn's end" and "an inProgress completion of a command ends the turn, so an abort sends no turn/interrupt"; both fail without the fix. #224 holds the two open holes of round 5.

## Round 6 (reduced rerun, as the orchestrator set)

The fix is 49 lines in one code file and adds functions, so the ship rules call for a full round; the orchestrator set one reduced round (spec and failure path) as the last Codex round. Bounds sensor: skipped, as before. Base: `ae9585d`. Both briefs asked for another program value that the provider trusts when it clears live-work state.

### Spec: 1 finding (the same path as below)

### Failure path: the reproduction passes, 1 finding

Both agents found the same path: a `commandExecution` `item/started` with no string `turnId`, or with a non-string `id`, fell to a catch-all and was dropped, so the command never entered `commands`; the turn ended `:end_turn` and the next turn ran on the same program while the command ran (reproduced with the fake program). **Fixed**: a tool item's `item/started` or `item/completed` with no string `turnId` or item `id` stops the harness process with `:item_malformed`. Test: "a command start with no turn id or no string id stops the harness process". No further round: this was the last round the orchestrator set. The failure-path agent also named a line with no `threadId` (not reproduced); it is dropped with the other threads' lines, as in #224.

## Precommit

`mise exec -- mix precommit` passed: root 267 tests, `plugins/bundled` 388 tests and 1 property, `apps/coding_agent` 17 tests, 0 failures, no warnings, Credo and Dialyzer clean. The first run after round 6 failed one root test, `hands_test.exs:163` ("cancel releases with :cancel ..."), which this branch does not touch; it passed 20 of 20 alone, and the second run passed.
