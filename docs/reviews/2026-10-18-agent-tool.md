# Review: the agent tool (#735)

Feature doc: `docs/features/agent-tool.md`. Base of the diff: `b42d8aa6` (the branch point; `origin/master` moved to `9cd55244` after it, so `git diff origin/master` also shows the #705 files).

Invariant: a child session that the agent tool starts gets exactly the tools of its parent session but `agent`, has the model of the parent's turn and its working folder, is linked in its header to the parent call and left out of the session list and the newest pick, and is stopped when its call ends, when the parent turn is aborted, and when the parent session, the call Task, or the Core ends.

## Round 1 (full)

Simplify (4 agents): applied the reuse of `Helyx.Test.Gate.open/0`, the context built in `ToolRuns` (the hands got no session id), no guard on the session id of an event, no default argument in `Scan.header/3`, one cut in the TUI call line, and `Message.text/1` once per turn. Skipped: no hold and release (decision 6 of the ticket asks for them), child files in a subfolder (a change of the storage layout; the scan bound is accepted), the parent's specs passed to the child (the checks are cheap), the model string on the `Turn` (trivial), a generic description rule in the TUI (it changes other tools; the ticket names only `agent`), an opaque header field (the ticket asks for a parent link), the release off the hands loop (decided in the feature doc), shared code with `Print` (other behaviour), a rename of `Input.child/1` (minor).

Bounds sensor (base `origin/master`):

```text
bounds sensor: 21 candidate functions, 3 flagged, 0 without an answer
  lib/helyx/interfaces/tool.ex:215  WAIT  def unhold(handles) when is_list(handles) do
  plugins/bundled/lib/helyx/tool/agent.ex:48  SIZE  def run(%{"description" => description, "prompt" => prompt},
  plugins/bundled/lib/helyx/tool/agent.ex:139  SIZE  defp await(child, ref, last) do
```

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | Codex [high] | the child excluded only `agent`; `Session.start/2` rebuilt its tools from all Core registrations, so a parent started without `write` had a child with `write` | read (the Codex probe reproduced it) | `:without_tools` became the allowlist `:tools` (`Helyx.Session.start/2`, `Helyx.Tool.specs/2`); the hands put the tool names of the session in `Helyx.Tool.context/0`; the agent passes them without `agent`; test "a child gets no tool that the parent lacks" |
| 2 | standards, spec | `release/3` ran its stops at the default `max_concurrency` (the scheduler count), so up to 8 children on a small host could pass the deadline | read | `max_concurrency: length(children)`; the round 2 spec probe saw both releases start at once, and a second release did not come in 5 s with `max_concurrency: 1` |
| 3 | failure path, spec, standards | the feature doc said `Hands.start_link/1` takes `:session_id` and `run/4` the model; `run/3` stayed in `hands.ex` and `loop_test.exs` | read | fixed |
| 4 | standards | no bounds row for `:without_tools` | read | a row for `:tools` |
| 5 | spec | the `:parent` call id row has no agent test | read | fixed in round 2 (test of a 257-byte call id) |

Judged and not changed:

- Structs for the parent link and the call context (standards): they stay maps, as the other option maps of `start/2`; `Input.child/1` checks the shape at the boundary.
- `Input.child/1` also checks `:tools`, the "child" names in Core, `one_line/1`, `child_test.exs` with no `child.ex`, and the repeated `head <> "\n\n"` (standards, judgement): kept. The parent link is a generic header field.
- The `"agent"` clause of `ViewModel.call_line/1` (standards, Repeated Switches): the ticket names the agent cell.
- The result prefix `[agent session <id>]` (spec, scope): a decision of the feature doc, so the TUI cell shows the id.
- The aborted result does not name the child id (spec): the hands make the `aborted` result after a kill of the Task; accepted hole.
- A resumed child gets the agent tool (spec): accepted hole, stated in the feature doc. The resume reads the tools before the file.
- The queue limit text of #734 and `unknown tool: agent` do not tell the model to do the task itself (spec): generic texts of Core; only the Core cap is a limit of the agent tool.
- A prompt over 4 MiB starts a child before `Session.prompt/3` refuses it (spec): the call gets an error result, and the child stops. The tool does not repeat the check of Core.
- Bidi characters of the description reach the terminal (spec): the same class as all model text, which `Helyx.TUI.Wrap.sanitize/1` treats the same way.
- No tests of the `:slow` end, of the release timeout, and of the model at a later switch: the code paths are short; recorded as gaps.

Failure path: no reproduced code defect. Probes: an owner suspended during the start, then an abort (7 runs); an abort, then a read (10 runs). Not reached: the cap that frees between a stop and a start, a Core stop while an owner starts, the scan of 256 files with children.

## Round 2 (full)

The fix of round 1 changed the arity of `Helyx.Tool.specs/2` and `Hands.run/4`, and more than one code file: a full round.

Simplify (1 agent with the four angles, for the 45-minute limit): applied the context fields that the hands have (`core`, the tool names) added in `Hands.start/4`, so `ToolRuns` passes only the session id and the model; `max_concurrency` without `max/2` (the release runs only with handles); a clause on `nil` in `specs/2`. Skipped: a separate `Input.tools/1` (the 400 lines of `session.ex`).

Bounds sensor (base `origin/master`):

```text
bounds sensor: 21 candidate functions, 3 flagged, 0 without an answer
  lib/helyx/interfaces/tool.ex:217  WAIT  def unhold(handles) when is_list(handles) do
  plugins/bundled/lib/helyx/tool/agent.ex:48  SIZE  def run(%{"description" => description, "prompt" => prompt},
  plugins/bundled/lib/helyx/tool/agent.ex:140  SIZE  defp await(child, ref, last) do
```

Codex: approve, "No material blocker found"; in-memory probes of tool inheritance, abort, Task death, parent death, parent stop, and release timeout.

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | failure path | a resume drops `:tools` of any session, so a product session started with `:tools` has all Core tools after a resume | yes (a throwaway test) | the same mechanism as the accepted hole of a resumed child; the feature doc states that a resume gives every session all tools of its Core. The invariant of the agent tool holds: a child gets the current tools of its parent |
| 2 | standards, spec | the Tool moduledoc and decision 3 left `tools` out of the context; the `start/2` doc named `specs/1` | read | fixed |
| 3 | standards | no bounds row for the stop of a child at the end of a call | read | a row: no bound of its own, the release deadline of the child's hands |
| 4 | standards | the call id row had no test | read | test "a call id over 256 bytes gives an error result and starts no session" |

Judged and not changed: the context built in two modules (the session id stays a `run/4` field, so the hands keep no session id); `session.ex` at 400 lines with a wider wrap of the `start/2` doc (it holds the limit; the text that does not fit is in the feature doc); `:sys.get_state/1` in one agent test.

Guarantee table (round 2 spec review):

| Guarantee | Evidence |
| --------- | -------- |
| `specs/2` keeps only the tools in `only` | `test/helyx/session/child_test.exs:30` |
| `specs/2` applies `only` after the checks | probe: a bad spec outside `only` still gives `{:bad_tool_spec, "bad"}` |
| `context/0` gives the Core, the session id, the tool names, the call id, the model | `test/helyx/session/hands_test.exs:72` |
| `context/0` raises outside a call | `test/helyx/session/hands_test.exs:80` |
| bad `:tools` or `:parent` starts nothing | `test/helyx/session/child_test.exs:40`, `:75` |
| the `:parent` call id has 1 to 256 bytes of UTF-8 | `test/helyx/session/child_test.exs:65`; the agent: `plugins/bundled/test/helyx/tool/agent_test.exs` "a call id over 256 bytes" |
| a parent link keeps the session out of the list and the newest pick | `test/helyx/session/child_test.exs:48`, `plugins/bundled/test/helyx/tool/agent_test.exs:86` |
| a child has no `agent`, and no tool that the parent lacks | `plugins/bundled/test/helyx/tool/agent_test.exs:89`, `:98` |
| `release/3` stops all children at once | probe (see round 1, item 2) |
| the model of the turn, not of a later switch | code reading only; no test |
| a release timeout leaves the child held | no test; accepted |

Round 2 reproduced no defect of the invariant, so the loop ends.

## Precommit

The first slow precommit run failed one test: `Helyx.Tool.ReadTest`, "is the only concurrent bundled tool", expected `MapSet.new(["read"])` and got `MapSet.new(["agent", "read"])`. The test records the state of #734; the agent tool is concurrent by decision of the ticket. The test now expects `agent` and `read`. A test change only, so no review round.

# Run 2: children out of the scan, a child id derived from the call

Orchestrator decisions of 2026-10-18: children must not use scan slots, and the user must find the child of an aborted or stopped call. The base of every round is `d6bb41ae`, the feature commit, rebased onto `origin/master`. The rounds ran on the working tree.

Invariant: one parent link has at most one child session. Its id is derived from the parent session id and the call id (`Helyx.Sessions.child_id/2`). Its file is `<sessions folder>/.children/<id>.jsonl`, whatever its cwd. A second child fails with `{:create_failed, :eexist}` at once, later, or in another cwd, and the first file stays unchanged and findable by `Scan.find/2`. `Helyx.Session.start/2` never attaches to a running process of its id. The list and the newest pick never read or count a child. The TUI cell of an agent call shows the derived id.

## Round 1 (full)

Simplify (4 agents): applied `Id.child/2` with the encode of `Id.new/0`, one `jsonl_paths/1` over a list of folders, the exclusive create for every session file, and the codec note in `wire-protocol.md`. Skipped: a required session id in `CallLine.line/2` (the test helpers and the bench build view models with no session), the second mkdir in `File.create/5` (pre-existing), and one `File.write` with `:exclusive` (minor).

Bounds sensor (base `HEAD`):

```text
bounds sensor: 11 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/lib/helyx/tool/agent.ex:140  SIZE  defp await(child, ref, last) do
```

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | Codex [high] | a second child of one link while the first runs: `Server.Open.start/4` attached to the running process and skipped the exclusive create | read | `Server.Open.create/3`, a start with no attach for `Session.start/2`; test "a second child of one link while the first runs, or at once" |
| 2 | standards | the call-line tests stayed in `view_model_test.exs` after the move to `Helyx.TUI.CallLine` | read | moved to `call_line_test.exs` |
| 3 | standards | the scan test did not prove that a child takes no slot | read | the child is made the newest file, and a scan of one file still picks the parent |

Judged and not changed: the parent map as a struct (standards; it stays an option map, checked by `Input.child/1`), and the doc reference of `child_id/2`.

The spec agent and the failure-path agent of this round died with: `Agent terminated early due to an API error: You've hit your session limit · resets 6am (Asia/Makassar)`. Round 2 ran both again.

## Round 2 (full)

The fix of round 1 added a function (`Open.create/3`): a full round.

Simplify (2 agents, two angles each): applied `launch/3`, the start shared by `start/4` and `create/3`, and the comment of `start/4`, which named `start/2`. Skipped: a helper for the children folder, a filter in the listing of `find/2` (it runs only at a resume), the header written through the exclusive handle, and the session id passed as an argument in `ViewModel` (low cost).

Bounds sensor (base `HEAD`):

```text
bounds sensor: 10 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/lib/helyx/tool/agent.ex:140  SIZE  defp await(child, ref, last) do
```

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | failure path | the child path depended on the cwd: after the first child stopped, a second child of the link in another cwd made a second file with the id, and `Scan.find/2` gave `:duplicate_id` | yes (a throwaway test) | the second finding on the uniqueness of a derived id, so the mechanism changed and not the path: every child is in `<sessions folder>/.children/`, so the exclusive create and the lock see one file for each id. No slug starts with `.`, and the scan hides dot names. Test "a second child of one link, in any folder" |
| 2 | spec, standards | at the Core cap, a second child of a running link gives `:too_many_sessions`; `server-management.md` said `eexist` | yes (spec probe) | the docs state the cap case; a test was added in round 3 |
| 3 | spec | in memory, a child that stopped leaves nothing, so a second child of the link starts | yes (spec probe) | stated in the feature doc: in memory, only a running child stops a second one |
| 4 | standards | no test fixes the value of the derived id, which the wire note states | read | test of a fixed value in `child_test.exs` |
| 5 | standards | `File.mkdir/2` in `server-management.md`, `from_snapshot/1` in the struct comment of `ViewModel` | read | fixed |

Codex [medium]: "Keep existing child files out of automatic resume". The finding: the old scan left out a header with `"parent"`, so child files in a project folder would be listed after an upgrade. Rejected: only `d6bb41ae`, the unmerged commit of this ticket, wrote child files in a project folder. No released build did, and both commits merge together.

Judged and not changed: the nil session id in `CallLine.line/2` and `from_snapshot/2` (the bench and the test helpers), and the empty file that a failed header write leaves (see round 3).

## Round 3 (full)

The fix of round 2 is the second finding on one mechanism: a full round.

Simplify (1 agent, four angles): no change. Skipped: the header written through the exclusive handle, the second mkdir, the nil defaults, the session id as an argument, and the `{:started, _}` tag (it keeps the errors of the open apart from the errors of the supervisor).

Bounds sensor (base `HEAD`):

```text
bounds sensor: 11 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/lib/helyx/tool/agent.ex:140  SIZE  defp await(child, ref, last) do
```

Codex: approve, "No material defect found within the stated scope."

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | failure path | a kill of the session between the exclusive create and the header write (the open deadline, a Core stop) leaves an empty file at the derived id; a later child of the link gets `eexist`, and `Scan.find/2` gives `{:invalid_file, _}` | yes (3 of 3) | judged as the accepted hole that the brief named: only a reused call id names that id again, and a reused call id gets no second child by decision. Before this run, the same kill left an empty file at a random id. Stated in the bounds row of a reused call id |
| 2 | standards | the doc of `Session.start/2`, the moduledoc of `Session.File`, and `coding-agent.md` gave only the project path | read | fixed |
| 3 | standards | "Replaced mechanism: None" in the feature doc | read | two entries: the attach of `start/2`, and the plain create |
| 4 | standards, spec | no test of the cap for a second child of a running link | read | a test in `sessions_cap_test.exs` |
| 5 | spec | a second Core on the sessions folder gets `{:session_locked, id}` while the first child runs, not `eexist` | yes (spec probe) | stated in the feature doc |
| 6 | standards | "Core uses it for the id and the folder of the file only" left out the header | read | fixed |

Judged and not changed: the parent map as a struct, and the names `create/3` and `start/4` (their comments state the difference). No test checks that `Helyx.TUI.Switch.bind/3` passes the session id: recorded as a gap.

Round 3 reproduced no defect outside the accepted holes, so the loop ends.

Guarantee table (round 3 spec review):

| Guarantee | Evidence |
| --------- | -------- |
| a child file is at `.children/<id>.jsonl`, whatever its cwd | `test/helyx/session/child_test.exs`, "a child has the id of its link", "a second child of one link, in any folder" |
| the list and the newest pick do not read or count a child | `child_test.exs`, the scan of one file with a newer child; the list shares the code of the pick |
| `Scan.find/2` finds a child | `child_test.exs`; `plugins/bundled/test/helyx/tool/agent_test.exs`, the abort test |
| the create is exclusive, gives `eexist`, and does not write | `child_test.exs`; `agent_test.exs`, "a second call with the call id of an earlier child" |
| a second child while the first runs, or at once in memory, gets `eexist` and no attach | `child_test.exs`, "a second child of one link while the first runs, or at once" |
| at the cap, `:too_many_sessions` before the id check | `test/helyx/sessions_cap_test.exs` |
| the derived id has the rule of the wire note | `child_test.exs`, the fixed value |
| the TUI cell shows the id from the call, before any result, and the cut keeps it | `plugins/bundled/test/helyx/tui/view_model_test.exs`, `call_line_test.exs` |
| a child that ended in memory leaves nothing | probe only (spec, round 3) |
| `Switch.bind/3` passes the session id | no test; gap |

## Precommit of run 2

The first slow precommit run failed on Credo only: "`with` contains only one <- clause and an `else` branch, consider using `case` instead", `lib/helyx/session/file.ex:98:5`. The tests passed: 740 in the root, 941 and 2 properties in `plugins/bundled`, 80 in `apps/coding_agent`. `new_file/1` now uses `case`, with the same two branches. This is a change of form only, so it got no review round.
