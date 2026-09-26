# Review: session_not_found and client start errors (#188)

Invariant: every contract operation of `Helyx.Session` (`subscribe/1`, `prompt/2`, `steer/2`, `follow_up/2`, `abort/1`, `set_model/2`) on a session that is not running returns `{:error, :session_not_found}` through one private `call/3`, a caller holds at most one registration for a session, and a failed `subscribe/1` (`:session_not_found` or a `:timeout` exit) leaves no registration of the caller for the session. `client_start_error/1` is the one mapping from a start or resume error to the closed list of ADR 0006, section 2, and a ref passes only within the bounds of `Helyx.ModelRef`. Boundaries: the pid lookup (no process, or a stopped Core whose Registries raise `ArgumentError`), the exit of `GenServer.call/3` (every reason, except a `:timeout` of a process that still lives), and the start error term, which includes a model ref from the session file. Accepted hole: after a failed subscribe, an event of the session can stay in the caller's mailbox; a client drops it by `seq` once it has a snapshot. Exception: session instance identity (a resume reuses the id and starts `seq` at 0; two Cores can hold one id) is out of scope and tracked in #204, which blocks #191. Documented exception: `model/1` is not in the contract and keeps its exit.

Feature doc: `docs/features/session-not-found.md`.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

Simplify (before the round): `@start_failed` inlined; the TUI mount exits with `{:session_down, :session_not_found}` on both paths. Skipped: remove `client_start_error/1` (the ticket asks for it); `start_for_client/2` wrappers (the ticket asks for one mapping function); one shared "session ended" string.

### Standards: 0 hard, 6 judgement calls

1. `model_error(:session_not_found)` in the TUI is not a model error. **Fixed**: renamed to `switch_error/1`.
2. The guard of `client_start_error/1` repeats the tags of `model_error()`. **Accepted**: no function tests "is a model error"; the test of the pass-through list fails when a tag is missing.
3. The doc said "Every transport calls it", but no transport exists. **Fixed**: "A transport calls it".
4. `timeout \\ 5_000` repeats the `GenServer.call/3` default. **Accepted**: the bounds table states it.
5. The test name "a text that is not UTF-8 is refused before the call" also covers a model error. **Fixed**: "input errors win over session_not_found".
6. The Registry partitions stay suspended when an assertion fails. **Accepted**: each test has its own Core, which `start_supervised!` stops.

### Spec: 0 missing, 4 notes

1. The "session ends during the snapshot call" test kills the session after the call is queued, not before the call is sent. **Accepted**: the window before the call gives `:noproc`, which the "dead session that is still registered" test and the "ended" test cover.
2. `mount/1` still calls `Session.pid/1` after the subscribe. **Accepted**: stated in the feature doc; ticket 2 of ADR 0006 removes it.
3. A `:timeout` exit of `subscribe/1` keeps the registration. **Accepted**: written as a hole in the feature doc.
4. A stale TUI comment named a `noproc` crash on the next key press. **Fixed**.
5. The bounds row of the log line did not say that `inspect/1` limits apply per collection. **Fixed** in the doc.

### Failure path: 2 findings, both reproduced

1. `client_start_error/1` passed `{:invalid_model_ref, ref}` unchanged. On resume the ref comes from the session file, so a client got a 1,000,024-byte ref. **Fixed**: the ref passes only as valid UTF-8 of at most 256 bytes (`Helyx.ModelRef.max_bytes/0`); any other ref becomes `{:start_failed, text}` and goes to the log. Tests at 256 bytes, at 257, at 128 two-byte characters (256 bytes), one byte over with a multibyte ref, and a byte that is not UTF-8.
2. A failed `subscribe/1` left in the caller's mailbox the events that the session sent to the new registration before it died. A client that subscribes after a resume with the same id could apply them as live. **Fixed**: with no other registration of the caller for the id, the failed subscribe flushes the events of the id. The test queues a prompt, a stop, and the snapshot call on a suspended session; it failed without the flush and passes with it.

Fix size: 42 added and 14 removed code lines in 3 files, with new functions, so round 2 is a full round.

## Round 2 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: the tree before the round 1 fixes.

