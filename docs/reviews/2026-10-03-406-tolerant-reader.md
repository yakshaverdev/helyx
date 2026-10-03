# Review: #406, tolerant reader by type; one Helyx version; no TUI instance and seq guards

Branch `ticket/406-tolerant-reader`, base `origin/master` `fdbbb63`.

Invariant: `Helyx.TUI.ViewModel.apply/2` has one clause per known event type that matches the type only and checks its payload inside, so a known type with a broken payload crashes and only a type that no clause names is ignored; a `message_update` with no known delta key is ignored, two known keys or a known key with a bad value crash; a message of an unknown role makes no cell; every block that the TUI does not render shows `[unsupported block: <kind>]` in an assistant message, a user message, and a tool result; the TUI has no `instance_id` or `seq` guard and no version screen, and `Snapshot.contract_version` is gone. Accepted: a delta with no `message_start` is dropped (`docs/features/unknown-values.md`). Out of scope: #407 (cell storage, snapshot messages through the live fold).

## Deleted tests (removed cases)

- `view_model_test.exs`, "an event of another instance leaves the view model unchanged (#204)": the instance guard.
- `tui_test.exs`, "an event of a resumed instance does not change the screen of the old one (#204)": the instance and `seq` guards. The TUI exits on the end signal of the old instance.
- `tui_test.exs`, "a snapshot of an unsupported contract version shows a message, not the session": the version screen.
- `second_client_test.exs`, the `seq` asserts at the reconnect, and `view_model_snapshot_test.exs`, `fold(joined, events) == joined`: the `seq` guard. ADR 0006, consequence 4, now says so.
- `view_model_test.exs`, the two tests that a new block kind is dropped: now they check the placeholder.

## Round 1 (full)

Simplify: four agents. Applied: the `fold/2` clauses are the `apply/2` clauses (no forwarding function); the second-client test keeps the last `seq` in its own map. Skipped: a fixed placeholder text without the kind (the ADR names `[unsupported block: image]`), a `message!/1` helper (the design checks the payload inside each clause), a `%Message{}` block clause (a wrong struct and a new kind have the same shape).

Bounds sensor:

```
bounds sensor: 4 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/lib/helyx/tui/view_model.ex:128  SIZE  def apply(vm, %Event{type: :message_end, data: data}) do
```

The failure-path agent attacked the flag: a broken payload raises `MatchError`; the cell append is as before. Not a defect.

| Axis | Finding | Resolution |
| --- | --- | --- |
| Codex, failure path | An image in a user message or a tool result renders with no placeholder (`Message.text/1` skips it); the session file decodes images for every role | Fixed: `Transcript.shown_text/1` puts the placeholder in place of each block that is not text; test through `from_snapshot/1` |
| Standards | `Session.subscribe/1` doc and moduledoc still told every client to drop by `instance_id` and `seq` | Fixed: the rule is for a caller that reconnects |
| Spec | ADR 0006 consequence 4 still says the second-client test checks the reconnect `seq` | Fixed: a sentence says the check comes with the first client that reconnects |
| Standards | Three copies of the transcript texts helper in `view_model_test.exs` | Fixed: one `texts/1` |
| Standards | Moduledocs give a reason for the removal | Kept: one short sentence each with the ADR link |

## Round 2 (full)

The fix adds two functions in one code file, so the round is full. Simplify: `shown_text/1` uses `Enum.map_join/2`; the `streaming` type admits every block kind. Skipped: a placeholder helper in `Helyx.Message` (the ADR puts the rule in the client).

Bounds sensor:

```
bounds sensor: 8 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/lib/helyx/tui/view_model.ex:128  SIZE  def apply(vm, %Event{type: :message_end, data: data}) do
```

| Axis | Finding | Resolution |
| --- | --- | --- |
| Codex | A placeholder after the fourth line of a tool result is cut by the four-line preview | Rejected: the preview cuts all content past line four, text included, and shows "… N more lines"; the block is counted, not silent. The failure-path agent saw the same and called it the designed cut |
| Standards | `apply/2` doc: "Only an event of a type that no clause names leaves the view model unchanged" is false (`turn_start` and others) | Fixed: the sentence says such a type is not checked |
| Standards | Comments say "newer Core" while the TUI runs with its own Core | Fixed: "a type that this client does not know" |
| Standards | Private `text/1` has the name of `Message.text/1` with another result | Fixed: `shown_text/1` |
| Standards | ADR sentence cites #406 for deferred work | Fixed: reference removed |
| Spec | `session-snapshot.md` struct sketch still lists `contract_version` | Kept: it is marked as replaced (history) |
| Failure path | No defect reproduced | none |

Round 2 reproduced no defect, so the loop ends.
