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

## Slice 3: deferred tools and activation

Invariant: a deferred source entry reaches a provider context only while its name is in the session's activated list; `activate/1` and the cap after each put keep that list in drop order within 32 names and 65,536 bytes of spec JSON, older calls first and within one call the lowest ranked first; each change of the list writes one `tools_change` entry and emits one `:tools_change` event, with the turn of a call that runs in it, else nil; a resume restores the list in order; `deferred/2` answers at once when the version moved or it is nil, else at the next change or its bound, and a dead waiter never blocks a live one.

Base `fc06b7ac` (slice 2 follow-up, rebased on master). Bounds sensor:

```
bounds sensor: 8 candidate functions, 2 flagged, 0 without an answer
  lib/helyx/interfaces/tool.ex:399  WAIT  def deferred(version, wait_ms)
  lib/helyx/interfaces/tool.ex:414  WAIT  def activate(names) do
```

Decided inside the doc's design (no new concept), stated in the doc: the bounds of `activate/1`'s input (1,024 strings), of a `tools_change` entry on read (32 distinct names of the name rule), and of `wait_ms` (taken as at most 30,000).

### Round 1 (full)

Simplify: `capped/2` encodes only the names on the list; `wake/1` builds no view with no waiter; helpers moved to `test/support/source_case.ex`, and `tool_source_test.exs` uses them.

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | failure path, spec, standards | The waiter cap of 8 counted dead waiters (a call aborted while it waited stays until its timer), and live background runs pass 8 too; past the cap a waiting `deferred/2` answered at once, so a search would loop | reproduced (8 aborted waiters; 8 live background runs) | a waiter whose process ended goes before the count; the cap is 32, the live Tasks with a call context (8 calls, 8 hooks, 16 background runs). Test "a waiter whose call ended does not fill the waiters" (33 aborted waiters); it fails with the old code |
| 2 | failure path, spec, standards | `:tools_change` took the current turn's id, so a background run that activated during a later turn got that turn's id | reproduced | the turn id is that of a caller that is a running call or hook of the current turn (the askers of `Asks`), else nil; the doc and the event doc say so. Test "an activation of a background run has no turn", which activates during a later turn; it fails with the old code |
| 3 | standards | A FileLength entry for `lib/helyx/interfaces/tool.ex` breaks the rule of `.credo.exs` that the list only shrinks | read | the entry is gone; the moduledoc and the docs of `hold/1`, `unhold/1`, `context/0`, `ask/1`, `transcript/0`, `background/0`, and `started/1` are shorter, with their guarantees kept, so the file is at 400 |
| 4 | Codex | An activated name stays when its entry leaves or turns direct, so a later deferred entry of that name is active with no new activation | read | rejected: the doc decides that activated names stay while no source registers them ("Names that no source registers yet stay in the list and are sent once their group lists them"), and a tool name of a source is `<server>__<tool>`, so the same name is the same tool of the same server |
| 5 | spec | No test at exactly 65,536 bytes, of the list on disk after the cap drops on a put, of the version at a source's end, of bad `activate/1` lists, of the 30,000 ms clamp | read | a test each |
| 6 | spec | The snapshot field and the event reach the WebSocket wire under protocol 3, before slice 4 | read | kept for one commit: slice 4 puts them in the schema with a new protocol number; the branch merges with both |
| 7 | standards | `waiters` lives in the pure registry struct; `File.Reader` calls `ToolRegistry.max_activated/0`; `SourceCase` is a helper module, not a case template | judgement | kept: the waiters wait on the registry's version, which only the registry holds, and Credo's struct field limit of `Server.State` is reached; the reader takes the one source of the cap; the name follows `Helyx.Test.SessionCase` |
| 8 | standards | Doc rewording in `file.ex` to stay at 400 | judgement | kept: every guarantee of the old text stands |

### Round 2 (reduced: spec and failure path; the failure-path agent of the first try ended at the usage limit of the model account and was rerun)

