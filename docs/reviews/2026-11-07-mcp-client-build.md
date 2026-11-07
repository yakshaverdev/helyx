# Review: MCP client build (#492)

The build of `docs/features/mcp-client.md`, one `/ship` per slice of its "Slice order".

## Slice 1: tool name rule

Invariant: `Helyx.Tool.specs/2` accepts a tool name only when it is 1 to 52 bytes, each an ASCII letter, a digit, `_`, or `-`; any other name gives `{:bad_tool_spec, module}` before a session creates any file or process, and every bundled tool name passes.

Base `610a8d41`. Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

### Round 1 (full)

- Simplify: moved `@name_pattern` next to `name?/1`; removed a test that repeated the `"a\n"` row.
- Codex: approve, no finding (983 spec probes and 84 session entry probes).
- Failure path: no defect. Probes through `Session.start/2` and `resume/2`: 53 bytes, `"a\n"`, `"\na"`, a NUL, invalid UTF-8, a list, a bitstring, a space, `"é"` are all rejected with no file and no process; 52 bytes starts; a resume with a bad name leaves the file unchanged; a 100 MB name is rejected in 94 µs.
- Spec: no missing or wrong requirement. The bundled names test lives in `plugins/bundled` because the root project cannot load the bundled plugins. Guarantee table of the `@doc` of `specs/2`: every guarantee has a test but "a raise while a spec is built is not contained", which predates this change.
- Standards: one hard finding and three judgement calls.

| # | Finding | Resolution |
| - | ------- | ---------- |
| 1 | The `@doc` wrote the rule as `^...$`, which matches a trailing newline; the code uses `\A...\z` | the `@doc` and the test header state the rule in words |
| 2 | The code comment said every provider takes 64 bytes; decision 8 says 64 is the smallest known limit | comment fixed |
| 3 | `names_test.exs` mirrors no `lib/` module | renamed `bundled_names_test.exs`, `Helyx.Tool.BundledNamesTest`; later slices add their tools to its list |
| 4 | `boundary_test.exs` rows overlap the new file | kept: they test the session boundary, the new file tests `specs/2` |
| 5 | (failure path, out of axis) `docs/features/coding-agent.md` bounds row still said "the name non-empty" | row updated |

No round reproduced a defect, so the loop ended after round 1.

## Slice 2: tool sources in Core

Invariant: a tool source runs in one source process per session (none with `:tools`), as a Task of the hands that ends with its hands and with `:shutdown` when `source/1` returns; its `announce/1` and `put_tools/2` change the session's registry entry by entry within the bounds of the doc, and the hands get each new tool map before any context holds it; a source tool never runs on a source that ended; `launch/1` starts at most 16 server Tasks per source, each linked to its source, and the source hears `:released` only after the hands released the Task's handles.

Base `d4a4a9c0` (slice 1 after a rebase on master). Bounds sensor:

```
bounds sensor: 17 candidate functions, 3 flagged, 0 without an answer
  lib/helyx/interfaces/tool.ex:237  WAIT  def unhold(handles) when is_list(handles) do
  lib/helyx/interfaces/tool.ex:334  WAIT  def started(text) when is_binary(text) do
  lib/helyx/interfaces/tool.ex:386  WAIT  defp source_call(request) do
```

The three flags are calls to the hands or the session with no deadline; the failure-path agent read them and found no wait loop. `source_call/1` waits on the session, which answers it at once.

### Round 1 (full)