Simplify: no change applied. Two points were taken into the round 2 fix below (one ref rule in `Helyx.ModelRef`; control characters). Skipped: a shared constant for the `:start_failed` text in the tests; a separate commit for the `switch_error/1` rename. Skipped: bound the ref inside `ModelRef.parse/1`, because that changes the error of `parse/1` for every caller; the client mapping is the boundary to a client.

### Standards: 0 hard, 6 judgement calls

1. The ref check in `Helyx.Session` repeated part of the rule of `ModelRef.parse/1`. **Fixed**: `Helyx.ModelRef.bounded?/1` holds the rule, `parse/1` and `client_start_error/1` both call it, and `max_bytes/0` is gone.
2. A ref with a control character from the session file passed to a client. **Fixed** with item 1: `bounded?/1` refuses whitespace and category C characters. Tests: `"a b"`, `"a/\e[2J"`, `"a/b\n"`.
3. The `@doc` of `subscribe/1` did not state the mailbox flush. **Fixed**.
4. The flush loop has no deadline. **No finding**: the dead session sends no new event.
5. The `:start_failed` text is in three places. **Accepted**: the tests assert the exact value.
6. The tests hard-code 256. **Accepted**: the test names the bound of `Helyx.ModelRef`.

### Spec: 1 finding

1. The events Registry has duplicate keys and sends one event for each entry. A caller that subscribed before and then failed a second subscribe kept one copy of each event from the failed entry, because the flush ran only with no other entry. **Fixed** (see below).

### Failure path: 1 finding, reproduced

1. The same path as the spec finding: seqs `[1, 1, 2, 2, 3, 3, 4, 4]` stayed in the mailbox. This is the second finding on the flush mechanism, so the fix changes the mechanism: a caller holds at most one registration for a session (a second subscribe does not register again), and a failed subscribe removes the caller's registration and every event of the id. The test subscribes twice, checks one entry, makes the session emit and stop before the snapshot call, and checks that no event and no entry stays. It also removes the double delivery after a second successful subscribe, which existed on master.

Invariant 1 held under every probe of round 2.

Fix size: 28 added and 23 removed code lines in 2 files, with a new function and a removed one, and the two-findings rule applies, so round 3 is a full round.

## Round 3 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: the tree before the round 2 fix.

Simplify: the new test copied the suspend harness of the older flush test. **Fixed**: merged into one test. The comment at the register check now says why the check and the register do not race.

### Standards: 0 hard, 5 judgement calls

1. `bounded?/1` checks more than size. **Accepted**: the module doc of `Helyx.ModelRef` calls all these rules its bounds.
2. The `@doc` of `client_start_error/1` said the rule twice. **Fixed**.
3. `Registry.values(...) == [nil]` names the stored value. **Accepted**: the value is part of what the test pins.
4. The merged test lost the comment on the suspend harness. **Fixed**: restored.
5. No other smell.

### Spec: 1 finding, 1 read-only note

1. A caller that subscribed, did not read its events, and subscribed again after a resume kept the events of the old instance. The resumed session starts at `seq` 0, so the client applied them as live (probe: snapshot `seq` 0, then old events 1..9). **Fixed** (see below).
2. A concurrent resume can send an event to the caller's entry after a failed subscribe drops the events. Not reproduced. **Accepted** as a hole in the feature doc: the next subscribe drops it.

### Failure path: 1 finding, reproduced

1. A subscribe that exits on `:timeout` kept its entry, and a caller that caught the exit then got 9 events with no snapshot. Round 1 had written this as an accepted hole. **Fixed** (see below).

Both findings are on the same mechanism as the round 1 and round 2 findings: the state of the caller for a session around `subscribe/1`. So the fix is a rule for all paths, not a patch for the path: every subscribe drops the queued events of the id before it registers, and every failed subscribe, `:session_not_found` or an exit of the snapshot call, removes the entry and drops the events again (`leave/2`). Tests: a re-subscribe after a resume with unread events of the old instance; a subscribe to a suspended session that times out. Both failed without the fix and pass with it.

Fix size: 23 added and 10 removed code lines in 1 file, with a new function (`leave/2`), and the two-findings rule applies, so round 4 is a full round.

## Round 4 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: the tree before the round 3 fix.