No reproduced defect. The failure-path agent held both fixes on other paths: 32 helper processes with a copied call context fill the waiters, a 33rd answers at once, and a killed one frees its place; a helper of turn 1 that activates during turn 2 gives a nil turn id; `before_tool` and `after_tool` hooks give the current turn id and one event each; a source's end answers the waiting call. Spec findings, fixed as wording: the shorter `tool.ex` docs had lost that a failed `check/0` stops the start with a clear error, that the release deadline is on the node of the hands, that the `after_tool` hooks of `started/1` can change the status, and that the cap of 8 is of the calls of a turn; the `deferred/2` and `activate/1` docs did not name hooks or the answer at once past 32 waiters; the doc's event line did not name hooks. The loop ended.

## Slice 4: the wire

Invariant: the wire schema of protocol 5 holds the event `tools_change` with `data.activated`, a list of strings, and the snapshot field `activated`, the same list; `Helyx.Transport.WebSocket` speaks 5, carries the SHA-256 of that schema, and answers a `hello` of another protocol with `refused` and `4426`; the strict decoder of the TUI takes the event and requires the field, and ends the connection as a contract break on a value of another shape; the conformance fixtures name protocol 5 and hold the valid and broken cases; every doc that names the current protocol number follows (master's protocol 4 came with #880).

Base `570dbe0c` (slice 3). Bounds sensor:

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

### Round 1 (full)

Simplify: `decode.ex` checks the list in one `activated!/1` for the event and the snapshot, at 400 lines; `activated` follows `asks` in the fold snapshots, as in the schema.

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | Codex | `activated: [7]` raises `FunctionClauseError` in `activated!/1`; check that the connection closes, not only the event or the request | reproduced the path, not a defect: the failure-path agent sent each broken shape (missing, null, a string, `["a", 1]`, `[["a"]]`, an object) through the real `Wire.connect` and `Connection`, and each closed the connection with `{:shutdown, :broken}`; a broken snapshot made `subscribe` give `{:error, :closed}` | none |
| 2 | standards, spec | `docs/features/tui-attach.md` decision 13 said "pages need protocol 5": written when "protocol 4" meant the next number, now the number of this slice, which has no pages | read | "a new protocol number" |
| 3 | standards, spec | `docs/features/hub.md` moved to 5 → 6 in item 4, but decision 6 still gave the `hub.*` ops protocol 5, the Transport line "goes to 4", and the schema heading "(protocol 4)" | read | all three say protocol 6 and point to item 4 of its Replaced mechanism |
| 4 | standards | Item 11 of wire-protocol.md says "drop order", which only mcp-client.md defines | judgement | item 11 says what it means for a client: the first name leaves first, and a client only shows the list |
| 5 | standards, spec | No fold case holds a known `tools_change`, and the object-in-place-of-a-list test leaves out `activated` | read | `folds.json` gets a `tools_change` with a nil turn after `turn_end`: the state moves its `seq` and keeps the rest; the decode test checks `activated` as an object |
| 6 | failure path | The client takes any list of strings, past the 32 names and the name rule of Core | judgement | kept: nothing in the TUI reads the list, and the schema gives a list of strings; a client that shows the names checks them then |

The failure-path agent reproduced no defect: hellos of protocol 4, 6 and 4294967296 get `refused` with 5 and `4426`, `"5"`, `5.0` and null close with `4400`, a Core event and a real snapshot encoded by the server decode equal on the client, and lists of 20,000 names and of names with control or multibyte characters decode. No round reproduced a defect, so the loop ended.

## Slice 5: `tool_search`

Invariant: `tool_search` takes a query of at most 1,024 bytes and a limit from 1 to 10 (5 when missing or null), else an error result; it ranks the deferred entries of the registry by BM25 over the words of the name, the description, and the parameter property names and descriptions, an entry named by a word of the query first; it answers at once with a match, or when no group starts and no source is pending, and else waits for each change within 30,000 ms of its first look, ending at a `deferred/2` answer with the same version; it lists as loaded only the matches that `activate/1` kept and the registry holds, names the others, the groups and sources still starting, and each failed group, each text of a source on one line; an empty query activates nothing and lists the groups with their state and tool count.

Base `248856c8` (slice 4). Bounds sensor:

```
bounds sensor: 12 candidate functions, 0 flagged, 0 without an answer
```

Decided inside the doc's design (no new concept), stated in the doc's "Decided in slice 5": the words and the BM25 parameters, exact names as whitespace words of the query, the end of the wait at a same-version answer, a null limit, the answer layout, the empty query, and a tool count per group in the view of `deferred/2` (`Helyx.Session.ToolRegistry.view/2`).

### Round 1 (full; the standards, spec and failure-path agents of the first try ended at the usage limit of the model account before they started and were rerun)

Simplify: `words/1` splits in one regex pass; an entry keeps only the counts of the query terms and its word count; a look after a change counts only the entries that are new.

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | failure path, Codex | A name that an earlier search activated stays in the activated list when its group empties (the doc keeps such names); a put that empties the group between the look and `activate/1` left the match in the returned list, so the answer listed it as loaded and callable | reproduced (a look over 600 entries at the bounds held the window) | a match is loaded when the returned list holds it and a `deferred(nil, 0)` after the activation shows it registered; the state lines come from that view. Test "a match whose group emptied since an earlier activation is not loaded", which holds the search with `:erlang.suspend_process/1` while the group fills and empties; it fails with the old code |
| 2 | failure path | A group's failure text with line breaks added lines to the answer (a fake `evil__tool:` line and a second last line); U+2028, U+0085, `\v`, and `\f` split a description; a group name can hold a line break too | reproduced | each run of Unicode line breaks (`\R`) in a description, a group name, or a failure text becomes one space. Test "each text of a source is on one line of the answer" |
| 3 | spec, standards | No test of the default limit of 5, of `Tool sources still starting` beside a match, of parameter words at depth, of digits, of the tie by name | read | a test each ("a search loads at most 5 matches with no limit", "a match answers at once and names a source that is still pending", the rank tests) |
| 4 | spec | The doc gave `<n> tools`, the code writes `1 tool` for one; the doc of `deferred/2` did not name the tool count | read | the doc says `1 tool`; the `deferred/2` doc names `state` and the `tools` count, with `tool.ex` at 400 lines |
| 5 | failure path | One look over 1,024 entries at the bounds takes about 4 s of CPU; the 30,000 ms bound counts the waits only | measured, not a defect | the doc's "Words" bullet and the Bounds row state it: a look that starts before the end runs to its end |
| 6 | standards | The comment "at least one word on average" is wrong; `- 1_000` in the slow test has no reason; `left` beside `left_out`; the helper `e/3` | read | the comment says what the code does; the slow test asserts at least 30,000 ms (the start is read before the prompt); `time_left`; `ranked/3` |
| 7 | standards | `Helyx.Test.ToolSource` copies the root `Helyx.Test.Source` and `SourceCase` helpers | judgement | kept: the root support is not compiled in the bundled project, and the root source has release handles that the search tests do not need |
| 8 | standards | The query map and the count tuple could be structs; the ranker could be its own module | judgement | kept: both shapes live inside one 270-line module; `rank/3` stays `@doc false` for the rank tests |
| 9 | spec | The answer at once past 32 waiters has no test | probed by the spec agent: 32 live waiters, the search answered in 1 ms with no match | none: a test needs 32 live callers of another kind |

`read_test.exs` listed every Tool module of the app, and the test sources of the bundled project compile into it in tests: its list keeps the fixed tools, which have `name/0`.

### Round 2 (reduced: spec and failure path)

Both reproductions of round 1 pass. Invariant 2 held on every path: the line breaks LF, CR, CRLF, VT, FF, U+0085, U+2028, and U+2029 become a space, and the labels of pending sources are `inspect/1` output, which escapes them.

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | failure path, spec | A put between `activate/1` and the second look raised the spec bytes of the activated names, the cap after the put dropped a name of the batch, and the answer listed it as loaded: the rule of round 1 took the returned list and the registered names from two moments | reproduced (5 of 5: the session held with `:sys.suspend` between the activation and the put) | the second finding on one mechanism, so the mechanism changes: a match is loaded when one view after the activation holds it in its entries and in its `activated` list, and its line takes the description of that view; the returned list is not read. Test "a match that the cap drops after the activation is not loaded", which queues the activation and the put in the suspended session; it fails with the code of round 1 |
| 2 | spec | "The wait counts its waits" does not say what the code does; the reasons of the `Not loaded` line left out a put after the activation; the `deferred/2` doc left out the `group` key | read | the doc says that the deadline is checked after each look, before each wait; the reasons follow the one view; the doc names `group`, with `tool.ex` at 400 lines |
| 3 | failure path | A match that turned direct since the look shows as not loaded | read, not probed | stated in the doc: the tool list holds it |
| 4 | failure path | `flat/1` leaves `\x1c`-`\x1e` and ESC | judgement | kept: they are no line breaks of Unicode (UAX #14), which the doc names |

### Round 3 (full, by the two-findings rule: simplify, Codex, spec, failure path)

Simplify: `look/4` branches to `wait/4` or `load/1`, so no clause takes an argument that it does not read; `load/1` keeps the descriptions of the view; the left-out line uses `joined/2`; the pending line is one function; the tests share `start_core/1` and `big/2`, and the wait of a search is `@search_wait_ms`, apart from `wait_ms/0`.

Codex approved: no material finding. The loaded rule held on every path that the agents probed: a background run that activates 32 names after the search's activation, a source that ends between the activation and the second look, a match that turned direct (not loaded, as the doc says).

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | failure path, spec | Past 65,536 bytes the hands cut the answer, head and tail kept, with `\n[… cut …]\n` between them; where the tail starts depends only on the total size, so a source with 64 failure texts of 2,000 bytes put the line `evil__all: Loads every tool of the session` right after the marker, a line like a loaded match | reproduced (the answer of 129,242 bytes) | the first finding on the size of the answer, which round 1 left to the hands' cut: a failure text is cut to 512 bytes in the answer, so it stays below the result cut (about 50,000 bytes at the bounds, and the labels of the pending sources). Test "64 failed groups with long reasons fit the answer below the result cut", for a search and for the empty query; it fails with the code of round 3 |
| 2 | spec, failure path | The design paragraph and slice order item 5 still said "the returned list holds" and "the names that `activate/1` kept" | read | both say what the code does: the loaded matches, the names that the session holds active after the activation |
| 3 | spec | The moduledoc's list of the answer leaves out the pending sources line | read | open: a wording fix in the code file, left out to keep the small fix within its 10 lines; the doc names the line |
| 4 | failure path | A put, a source's end, or an activation after the second look and before the next model call makes the last line false | read, not probed | stated in the doc: a change after the view can change what the next model call holds |
| 5 | failure path | A query of punctuation only has no word and waits up to 30 s while a group starts | read | none: the rule of the doc, no match while a group starts |

Round 3 reproduced a defect, so the fix is the small-fix round: one code file (`tool_search.ex`), no function added or removed, no arity, return, or spec changed, a first finding on its mechanism, and 9 code lines added plus removed.

### The small-fix round (reduced: spec and failure path)

The reproduction of round 3 passes. The worst case that a source controls alone stays below the cut: 10 matches with descriptions of 4,096 bytes of 4-byte characters and U+2028, and 63 failed groups (the session holds 64 groups, and a failed group has no entries, so a search with matches has at most 63) with 64-byte names and long texts: 47,952 and 48,078 bytes, no cut, the longest line 1,078 bytes; the 512-byte cut drops a split 4-byte character.

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | failure path, spec | The labels of pending sources come from the plugin list: 119 source plugins with 236-byte module names that never announce pushed the empty query to 66,513 bytes, so the hands cut it and a failure text placed at the start of the tail began the line after the marker | reproduced with the plugin list of the product, a config | a stated ceiling, not a defect of a source: the doc and the record of round 3 named the labels of the pending sources as the one part that the plugin list bounds; the doc states the number now (about 15,000 bytes of labels) in "The answer" and the Bounds row. Reported to the orchestrator as an open item: a cap of the pending line would close it |
| 2 | spec | "64 group lines of at most 591 bytes": starting groups share one line | read | the doc counts 591 bytes for a failed group and 66 for a starting group |
| 3 | spec | The empty query starts each line with a group name, and a group name can hold `: `, so a line can look like a match line | judgement | kept: the empty query lists no matches, and its format is the doc's; MCP group names follow `^[a-z0-9][a-z0-9-]{0,15}$` |
| 4 | spec | No test of the worst case with 10 match lines | probed by both agents (47,952 and 48,078 bytes) | none |

The loop ended: three rounds and the small-fix round.

## Slice 6: harness providers follow the active set

Invariant: at each turn start a harness provider compares the turn's `context.tools` (the exact list of specs, sorted by name by the session) with the tools of its running program; other tools replace the program, Claude Code with a resume of its harness session whose MCP server lists and admits the new tools, Codex with a new program whose `initialize` fits the tools and a fresh thread with the new `dynamicTools`, the replay, and a stored id of their digest, never a resume of a thread of other tools; a first Codex turn with other tools than `init/3` does the same; the same tools and prompt keep the program; a compaction keeps the running program's tools.

Base `ebf617ea` (slice 5, rebased on master `b8cf9d96`; the rebase merged the source clauses of `hands.ex` and `server.ex` with master's approvals). Bounds sensor:

```
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

Decided inside the doc's design (no new concept), stated in decision 10 and in provider-parity.md, "The prompt": the comparison is of the exact list of specs, so a changed schema or description is a change; a first Codex turn with other tools than `init/3` replaces the program. The tests of both providers that started a provider with tools and sent turns with none now send the provider's tools in each turn, as a session does.

### Round 1 (full)

Simplify: `Program.compaction/1` beside `turn/2`, with `ensure/4` private; `thread/3` in Codex takes the prompt and the specs; `replace/3` compares with `===`, as the match of `thread/3`; `answer/1` of the Codex tests in `CodexFake`; agent-self-knowledge.md named the stale `ensure/2`. `claude_code.ex` stays at 507 lines and `codex.ex` at 481.

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | Codex | The changed branch of `ensure/4` calls `replace/2` without `tools`, so the new program keeps the old tools | read: both branches pass `tools: tools`, and the test "a turn with other tools resumes the harness session in a new program that lists them" asserts that program 2's `tools/list` lists the added tool | rejected |
| 2 | failure path, spec | On Codex a tools change after a native compaction starts a fresh thread with the replay of the Helyx transcript, which holds no compaction summary, so the compaction and the history past the replay cut (400,000 bytes) are gone; harness-compaction.md said the history and its summary stay in the program | reproduced with the fakes | follows from decision 10, which the owner accepted (a thread's tools are fixed at `thread/start`): stated as an accepted hole in mcp-client.md and in provider-parity.md, and harness-compaction.md names the exception. Reported to the orchestrator |
| 3 | standards, spec | No test of "a compaction keeps the tools", of a prompt and a tools change together, or of a changed description on Codex | read; probes passed | a test each: `claude_code/compact_test.exs` and `codex/compact_test.exs` (each fails when the compaction passes no tools), "another prompt and other tools together give one new program with both", "a changed description is other tools, and with another prompt one new program has both" |
| 4 | standards | Decision 10 cited `codex/program.ex:96-105` and said "today" | read | it names `init/3` and `open_thread/1` and says "before slice 6" |
| 5 | spec | provider-parity.md "Bounds" and "Ownership", long-lived-harness.md (the relaunch row and Codex "Connect"), and the `codex.ex` moduledoc named only the prompt relaunch | read | each names the tools change; the moduledoc keeps its line count |
| 6 | standards | agent-self-knowledge.md: "only when the system prompt or the tools change" leaves out the Claude relaunch around a compaction | read | it names it |
| 7 | standards | `system`, `commands?`, `tools` travel together in `ensure/4`; `%{system: ...}` in place of `%State{}` in one clause of `thread/3`; `tools_turn/1` beside `tools_run/3`; the provider-parity bullet's `tools` is `tools.specs` on Codex | judgement | the field is named; the rest kept: the bare map keeps `codex.ex` at its count, and the three values are the launch of one program |

The failure-path agent reproduced no defect of the code: a tools change after a lost harness session or with no stored state, a compaction after a tools change, a steer without an answer (`{:error, :restarted}`), tools A, B, A (no resume, the stored id of A), and an error answer to `thread/start` in the new program (the generic failure path). No round reproduced a defect, so the loop ended.

## The rebase on master `77d0751e` (UI blocks, #878)

Master's #878 took wire protocol 5 and grew `lib/helyx/interfaces/tool.ex` and the TUI decoder. The rebase resolved:

- Slice 4 now gives protocol 6 (`@protocol 6` and the SHA-256 of the new schema, the fixtures bumped from master's protocol 5, item 12 of wire-protocol.md's Replaced mechanism, Hub from 6 to 7 in hub.md, the mcp-client.md Wire bullet). Its commit says protocol 6; the slice 4 section above, written for protocol 5, holds for 6.
- The snapshot holds master's `ui_blocks` and `activated`; the `hands.ex`, `server.ex`, `calls.ex`, `tool.ex`, `snapshot.ex`, and `events.ex` conflicts merged both sides.

The merged `tool.ex` had 449 lines and the decoder 406, over the 400 of AGENTS.md, and the `.credo.exs` list only shrinks. A separate commit fits them, through this cycle.

Invariant: no behaviour changes. The bodies of `Helyx.Tool.specs/2`, `check_available/1`, `concurrent/1`, and `name?/1` move into the internal module `Helyx.Session.ToolSpecs`, which owns the checks of the fixed tools at a session start and the name rule; `Helyx.Tool` keeps their docs, specs, and delegations, as `ask/1` delegates to `Helyx.Session.Ask`, so it stays a behaviour and public API (369 lines). The decoder rewraps its comments to the formatter width, with the same text, and writes `activated!/1` on one line (400 lines).

Base `HEAD` (`ca208ebb`, slice 6 rebased). Bounds sensor:

```
bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer
```

### Round 1 (full)

Simplify: each public function of `ToolSpecs` beside its helpers.

Codex approved. The failure-path agent compared HEAD's `tool.ex`, loaded under another name, with the new code over 32 bad tools (names at 52 and 53 bytes and multibyte, bad descriptions and parameters, duplicates, bad `check/0` and `concurrent?/0` returns): every answer equal; the one difference is the module that a `FunctionClauseError` of a bad `check/0` names. The decoder takes and refuses the same `activated` values in a snapshot and an event.

| # | Source | Finding | Check | Resolution |
| - | ------ | ------- | ----- | ---------- |
| 1 | standards | The header of `ToolSpecs` said what moved, which is history | read | it says what the module owns |
| 2 | standards | `&(<<_::binary>> = &1)` is an idiom found nowhere else in the repo, there to save a line; it raises `MatchError` in place of `FunctionClauseError` | judgement | kept: `decoded/1` turns either into `:error`, and the line keeps the decoder at 400 |
| 3 | standards | The decoder has no room left; its next line needs a seam | judgement | open for the next change of the decoder |
| 4 | spec | No decode test of a non-string in `activated` | read | covered by the fixtures "tools_change: a name that is not a string" and "subscribe: activated with a name that is not a string" (`wire_fixtures_test.exs`) |

No round reproduced a defect, so the loop ended.
