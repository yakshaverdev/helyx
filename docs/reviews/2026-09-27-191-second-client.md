# Review: the second-client test with the local transport (#191)

Base: `origin/master` at `a915e4c`. Four rounds: the first, complete round, then three reduced rounds. Every fix changed only test files, so each count below is 0 code lines, and a reduced round applied.

## Change

A test-only change. `plugins/bundled/test/helyx/tui/second_client_test.exs` runs a second client against a real session. The session has a local-turn test provider (`Gated`) and a gate tool. The second client is a process that uses only `Session.subscribe/1`, `Session.steer/2` and the events. It joins while the reply streams, disconnects (its process ends), subscribes again, and steers. The test process is the client that watched from the start. Three cases: a turn that succeeds (the reconnect and the steer happen while the tool runs), a turn that fails, and an abort while the first of two calls runs. At each join, the unfiltered view model of the joined client equals the view model of the live client without notices and without the partial reply of a failed or aborted turn (ADR 0006 section 3). The abort case asserts the accepted difference: one closed `aborted` cell for the unstarted call `t2` in the joined client, none in the live client, and every other cell equal. `transcript/1` and `fold/2` move from `view_model_snapshot_test.exs` into `plugins/bundled/test/support/view_model_rule.ex`, so both tests use one copy of the rule.

Invariant: a client that uses only the contract and joins or reconnects at any of these points shows the view model of a client that watched from the start, except the exclusions and the accepted difference of ADR 0006 section 3. After a reconnect its `seq` is the `seq` of the new snapshot, and no event at or below it changes the view. Entry points: `Session.subscribe/1`, `Session.steer/2`, `ViewModel.from_snapshot/1`, `ViewModel.apply/2`. Accepted gaps: this test does not produce the partial reply of an aborted turn (`view_model_snapshot_test.exs`, "a join after an abort during a partial reply", covers it); the only steer into a running turn is in the success case, and in the other two cases the steer starts a turn. The test found no defect in the session or the contract.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1 (complete)

### Simplify

Four agents. Fixed: the ADR rule helpers (`transcript/1`, `fold/2`) were copies of the snapshot test's helpers, so they moved into `Helyx.Test.ViewModelRule` (reuse, altitude). The client no longer holds a view model (the test folds it). The steer check is one `match?` on the folded view. Skipped: sharing the `Gate` tool and the forwarding client with the snapshot test (they differ in steer and disconnect; share them when a third test needs them), splitting `catch_up/2` into two functions, and replacing the list append in `catch_up/2` (a turn has a few dozen events).

### Standards

No hard violations. Judgement calls:

- Fixed: the lost cross-reference comment. The support module now says that a snapshot never holds the excluded cells.
- Skipped: `spawn_link` and a later `Process.monitor` in `disconnect/1`. The client blocks in `receive` until `:disconnect`, so it cannot exit before the monitor is set. The link ends the client with the test.
- Skipped: the bare map `live`, the `{client, view, live}` data clump, the forwarding `fold/2` in the snapshot test (it also takes a snapshot), and the name `ViewModelRule`.

### Spec

No missing requirement. Fixed:

- `transcript/1` ran on both sides of each comparison, so a snapshot that held a notice or a failed partial reply still passed. Now only the live side is filtered.
- The replacement at the reconnect was trivially true. The first joined view model is now kept, and the reconnect checks that the new `seq` equals the snapshot's and is above the old one.
- The waits for the gate used the 100 ms default timeout. They now wait 1 s.

### Failure path

No findings. 300 runs passed. Probes that held: a join while `t1` runs and before the abort (no early `t2` cell); one process that subscribes twice during a turn gets each `seq` once.

## Round 2 (reduced: spec, failure path)

Fix: 0 code lines (test files only).

- Spec: no regression. Mutation: when `display_only?/1` drops `:aborted`, the test still passes, because no aborted partial reply occurs here. This is accepted, see above. Also found: the `{:snapshot, _}` and `{:steered, _}` waits used the 100 ms default. Fixed, and the redundant `view != old` was removed.
- Failure path: no findings. Nine mutants (a notice, an error reply, or an aborted reply added to a joined view model) all fail the test. 300 runs passed.

## Round 3 (reduced: spec, failure path)

Fix: 0 code lines (test files only).

- Spec: no findings. It noted that `disconnect/1` still waits with the default timeout.
- Failure path: 1 finding, reproduced. When the client is suspended for 150 ms before `:disconnect`, all three tests fail at the `:DOWN` wait. This was the second finding on one mechanism (a wait with the default timeout). So the fix is at the mechanism: `@wait 1_000` is the timeout of every `assert_receive` and every `receive ... after` in the file.

## Round 4 (reduced: spec, failure path)

Fix: 0 code lines (test files only).

- Spec: no findings. Every wait of the test process uses `@wait`, and every acceptance line is still checked.
- Failure path: no findings. The round-3 reproduction passes. Stalls of 150 ms of the session server, the stream Task, the tool Task and the client at each step pass. No wait in the helpers or the contract calls is shorter than 1 s.
