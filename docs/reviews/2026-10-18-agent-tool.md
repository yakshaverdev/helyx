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
