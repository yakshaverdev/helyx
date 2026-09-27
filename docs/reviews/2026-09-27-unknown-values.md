# Review: an unknown value in a known event type in the TUI view model (#211)

Base: `8d77452` (the merge base; `origin/master` moved to `3038113` during the review, and the commit is rebased on it). Five rounds. Feature doc: `docs/features/unknown-values.md`.

## Change

`Helyx.TUI.ViewModel` ignores a present but unknown value inside a known event type, as ADR 0006, section 5, says a client does: a `message_update` with no delta key it knows, a `message_start` or `message_end` of a new role and the deltas of that message, a snapshot message or partial of a new role, and a block kind that the TUI does not render (a new struct, or an `Image`), which is dropped from an assistant message before it becomes a cell. A missing required field, a known delta key with a value of another type, two known delta keys, a non-struct block of an assistant message, and an `agent_end` with the stop reason `error` and no `error` field crash.

Invariant: no present but unknown value in a known event type or a snapshot reaches `Helyx.TUI.transcript_lines/2` or crashes the TUI, and a shape error in a known field crashes in the fold. Entry points: `ViewModel.apply/2` and `ViewModel.from_snapshot/1`. Accepted holes (feature doc): a delta with no `message_start` is dropped, not crashed; nested or interleaved messages raise the contract version and are not handled. Documented exception: a `message_update` with no known key, an empty data map included, is ignored.

## Bounds sensor

Every round:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1 (full)

- Simplify: one fix (the comment on the block filter names `Helyx.TUI.block_lines/2`, and says that an image block is dropped). Skipped: the efficiency agent said `streaming/1` runs on each frame; it runs once, in `from_snapshot/1`. Skipped: a shared block-kind predicate with `tui.ex`, which another ticket (#189) changes.
- Standards: 1 hard (the out-of-scope list named no ticket), 3 judgement (a `tool_call` of another type was ignored; `known_blocks` named the wrong property; a key list in two modules). Fixed: "No ticket, not planned"; renamed to `rendered_blocks`; a guard makes a known key with another value crash. Kept: the block list in two modules, with a comment that ties them.
- Spec: 3 minor (the same `tool_call` case, no ticket in out of scope, the image drop not asked for). Fixed as above; the image drop is in the feature doc table.
- Failure path: 0 findings.

Fix: 25 code lines, full round.

## Round 2 (full)

- Simplify: one judgement (the known keys listed twice). Fixed in round 3 by the mechanism change.
- Standards: 1 hard (a `text_delta` or `thinking_delta` of another type did not crash in the fold), 1 judgement (a non-struct block was dropped).
- Spec: 2 (the deltas of a message of a new role showed as an assistant reply; the same delta type case).
- Failure path: 2 (the same delta type case; a bad `tool_call` next to a valid key was ignored).

Two findings on the `message_update` shape mechanism, so the fix replaced the clauses with one match over `@delta_keys` that takes exactly one known key with a checked value. A delta with no open assistant message is dropped, a snapshot partial must be an assistant message, and a non-struct block crashes. Fix: 50 code lines, full round.

## Round 3 (full)

- Simplify: one fix (`rendered_block?/1` matches `%kind{}`). Skipped: `Map.take` and `Map.to_list` on each update allocate a small list; three keys at most.
- Standards: 1 hard (a delta of a new role while an assistant message is open joins the partial; a delta with no `message_start` is dropped, not crashed), 2 judgement (the non-struct rule does not hold for user and tool-result blocks; the ignore rule stated twice in the `@doc`).
- Spec: 1 (the same non-struct scope), 1 minor (nesting not stated).
- Failure path: 0 findings; a real session with the Fake provider streams all its deltas.

Resolution: `message_update` carries no message id, so nested messages are a contract change (ADR 0006, section 5), stated in the feature doc. A delta with no `message_start` is an accepted hole, stated in the feature doc; a flag for an open hidden message would close it, not planned since only a Core bug makes it. The non-struct rule is scoped to assistant messages. Fix: 17 lines of comment and `@doc`, full round by count.

## Round 4 (full)

- Simplify: one judgement (the delta rule in three places), skipped: the comment is next to its clause.
- Standards: 2 judgement (the table row said "text or thinking" delta; an `agent_end` with `error` and no `error` field showed a normal end).
- Spec: 1 (the same `agent_end` case).
- Failure path: 1 (the `@doc` said only `seq` moves for an event of an unknown type; there `seq` does not move).

Fixed: "a delta"; the `agent_end` fallback clause excludes `:error`, so a missing `error` field crashes, with a test; the `@doc` states the two `seq` rules. Fix: 9 code lines in one file, no new function: reduced round.

## Round 5 (reduced)

- Spec: 1 doc wording (the bounds line said each ignored event moves `seq`), 1 minor (the table row holds for a well-formed delta). Fixed in the feature doc only.
- Failure path: 0 findings. Real sessions that fail or abort fold their `agent_end`; Core sends `error` with every `:error` stop.

The last fix is Markdown only, so there is no rerun.