Simplify: moved the derived tool values into `ToolRegistry` (Credo's struct field limit on `Server.State`), split `serve/2` out of `launch/5` (nesting), one `ToolRegistry.modules/1`, dead code removed, `Server.Sources.down/2` takes the record that every end has.

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | Codex, spec, failure path | The source process traps exits, so a kill of the hands (as `Stop` does past its deadline) left it running with the hands' exit as a message | reproduced (all three) | a guard process monitors the source and the hands and kills the source when the hands end. Test: "a kill of the hands ends the source, which traps exits" |
| 2 | failure path | The hands dropped the source pid at its end before the session sent the new tool map, so a call in that window ran with `context().source == nil` | reproduced | the hands drop the source's tools from their own map at its end. Test: "a call that the hands take after the end of its source is unknown" |
| 3 | spec | The 1,024 cap counted entries that the checks then rejected | reproduced | the cap counts the kept entries. Test: "1,024 source tools pass, and the cap counts only the kept entries" |
| 4 | standards | The trimmed hands moduledoc said the log gets the term of a bad return; it gets its kind | read | fixed |
| 5 | standards | The `spawn_task/5` comment listed the old ids only | read | fixed |
| 6 | standards | `docs/agents/review-checklist.md` said Core checks no required callback | read | the line names the Tool plugin check |
| 7 | standards | `Calls` matched the source calls by `elem/2` | read | two clauses that match the whole tuple |
| 8 | standards | `Hands.State.sources` and `Server.State.sources` hold opposite maps under one name; the `announced` comment said "in announce order" | read | the hands field is `source_pids`; comment fixed |
| 9 | spec, standards | Guarantees with no test: `{:error, text}` and `:starting` remove the tools, a non-list or non-UTF-8 announce, a plugin with no `run/2`, a source's `check/0`, `context().source` nil for a fixed tool, a resume, an abort, the concurrent flag, a launch of a source that ended; limits with no test at the limit: parameters at 16,384 bytes, a group name of 64 bytes, 64 groups, 1,023 entries, the 2,000-byte notice | read | a test each |
| 10 | spec | The test of a late `{:ok, pid}` kills the Task by hand: the timers and the call routing are the plugin's | judgement | kept: Core's part is that the launch returns at once and that a killed server Task gets its release; the MCP slices test the plugin's timers |
| 11 | standards | Two parameter rules: `Helyx.Tool.parameters?/1` for fixed tools and the registry's for entries | judgement | kept: the doc gives source entries their own bound (a JSON object schema of 16,384 bytes) |

### Round 2 (reduced: spec and failure path)

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | spec, failure path | The drop of round 1, finding 2, was undone: a tool map that the session sent before it heard of the source's end (its next `put_tools/2` of another source, or a put of the source that waited in the session's queue when it died) put the tools of the ended source back, and a call ran with `context().source == nil` | reproduced (two paths, twice each) | second finding on one mechanism, so the mechanism changed: the hands no longer drop and store; `Hands.Sources.lookup/2` derives at each call that a source tool counts only while its source is in the hands' `source_pids`, and `names/1` does the same for `context().tools`. Test: "a tool map that names a source that ended runs none of its tools"; with the check switched off, it and the round 1 test fail with "ran a__echo from nil" |
| 2 | spec | An exit signal other than the end of the hands (a `:shutdown` of the Task supervisor at a Core stop) reaches the trapping source as a message | read | the `Helyx.Tool` moduledoc states the contract: the source ends at an `:EXIT` of a pid that is no server Task of its own; Core kills it when its hands end. A Core stop kills it at the Task supervisor's shutdown limit in any case |
| 3 | spec | No test that each announced group starts as `:starting`, that `info` holds the cwd, of one notice for each of two groups at a source's end, of a 52-byte and a multibyte source entry name, of the cut of a kept error text | read | a test or an assertion each |
| 4 | spec | The Core check also requires `run/2`, and all three spec callbacks of a fixed tool | judgement | kept: the doc says "a fixed tool exports `name/0`, `description/0`, `parameters/0`, and `run/2`" and "A tool source exports `source/1` and `run/2`" |

### Round 3 (full, by the two-findings rule: simplify, Codex, spec, failure path)

Simplify: moved a comment to the code it describes, one comprehension in `others/2`, one observer helper in the test.

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | failure path | Two sources: A announces 64 groups, B announces `["z"]` and gets `:ok`; B's `put_tools("z", :starting)` exits B with `{:bad_source_call, :put_tools}`, which takes its server Tasks. `announce/1` does not tell a source which groups the cap kept, so a correct second source cannot know its room | reproduced | **open.** The code does what the doc decides ("`put_tools/2` of a group that `announce/1` did not keep exits the source"), and the doc does not decide how a source learns what it kept. A fix changes the return shape of `announce/1` (for example `{:ok, kept}`), so it is no small fix. Unreachable with the bundled plugins: the MCP source is the only one, with at most 16 servers |
| 2 | Codex | `announce/3` sorts the whole list and `left_out/1` joins every left-out name before the 2,000-byte cut: an announce of a very large valid list allocates far past the notice bound | read (an inference of Codex, confirmed in the code) | **open.** Fix for the next round: join at most the names that fit in 2,000 bytes (667 at the least size) and count the rest. It is a small fix, but the small-fix round applies only when it is the one defect of round 3 |
| 3 | spec | The doc's `launch(fun)` bullet says "an exit signal from any other process, the hands for example, ends it"; Core kills the source only at the end of its hands, and the `Helyx.Tool` moduledoc gives every other exit signal to the plugin's contract. A probe: `Process.exit(src, :shutdown)` from an unrelated process leaves the test source running | reproduced | **open: doc and code disagree.** Core cannot end a trapping process on an exit signal that plugin code does not read. A design that closes it: a guard per server Task that kills it at the end of its source, in place of the link, so the source need not trap exits. That changes the mechanism that the doc decides (the link and the trap), so it is for the owner |
| 4 | failure path | A source tool's `run/2` ran with the pid of a source that the hands already knew had ended: the lookup is at the spawn of the call Task, and a `before_tool` hook held the call past the source's end | reproduced | not a defect of a written rule: the doc gives `context().source` as "the pid of the source process of the called tool's plugin", and a source can end during any call, so `run/2` fails on its own call to the source. The invariant of this slice is restated below. Open as a note for slice 10: the MCP plugin's `run/2` must turn a dead source into an error result |
| 5 | spec | Guarantees with no test: the cut of a kept `{:error, text}` to 2,000 bytes (a probe shows it cut), a source with no `run/2` and a source that also exports `description/0` refused (a probe shows both refused), the 64-group cap across two sources (a probe shows it right) | read | open: tests for the next round of slice 2 |

