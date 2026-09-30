# Review: #265, remove the per-turn external provider mode

Scope: `git diff origin/master` on `ticket/265-remove-external-mode`. A provider has a local turn (`stream/3`) or is connected (it exports `harness_init/3`). `Helyx.Provider.turn/1` decides by that export alone. The `turn/0` callback, `{:bad_provider_turn, id}`, `Hands.stream/4`, the steer that aborted an external turn, and the `{:error, :connected}` stubs of Claude Code and Codex are gone. `stream/3` is an optional callback. The ADR 0002 and ADR 0007 amendment records the decision and the risk: a harness with no persistent-process mode would need the per-turn path again.

## Checked names

Every item that the ticket names exists on `origin/master` (line numbers from `5956944` had moved): the external steer clause, `external?` and `start_stream(:external, …)` in `server.ex`, the `turn_mode` branches, `Hands.stream/4`, the `turn/0` try/catch in `provider.ex`, and the two stubs in each harness provider. `{:stream_end, turn_id, terminal}` stays: the harness loop sends the terminal of a connected turn with it. `Stream.check/2` keeps its flag, renamed `connected?`: the harness loop passes `true`.

## Tests

- Deleted, because they covered only the removed path: the `Hands.stream/4` tests (`hands_test.exs`, "a harness stream (#10)"), the `bad_provider_turn` tests and their fakes (`BadTurn`, `RaisingTurn`, the TUI `BadTurn`), the external row of the #227 context check (the connected check is in `harness_test.exs`, "failures"), and the `bad_provider_turn` error texts.
- Moved to connected fakes: `Helyx.Test.Harness` answers `{:turn, …}` with the events of its model, so the session tests of harness events, results, ids, and the capped crash reason run on a connected turn. `Helyx.Test.Gated.External` became `Gated.Connected`: it stops at the gate in `harness_info/2`, after the events before the gate reached the session, so the snapshot tests keep their order.
- The stream tests of connected events call `Stream.check/2` with `true`; a new session test sends `rejected_tool_call` through the harness process from start to end.
- The TUI test of a stray `:DOWN` makes the monitor itself; no provider callback runs in the caller of `/model` any more.

## Simplify

- Reuse: none.
- Efficiency: none.
- Simplification: comment reflow in `stream.ex` and `turn.ex`, one `{:noreply, …}` in `Hands.handle_cast({:run, …})`, one comment paragraph in `end_turn/2`, "harness result" in `message.ex`. Applied.
- Altitude: a provider with neither `stream/3` nor `harness_init/3` started and failed each turn with an `UndefinedFunctionError`. Applied: Core start refuses it with `{:invalid_provider, plugin}` (`Helyx.Core.Plugins.provider_ids/1`), with a test.

## Round 1 (full)

Bounds sensor: `bounds sensor: 9 candidate functions, 1 flagged, 0 without an answer`, `lib/helyx/session/stream.ex:116 SIZE defp consume(stream, session, turn_id)`. The diff only drops an argument there; the session queue check bounds each send as on master.

| Axis | Finding | Resolution |
|---|---|---|
| Standards | `provider.ex` moduledoc: the `harness_session` item ran into the next sentence | fixed |
| Standards | no feature doc for #265 | kept: a removal; the ADR amendment carries the decision |
| Standards | `check/2` takes a boolean, not `turn_mode` (judgement call) | kept: the flag is older than this ticket |
| Standards | `turn?(plugin) && checked_id(plugin)` mixes a boolean and a tuple (judgement call) | fixed: an `if` with a `:no_turn` value |
| Standards | the connected fakes repeat the `:ok` fallback; two long doc lines; "Besides … but" wording | the wording and the lines fixed; the fakes kept |
| Spec | `coding-agent.md` still states the 2,000 ms stream grace and a worst abort of 22,000 ms | fixed: the grace went with the mode, the worst abort is 20,000 ms |
| Spec | the rejected-call test lost its path through the turn | fixed: a session test on the connected fake |
| Spec | ADR 0006 and `session-not-found.md` kept history in the contract text | fixed |
| Spec | the ADR 0007 amendment names ADR 0007 | fixed |
| Failure path | none reproduced; an old plugin with `turn/0` returning `:external` and `stream/3` now starts as local, and its first harness event fails the turn, the session lives | accepted: no bundled or known plugin has it (the ticket) |
| Codex | approve, no findings | none |

No round reproduced a defect, so the loop ends after round 1. The code change after the round is a judgement fix of a few lines: the turn check in `provider_ids/1` moved into the helper `checked/1`, with an `if`, because precommit Credo refused the nesting depth.
