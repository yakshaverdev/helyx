# Review: an unknown event type in the TUI view model (#206)

Base: `origin/master` at `494922f`. One round, the first and complete round. It changed no code, so no rerun round.

## Change

`Helyx.TUI.ViewModel.apply/2` gets a clause after the stale-seq clause: an event whose type is not in `@known_types` returns the view model unchanged, `seq` included. `@known_types` lists the 12 types that `fold/2` has clauses for. A known type with another shape still reaches `fold/2` and crashes, as before. The `@doc` of `apply/2` states the rule and cites ADR 0006, section 5. One test folds a started turn and then sends an event of type `:from_a_newer_core` with a higher seq.

Invariant: an event of a type that `fold/2` does not know never changes the view model and never crashes the TUI. The entry point is `ViewModel.apply/2`, the one path where an event reaches the view model (`Helyx.TUI.handle_info/2`, `{:helyx_event, event}`). Accepted hole: a new value in a known type (a new `message_update` key, a new message role) still crashes; see "Reported" below.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Four agents: reuse, simplification, efficiency, altitude. One fix.

- Fixed (simplification): the comment on `@known_types` now says that the list holds one entry for each type that `fold/2` has a clause for, and that a type not in it is dropped.
- Skipped (simplification): move the list into `Helyx.Event` as `types/0`. The list is what this client knows, not what Core emits (ADR 0006, section 5), and the change stays inside the view model.
- Reuse, efficiency, altitude: none. A catch-all `fold/2` clause was rejected by all four, because it hides a known type with a bad shape.

### Standards

No hard violations. One judgement call, skipped: `@known_types` repeats the `fold/2` clause heads and the `Helyx.Event.type()` union (mild Duplicated Code). A type added to `fold/2` but not to the list is dropped silently. The ADR semantics justify a client-side list.

### Spec

Both acceptance items present. No scope creep. The only other event path in `tui.ex` (the unsupported state) already drops all events. Same drift note as Standards, skipped.

### Failure path

One reproduced finding, outside the ticket (below). Probes that hold: an unknown type leaves `seq` unchanged and a later known event still applies; a non-atom type with `data: nil` is dropped; the stale-seq clause runs first; a known type with an extra `data` key folds. Render cost of an ignored event: one `settle/1` in `tui.ex`, at most one screen of layout when scrolled.

## Reported, not fixed

A new value in a known type crashes the view model: `%Event{type: :message_update, data: %{signature_delta: "x"}}`, or a `message_start` with a new role, raises `FunctionClauseError`. ADR 0006, section 5, lets the server add "a value" within one version only when a client that ignores it stays correct, but the `apply/2` doc says a known type of another shape is a Core bug. Which rule wins is a design decision that #206 does not state.
