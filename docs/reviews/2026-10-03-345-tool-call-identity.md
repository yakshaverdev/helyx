# Review: tool-call identity in the OpenAI parser and Core (#345)

Date: 2026-10-03. Base: `3bf9aaa` (the branch point from `origin/master`; `origin/master` moved during the review, so the briefs of round 2 name `3bf9aaa`). Scope: `plugins/bundled/lib/helyx/provider/openai/events.ex`, `lib/helyx/session/stream.ex`, their tests, `test/support/interfaces.ex`, and the rows of `docs/features/coding-agent.md` and `docs/features/rejected-tool-call.md` on tool calls.

Codex was unavailable (usage limit until 2026-10-04 01:42). In each round, a fresh general-purpose agent ran the same adversarial review, read-only, with the same invariant sentence, and counts as the Codex reviewer.

## Invariant

In `Helyx.Provider.OpenAI.Events.events/1`, each id names one call and each call has one id: a delta that names a second id for an index, an id that another index holds, or a stream that mixes deltas with and without an index, makes its chunk malformed, and the stream ends with one `{:error, {:bad_chunk, payload}}`. Without an index, a delta extends the last call when it has no id, an empty id, or the id of that call, and starts a call for a new id; the id of an earlier call conflicts. `Helyx.Session.Stream.check/1` rejects a `:tool_call` or a `:tool_request` with an empty id as a malformed event, so the turn fails and the session lives.

Accepted: the resume path (`Helyx.Session.File` codec) does not check for an empty id. A first delta with no index and no id still makes a call with an empty id, which Core rejects. A bad-JSON call with an empty id now reaches Core as a `rejected_tool_call` and fails the turn with `bad_stream_event`; the provider error `{:bad_tool_arguments, name}` is gone.

## Round 1 (full)

Bounds sensor:

```text
bounds sensor: 20 candidate functions, 4 flagged, 0 without an answer
  lib/helyx/session/provider_process.ex:94  WAIT  defp loop(proc) do
  plugins/bundled/lib/helyx/provider/openai/events.ex:87  SIZE  defp data(payload, acc) do
  plugins/bundled/lib/helyx/provider/openai/events.ex:158  SIZE  defp chunk_events(chunk, acc) do
  plugins/bundled/lib/helyx/provider/openai/events.ex:218  SIZE  defp put_call_delta(delta, index, acc) do
```

The `provider_process.ex` flag came from the moved `origin/master`, not from this change.

Simplify (4 agents): the `with` step in `data/2` matches `:conflict` by name, not by a failed tuple match. The OpenAI clause that failed a bad-JSON call with no id (`{:bad_tool_arguments, name}`) is removed, because Core now rejects every empty id. Not changed: the reduce as a `with` step (same size), and the comment at the Core guard (the bound is at that line).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 2 docs | 0 | `rejected-tool-call.md` kept the old `bad_tool_arguments` sentence, bounds row, and test line. Replaced. |
| Spec | 1 wording | 0 | The bounds row now says the term holds `%{}` for bad JSON and the decoded arguments otherwise. |
| Failure path | 1 defect, 1 dead branch | 1 | Without an index, a repeated id started a second call with the same id, and an empty id started a call with an empty id, which now fails the turn. The error branch in `flush/1` was dead after the removal above. Fixed (below). |
| Codex adversarial (agent) | 2 defects, 1 risk | 2 | The same two defects. Risk: two indexes with one id give two calls with one id, and the next request has two results for that id. Fixed (below). |

Fix: an `ids` map (id to index) in the accumulator. Without an index, a delta goes to the index of its id, a new id starts a call, and no id or an empty id extends the last call. With an index, an id that another index holds conflicts. The flat entry charge covers the one `ids` entry of a call. The dead branch in `flush/1` is removed. Fix diff: 53 lines in one code file, a new accumulator field, and a changed arity of `put_call_delta`, so round 2 is full.

## Round 2 (full)

Bounds sensor (base `3bf9aaa`):

```text
bounds sensor: 10 candidate functions, 3 flagged, 0 without an answer
  plugins/bundled/lib/helyx/provider/openai/events.ex:88  SIZE  defp data(payload, acc) do
  plugins/bundled/lib/helyx/provider/openai/events.ex:159  SIZE  defp chunk_events(chunk, acc) do
  plugins/bundled/lib/helyx/provider/openai/events.ex:223  SIZE  defp put_call_delta(delta, id, index, acc) do
```

Simplify (2 agents, two angles each): `known` reads `get_in/2` instead of a dummy map. A repeated id is not copied, charged, or put in `ids` again, so a gateway that repeats the id on every fragment does not use the budget for bytes it does not keep. Not changed: the `ids` check also runs on deltas without an index, where it cannot fail in round 2 (one lookup).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards and spec (1 agent) | 1 | 1 | Same defect as below. |
| Failure path | 1 | 1 | Without an index, `c1`, `c2`, `c1`, then a fragment with no id: the fragment went to `c2`, the call with the highest index, not to `c1`, which the delta before it named. |
| Codex adversarial (agent) | 1 | 1 | The same defect. The round 1 reproductions hold. |

This is the second finding on the identity rule without an index, so the fix removes the mechanism that made it: a delta without an index can no longer go back to an earlier call by its id. Such an id now conflicts like an id that another index holds, so "the last call" is always the call with the highest index. Fix diff: 20 lines in one code file, and the two-findings rule applies, so round 3 is full.

## Round 3 (full)

Bounds sensor (base `3bf9aaa`):

```text
bounds sensor: 9 candidate functions, 3 flagged, 0 without an answer
  plugins/bundled/lib/helyx/provider/openai/events.ex:88  SIZE  defp data(payload, acc) do
  plugins/bundled/lib/helyx/provider/openai/events.ex:159  SIZE  defp chunk_events(chunk, acc) do
  plugins/bundled/lib/helyx/provider/openai/events.ex:226  SIZE  defp put_call_delta(delta, id, index, acc) do
```

Simplify (1 agent, four angles): the test `known in [nil, ""]` is bound once as `open?`. Not changed: the "keep the first id" rule in `put_call_delta/4` stays, although `new_id` already makes it hold (a plain `if` is clearer than `call.id <> id`).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards and spec (1 agent) | 0 | 0 | The conflict check is in `add_call_delta/2`, not in the stateless `valid_chunk?/1`, because a conflict is between deltas; the error is the same `bad_chunk` as at the shape gate. |
| Failure path | 0 | 0 | The rounds 1 and 2 reproductions, one-chunk and cross-chunk forms, indexed late ids, and all mixed orders end with one `bad_chunk` or give one call. |
| Codex adversarial (agent) | 0 | 0 | Same cases; the budget charges each `ids` entry through the flat entry charge and the one id copy. |

Round 3 reproduced no defect, so the loop ends.

## Open, not caused by this diff

- `Helyx.Session.File` does not reject a tool call with an empty id on resume. A file written after this change holds none.
- A harness provider (Claude Code, Codex) that sends a `tool_request` with an empty id now ends its provider process with `bad_stream_event`, as for any malformed event; before, the tool ran. No harness sends an empty id in the tests.
- Not reached by the probes: ids that differ only in Unicode normal form (compared by bytes), and an end-to-end turn through `Helyx.Provider.OpenAI` with an empty-id call (the Core path is covered by the `empty_id` session test).

## Precommit

The first run failed on Credo only: `put_call_delta/4` had a cyclomatic complexity of 10. The `ids` update moved, unchanged, into the two-clause helper `put_id/3`. This is a move of one `if` with no change of behaviour, after the last review round; the round limit allows no fourth round. The second run passed.
