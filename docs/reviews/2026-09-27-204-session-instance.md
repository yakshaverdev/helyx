# Review: session instance identity (#204)

Invariant: every event and every snapshot of one session process carry one `instance_id`, which `Helyx.Session.Server.init/1` makes for each start of the process (a start, a resume, a restart), so it differs from every other instance with the same session id, in this Core or another. A client that drops every event of another instance, and then every event with a `seq` at or below its snapshot's, never applies an event of another instance. Entry points: `Helyx.Session.Server.init/1` (the id), the one event builder `do_emit/4` and the one snapshot builder in `Helyx.Session.Server`, and the client rule in `Helyx.TUI.ViewModel.apply/2`, which `from_snapshot/1` arms at mount and at a reconnect. Documented exception: `ViewModel.new/1` has no instance and drops every event; only render tests call it. Open hole: the end signal and the lost signal carry the session id only, so the flush in `subscribe/1` can remove a signal of the caller's subscription in another Core with the same id (`docs/features/end-signal.md`); a fix changes the signal shape of the contract, so it waits for an owner decision.

Feature doc: `docs/features/session-instance.md`.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: `origin/master`.

Simplify:
- Reuse: the two-Core test started a second Core by hand. **Fixed**: `start_core/1`.
- Simplification: `ViewModel.new/2` put a meaningless instance id in every render test. **Fixed**: `new/1` stays, and the fold helper of `view_model_test.exs` sets the instance. A redundant mailbox assert in the two-Core test. **Fixed**: removed. The new view model test wrote a full event literal. **Fixed**: it uses `events/1`. Skipped: merge the two resume tests (one checks the ids of a start and a resume, the other is the named case of #188, round 4); state the client rule in fewer places (each place is the doc of a module or a record that a reader opens alone).
- Efficiency: clean.
- Altitude: the end signal and the lost signal still carry only the session id. **Not fixed**: a change of the signal shape of the contract, which the ticket does not state; open, owner decision.

### Standards: 0 hard, 5 judgement calls

1. The comment of `Helyx.Session.Id` did not list session instances. **Fixed**.
2. `ViewModel.new/1` makes a view model with no instance, which drops every event, and the type allows `nil` for it. **Accepted**: only render tests call it; its doc now says so (spec item 1).
3. `{instance_id, seq}` travels as a pair. **Accepted**: the contract structs are flat.
4. The client rule is written in several docs. **Accepted**: see simplify.
5. The event literals in the TUI tests. **Accepted**: the duplication was there before this change.

### Spec: 0 missing, 2 notes

1. The doc of `ViewModel.new/1` still said "a fresh session". **Fixed**.
2. The signal hole has no ticket. **Reported** to the owner with the change: the owner decides the signal shape.

The spec agent agreed with both decisions of the feature doc: no Core in the event (a random instance id already differs between Cores, and a Core name is server configuration), and no mailbox drop at subscribe (the client rule covers local and remote clients, and the drop of #188 made the two-Core finding).

### Failure path: 0 findings

Checked: the id is set before the aborted results of a resume; `Server` is the only builder of an event and a snapshot; a restart gets a new id; the order of `subscribe/1` (pid, join, snapshot of that pid) across a resume in the window; the three places where the TUI sets its view model.

Fix size: 2 lines of doc and comment in 2 code files, no function added or removed. It touches more than one code file, so round 2 is a full round.

## Round 2 (full rerun)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: the tree before the round 1 fix.

Simplify: clean on all four angles. Skipped: "a view model for `model`" as the wording of the `new/1` doc.

### Standards: 0 hard, 3 judgement calls

1. `ViewModel.new/1` is a function in `lib/` that only tests call. **Accepted**, as in round 1.
2. The reason of the client rule is in four module docs. **Accepted**, as in round 1.
3. `session_id`, `instance_id`, and `seq` travel together. **Accepted**: three fields of a flat contract struct.

### Spec: 1 finding

1. Three docs still stated the old rule: the accepted hole of `docs/features/session-not-found.md` ("open, #204", and `seq` only), the snapshot shape and step 3 of `docs/features/session-snapshot.md`, and the event line of `docs/features/coding-agent.md`. **Fixed**: each names `instance_id` and the rule.

### Failure path: 0 findings

A throwaway test through the boundary: a view model from a snapshot in Core A, then events of the same id resumed in Core B and resumed again in Core A, each with a `seq` above the view model's; the view model did not change.

The round 2 fix is Markdown only, so no code changed and no further round runs.
