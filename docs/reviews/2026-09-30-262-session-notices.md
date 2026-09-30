# Review: #262, a notice when abort cleanup or a session-file write fails

Scope: `git diff origin/master` on `ticket/262-session-failure-notices`. The session emits one `:notice` event, with a fixed text, when the hands answer an abort cancel request with an error (no turn id, the abort still replies `:ok`), and when a write through `persist/2` raises `File.Error` (the append of a message, a `model_change`, or a `harness_session`). The reason goes to the log only.

## Checked names

`server.ex` `with {:error, reason} <- result, do: Logger.warning(...)` in the hands answer clause, `persist/2` with its `File.Error` rescue, `do_emit/4` with a nil turn id, and `Session.abort/1` at `:infinity`: all exist as the ticket states.

## Simplify

- Simplification: two comment paragraphs in the `persist/2` rescue said the same thing. Merged.
- Simplification: `cleanup_notice/2` has an `:ok` clause that only returns the state. Kept: clauses over a conditional (AGENTS.md).
- Reuse: a `turn_id(state)` helper for `state.turn && state.turn.id`. Skipped: one call site.
- Efficiency: none.
- Altitude: a shared log-and-notice helper for the two sites. Skipped: two sites, different texts and turn ids.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| Axis | Finding | Resolution |
|---|---|---|
| Standards | the feature doc has no line for the new notices | fixed: `docs/features/coding-agent.md`, the `model_change` paragraph, the write-failure list item, and the abort wait row |
| Standards | `persist/2` now emits, and its name does not say so (judgement call) | kept: the rescue comment states it |
| Standards | the notice goes out before the event of the message whose write failed (judgement call) | kept: a notice is not in the transcript |
| Standards | no devlog (judgement call) | kept: this record holds the work |
| Spec | the `set_model` write path has no notice assertion | fixed: the test "a switch still works when the file cannot be written" asserts the notice with a nil turn id |
| Spec | the abort test does not prove the hands answered with an error | kept: the notice goes out only on `{:error, _}`, and the stuck release always ends unconfirmed |
| Spec | the notice drops the list of handles | kept: the list has no cap; the notice bound is 2,000 bytes |
| Failure path | at a resume, the `aborted` results of open calls are written in `init/1`; a write that fails there sends its notice before any client can subscribe, so no client gets it (reproduced: `chmod 0444` of the file before `Session.resume/2`) | accepted hole, stated in the `Session.start/2` doc and the feature doc. ADR 0006: a late client does not see notices; a fix needs a snapshot field, which is a contract change |
| Codex | approve, no findings | none |

The one reproduced finding became a documented hole, with no code change. The other fixes are one test assertion and docs, so no rerun round.