Simplify:
- The timeout test left the session suspended when an assertion failed. **Fixed**: it resumes before it asserts.
- `leave/2` looks up the registry again. **Skipped**: the `catch` clause has no `registry` in scope.
- The test helper for `Registry.values/3`. **Skipped**: three short lines.
- The timeout test waits 5 s. **Accepted**: `subscribe/1` has no timeout argument, and the module is async.
- Altitude: the root cause of old-instance events is that a resume starts `seq` at 0 and an event has no instance id. The mailbox drop reaches only a local client. **Settled** by the owner decision below: the drop is removed, and instance identity is #204.

### Standards: 0 hard, 5 judgement calls

1. The registry lookup repeats in `leave/2`. **Accepted**: the `catch` clause has no `registry` in scope.
2. The general `catch :exit` in `subscribe/1` sees only `:timeout`, and `exit(reason)` drops the stacktrace. **Fixed**: a comment says that `call/3` lets only a timeout exit, and `:erlang.raise/3` keeps the stacktrace.
3. The name `leave/2` does not say that it drops events. **Fixed**: `leave/2` is gone with the drop; both paths call `Registry.unregister/2`.
4. The resume test waits for any message, not for an event. **Fixed**: the test is gone with the drop; the old-instance case moves to #204.
5. The timeout test does not check the mailbox drop, or a caller with an earlier entry. **Fixed**: the test subscribes once before the timeout and checks that no entry stays. The mailbox check is gone with the drop.

### Spec: 3 findings

1. **Moved to #204** (instance identity). A successful subscribe keeps its entry into the next instance. After a resume with the same id and `seq` 0, the TUI monitors the new pid from `Session.pid/1` and `ViewModel.apply/2` drops or applies the new events against the old snapshot.
2. **Accepted** as the hole of the feature doc: the event stays, and a client drops it by `seq`. On `:timeout` the session is alive, and `Registry.dispatch/3` can send one event after `leave/2` drops the events (`leave/2` existed before the owner decision). The feature doc names only a concurrent resume.
3. **Fixed** by the owner decision: the drop, and `flush_events/1`, are removed. `flush_events/1` matched the session id only, not the Core.

### Failure path: 1 finding, reproduced

1. **Fixed** by the removal of the drop; the same-id case of two Cores moves to #204. Two Cores resume one `sessions_dir`, so two sessions have the same id. A subscribe to Core B drops the unread events of the caller's live subscription to Core A (4 events to 0), and the Core A stream then has a gap in `seq`. The failure branch does the same. `lib/helyx/core.ex` says that sessions and their subscribers are scoped to their Core.

### Owner decision

The round 4 findings share one cause: an event does not name its Core or its session instance. The owner chose option 1: remove the mailbox drop of rounds 1 to 3, keep the removal of the registration on every failed subscribe, accept that an event can stay in the mailbox after a failed subscribe, and track session instance identity in #204, which blocks #191.

## Round 5 (full rerun)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: the WIP commit 78c827f. The fix of the owner decision: 11 lines added and 27 removed in `lib/helyx/session.ex`, and functions removed, so the round is full.

Simplify: clean. The altitude note of round 4 is settled.

### Standards: 0 hard, 7 judgement calls

1. The registry lookup repeats in the `catch` of `subscribe/1`. **Accepted**: the `catch` clause has no `registry` in scope.
2. The comment of the `catch` in `subscribe/1` did not say that only the snapshot call exits there. **Fixed**.
3. The doc sentence "So does a snapshot call that exits on its timeout" was unclear. **Fixed**: two sentences.
4. `seqs == Enum.uniq(seqs)` also holds for no event. **Fixed**: the test asserts `seqs != []`.
5. The hole of the feature doc named no ticket, and Ownership did not name the hole. **Fixed**: "open, #204" in both; the hole text limits the `seq` drop to one session instance.
6. The feature doc held review history. **Fixed**: one pointer to this record.
7. This record had an empty Round 5 heading and stale `leave/2` text in round 4 spec item 2. **Fixed**.

### Spec: 1 finding

1. **Fixed**. A session that stops with the reason `:timeout` gives the exit `{:timeout, _}`, the same as a call timeout, so `call/3` exited for a session that is not running. `abort/1` with `:infinity` did the same. `call/3` now reads the pid first and, on a `:timeout` exit, returns `{:error, :session_not_found}` when the process is dead. Test: "a session that stops with the reason :timeout during a call".