The invariant, restated after round 3: a source process runs per session without `:tools` and never outlives its hands; a source tool's call starts only while the hands know that its source runs, and its context names that source; the registry stays within 64 groups and 1,024 kept source entries, each entry checked alone; the hands get each new tool map before any context holds it; `launch/1` starts at most 16 server Tasks per source, linked to it, and the source hears `:released` only after the hands released the Task's handles.

The loop ended at three rounds with findings 1 and 2 reproduced, and neither fix meets the conditions of the small-fix round together. The slice also passed its 45 minutes. So the code as round 3 reviewed it is committed, and the slice is reported open; slices 3 to 10 are not built.

After round 3, the first precommit failed on Dialyzer only (`lib/helyx/session/hands/sources.ex:40:50:no_return`: the body of the source process never returns, because `run/3` always exits). The body moved to `body/3` with `@spec ... :: (-> no_return())` and `@dialyzer {:nowarn_function, body: 3}`, the pattern of `Helyx.Session.ProviderProcess.run/1`. No behaviour changed and the slice tests pass, but this move had no review round: precommit is its only gate.

### The open items of slice 2, decided (orchestrator, 2026-11-07)

1. `announce/1` returns `{:ok, kept}`, sorted; the doc, `Helyx.Tool`, and the tests follow (two sources, the cap across them).
2. The left-out notice names only the names that fit whole in its 2,000 bytes and counts all.
3. The link-and-trap design stays; the doc follows the code: Core ends a source when its hands end; any other exit signal but a kill is a message, and the source loop ends at an `{:EXIT, pid, reason}` from a process that is not one of its server Tasks. A contract of a tool source, checked in slice 10.
4. Tests: a kept error text cut to 2,000 bytes; Core refuses a source with no `run/2` and a source that exports `description/0`; the 64-group cap across two sources.
5. The note for slice 10 stays.

Base `e82013cb`. Bounds sensor: `bounds sensor: 4 candidate functions, 1 flagged, 0 without an answer` with `lib/helyx/interfaces/tool.ex:389  WAIT  defp source_call(request) do` (the call to the session, answered at once).

#### Round 1 (reduced: spec and failure path)

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | spec, failure path | `fitting/3` added a name while any room was left, even one that did not fit; the cut then left a part of it in the notice, even the whole name of another group, a kept one too | reproduced | a name goes in only when it fits whole with its separator, and the list stops there. Tests "a long left-out list ...", "a left-out name that does not fit whole is not in the notice"; both fail on the old guard |
| 2 | spec | The kept error text test could not fail on its UTF-8 part | read | the text starts with an odd byte, so the cut falls in a character |
| 3 | spec | No test that another exit signal reaches the source as a message | read | test added |
| 4 | spec | The `announce/1` doc did not say that `kept` is sorted | read | it does |

#### Round 2 (reduced). The failure-path agent of the first try ended at the usage limit of the model account and was rerun.

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | failure path | The notice charged a separator to its first name, so a name that ends it at 1,999 or 2,000 bytes was left out | reproduced | the room starts 2 bytes higher. Test "a left-out name that ends the notice at exactly 2,000 bytes is in it" |
| 2 | spec | "past 64 groups the first by name order stay": across sources the room fills in the order of the announces, and by name within one | reproduced (a probe) | the texts say so |
| 3 | spec | "any other exit signal reaches the source as a message": a kill does not | read | "but a kill" |
| 4 | spec | A server Task's `:EXIT` and the hands' `{ref, {:ok, pid}}` have no order, so a source can see the exit of a server Task that it has not learned | read (200 probes kept the safe order, which nothing guarantees) | the doc states the rule for a source: while a launch is open, it takes the hands' answers first; slice 10 checks it |
| 5 | failure path | A group name with `", "` reads as two names in the notice | reproduced | kept, a judgement: the notice is text for a person, and its count is right; a group name is plugin input of the MCP plugin, whose server names are `^[a-z0-9][a-z0-9-]{0,15}$` |

#### Round 3 (reduced)

No reproduced defect: the failure-path agent matched the notice byte for byte with a reference at 1,999 to 2,002 bytes, multibyte, and 40 random lists. Spec findings, fixed as wording: the slice 10 list lacked the rule of the open launches; the Core check sentence of the doc named only `name/0` and `source/1`; the `announce/1` doc said "with their count" for the count of all; a `refute` in a test could not fail. Kept: no test of the guard for hands that crash or stop normally (the guard acts on any `:DOWN`; a kill is the case that skips `terminate/2`). The loop ended.
