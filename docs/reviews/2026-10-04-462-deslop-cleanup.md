# Review: cleanup from the deslop review (#462)

Date: 2026-10-04. Base: `origin/master` 5edc951.

Invariant: the change is cleanup with no behaviour change, except two. First, every command line given to `Mix.Tasks.Helyx.Graph.run/1` that the argument parse cannot read ends in a `Mix.Error` with the usage, not in a raw exception. Second, `Helyx.Provider.OpenAI.Events.events/1` reads only `reasoning_content` as thinking, and no longer reads `reasoning`. Accepted hole: an unknown UTF-8 switch still gives the text of `OptionParser.ParseError`, as before.

## Ticket items

- Item 5: the `HarnessIO.stop(%{port: nil})` clause is deleted, because it cannot run. `stop/1` has one caller, `ClaudeCode.relaunch/2`. That function runs only from `read/2` with `terminal: :lost, closing: nil`. `port: nil` is set only in the `{:closed, from}` branch of `info/2`, and `HarnessIO.exited/2` gives that branch only when `closing` is not nil. `closing` is set only by `HarnessIO.close/2`, to a `from` that `ProviderRequest.ask/3` makes with `make_ref/0`. No code sets it back to nil on a live state. A failed launch gives `terminal: {:error, _}` and a stop, never `:lost`. The failure-path agent, the spec agent and Codex each checked the proof.
- Item 10: the `_seen =` binding at `helyx.graph.ex:177` is not unused. Without it, Credo strict reports an unused return of `Enum.reduce/3`, which failed the first precommit run. The binding stays as on master. The other two parts of item 10 are done.
- Item 12 (optional): only the three-line match at `codex.ex:126` was collapsed. A rewrite of `watchdog.ex` `parse_marker/2` was tried and reverted in simplify, because it tested 0 twice. The others are not shorter as clauses.
- Item 14: neither `ponytail:` marker had a ticket. Both became plain comments that state the ceiling, and no ticket was filed. The row in `docs/features/coding-agent.md` that cited the bash marker now names the module only.
- Item 17: the perl risk note moved to the ownership section of `docs/features/coding-agent.md`. No feature doc is named for bash or the watchdog, and this section describes the perl watchdog.
- Item 2: `docs/devlogs/2026-09-17-openai-provider.md` line 8 says that `reasoning` deltas become thinking. That line describes the first code, not an observed endpoint, so it is not evidence. The test that fed `reasoning` now checks that it gives no event.

## Bounds sensor

```text
round 1: bounds sensor: 9 candidate functions, 0 flagged, 0 without an answer
round 2: bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

## Simplify

- Simplification: `parse_marker/2` checked 0 twice after the item 12 rewrite. Fixed: the rewrite was reverted.
- Simplification and standards: the nested `try` in `helyx.graph` `turn/0` could be a helper function. Skipped: it would add a function. The order (the trace stops, the names are read, Core stops) is clear in place.
- Reuse and altitude: the two Mix tasks check the command line in two copies. Skipped: the ticket asks for the same fix in place. A shared helper can come with a third task.
- Reuse: the codex reset writes out the struct defaults again. Skipped: the ticket asks for the plain struct update.
- Efficiency: none.

## Round 1 (full)

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | `run([<<"-a", 255>>])` raises `UnicodeConversionError` | Reproduced. Fixed with the UTF-8 check of `helyx.ex` before the parse. The test now has this argument list and `<<"-", 200, 200>>`. |
| Standards | `Helyx.Session.aborted_result/0` is called from inner session modules | Judgement, kept: clients match the value, and `Helyx.Session` is the API that clients read. The altitude agent agreed. |
| Standards | The nested `try` in `turn/0` | Judgement, skipped (see Simplify). |
| Standards | Record the item 5 proof | Done in this record. |
| Standards | The OpenAI test name has two claims | Judgement, kept: it was one test before. |
| Spec | Item 1 does not have the UTF-8 check of `helyx.ex` | The same defect as the first standards row. Fixed. |
| Spec | `coding-agent.md` row cites the `ponytail:` marker | Fixed: the row names the module. |
| Spec | Item 17 doc is not a bash or watchdog doc | Judgement, kept (see Ticket items). |
| Failure path | None reproduced | Not reached: the `:real_claude` and `:slow` tests, and a timing probe of the relaunch window. The item 5 proof rests on the match in `port_message/3`. |
| Codex adversarial | Approve, no material findings | None. Its 515 switch probes did not include `-a<255>`. |

## Round 2 (reduced)

Fix diff: 1 code file, 7 lines added and 1 removed, no new function, no change of arity or return shape. Round type: reduced (spec and failure-path).

| Axis | Finding | Resolution |
| --- | --- | --- |
| Spec | `run(["calls", <300 characters>])` raises `SystemLimitError` from `Module.concat/1` | Reproduced. This defect is older than the change, and it is outside item 1: it comes from the module arguments of `calls`, not from the parse. It is not fixed here and needs a new ticket. |
| Spec | The `ParseError` text has no usage | Older behaviour, the accepted hole of the invariant. |
| Failure path | The same `SystemLimitError` (249 ASCII characters, 300 copies of `é`) | The same older defect. Not reached: the 248-character boundary, because it runs real `calls` work. |
| Failure path | The new comment names a case that the check now stops first | Wording fixed. |

The round found no defect in the change, so the loop ends after round 2.

## Precommit

The first run failed on Credo (the `_seen =` binding, see Ticket items). The second run failed one root test, `end_signal_test.exs:108` (`set_model/2` after Core stopped: `Registry.meta/2` in `Helyx.Core.provider_ids/1` gave `:error`). The change does not touch that path. The test passed 10 of 10 runs alone, and the third run of precommit, on the same tree, passed. The flaky test has no ticket.