### Failure path: 1 finding, reproduced

1. **Fixed**. A stopped Core makes the Registry functions raise `ArgumentError`, so every operation raised. The first reproduction was `subscribe/1`; the test of the fix showed the same raise in `call/3` through the `:via` lookup, and in `set_model/2` through `Helyx.Provider.find/2`. Fix at the root: `pid/1` returns `nil`, `call/3` calls the pid from `pid/1`, and `subscribe/1` and `set_model/2` rescue `ArgumentError` from their Registry read. Test: "every operation after the Core stopped".

Fix size: about 45 lines in `lib/helyx/session.ex`, two tests, and the docs; functions added and changed, so round 6 is full.


## Round 6 (full rerun)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: the WIP commit 78c827f plus the round 5 fix.

Simplify: `running?/1` removed; `call/3` reads the pid once and `call_pid/3` checks `Process.alive?/1` on the `:timeout` exit.

### Standards: 0 hard, 2 judgement calls

1. The `rescue` clauses of `subscribe/1` and `set_model/2` cover the whole body. **Accepted**: in `set_model/2` only `Registry.meta/2` can raise `ArgumentError`, because `ModelRef.parse/1` is pure and `Helyx.Provider.turn/1` contains all plugin raises; in `subscribe/1` only the Registry calls can raise, because `pid/1` rescues for `call/3`.
2. The `:timeout` reason test did not say which two messages it waits for. **Fixed**: a comment.

### Spec: 0 findings

Note: the `catch` clause of `subscribe/1` could raise `ArgumentError` when the Core stops after the liveness check. Closed by failure-path finding 1.

### Failure path: 2 findings, 1 reproduced

1. **Fixed**. While a Core stops, the events Registry can be there without its partition, and the register of `subscribe/1` raises `ErlangError` (`:noproc` of the link), not `ArgumentError`. The unregister in the `catch` clause could raise when the Core stops after the liveness check. Two findings on one mechanism (a Core that is gone, found by the exception name), so the fix is in one place: `subscribe/1` rescues `ArgumentError` and `ErlangError`, and both removals go through `leave/2`, which returns `:ok` when the Registry is gone. Test: "a subscribe while the Core stops".
2. **Documented**. `Registry.register/3` links the subscriber to the partition, so a Core stop ends a subscriber that does not trap exits with `:shutdown`, before it can get `:session_not_found`. This is Registry behaviour, not new in #188. The `subscribe/1` doc and the feature doc state it.

Fix size: about 20 lines in `lib/helyx/session.ex`, one test, and the docs; a function added, so round 7 is full.

## Round 7 (full rerun)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: the tree after the round 5 fix.

Simplify: clean.

### Standards: 0 hard, 3 judgement calls

1. `leave/2` rescued `ErlangError`, but `Registry.unregister/2` raises only `ArgumentError` when the Registry is gone (probe on Elixir 1.19.5, OTP 28). **Fixed**: `leave/2` rescues `ArgumentError` only.
2. The comment of "a subscribe while the Core stops" named the wrong cause. **Fixed**: the events Registry stops its partitions before it stops itself.
3. One bullet of the feature doc joined three statements with semicolons. **Fixed**: separate sentences and bullets.

### Spec: 0 findings

### Failure path: 0 findings

Checked and rejected: a sessions Registry that is gone while the events Registry lives (the stop order cannot make it; `pid/1` covers a brutal kill); an events partition that crashes while its session runs (no boundary input can make it, and no registration stays); a caller that traps exits gets the `:EXIT` of the partition (Registry behaviour, not new in #188).

Fix size: 1 line of code in one file, no function added or removed. Round 8 is reduced.

## Round 8 (reduced rerun)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: the tree after the round 6 fix.

### Spec: 0 findings

### Failure path: 0 findings

`Registry.unregister/2` fails only with `ArgumentError` (ETS `badarg`, or `info!/1`) in each state a Core stop makes: the partition alive, the partition gone, and the Registry gone. So `leave/2` never raises, and the timeout exit reaches the caller.
