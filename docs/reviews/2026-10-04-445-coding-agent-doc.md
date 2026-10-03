# Review: #445, coding-agent.md states the current runtime and one bounds table

Invariant: every sentence and row of `docs/features/coding-agent.md`, and every moduledoc that points into it, is true of the code it names; each bounds row names the attribute or function that holds the bound; the bounds of the turn, the provider process, the provider protocol, the harness programs, and the composer are linked to `session-lifecycle.md`, `one-provider-path.md`, `long-lived-harness.md`, and `multiline-composer.md`, not repeated.

## Round 1 (full)

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`

Simplify: removed the row of `model_change` and `harness_session` entries (it had no bound of its own), moved the default grace into the Bound cell, and fixed two stale references (`Helyx.TUI.Transcript` moduledoc, `multiline-composer.md` "exception 3"). Skipped: links in place of the tool Task, process group, and hold rows (`tool-resource-release.md` is a design record with old details, so this doc keeps the current statement); the prose of the `mix helyx` bullet (outside the ticket); the old edit plans in `external-turn.md`, `session-stream.md`, `tool-text-out-of-core.md`, and `tool-resource-release.md` that name removed rows (records of earlier tickets).

| Axis | Finding | Resolution |
| --- | --- | --- |
| Codex | the bash buffer keeps up to 409,600 bytes before `keep_tail/1` cuts to 204,800 | fixed |
| Codex | the session file rules said every cut partial message gets `aborted` or `error`; one with a tool call gets `tool_use` | cut; links `session-lifecycle.md`, "Turn end" |
| Standards | the TUI bullet said the table has the scroll costs and exceptions | fixed |
| Standards | the subscriber row named a behaviour as its owner | fixed |
| Standards | dropped rows: entry size per file, harness exit wait, session file append | rejected: the entry size follows the model ref and resume id rows, the exit wait is in `long-lived-harness.md` and `session-lifecycle.md`, and the one-write rule is in "Session file" |
| Standards, Spec | issue numbers and "accepted" in cells | kept for unbounded rows only: `review-checklist.md` asks for "unbounded, ticket #N" (#116, #90 are open) |
| Spec | owner cells named only a module | `read_marker/4`, `request_cancel/2`, `widget/3`, `page/5`, `hold/4` named |
| Spec | rules that say what Core rejects named no function | `check_version/1`, `Helyx.Session.Stream.check/1`, `send_text/3` named |
| Failure path | the TUI bullet said the table has the width rule and its exceptions | fixed; the rule is in `Helyx.TUI.Wrap`, and its moduledoc points to the bound |

## Round 2 (reduced: 5 lines of moduledoc in one code file, no function change)

| Axis | Finding | Resolution |
| --- | --- | --- |
| Spec | a comment in `Helyx.TUI.Transcript` said the feature doc has the measured costs and exceptions | cut |
| Failure path | the resume id row said only the provider's label is dropped; an entry with no string `provider` drops every label | cut to "the label is not restored" |
| Failure path | the replay rule for a cut message (`Transcript.resumable/3`) is now stated in no feature doc | open: belongs in `one-provider-path.md`, outside this ticket |
| Failure path | the `@doc` of `Helyx.Message.resume_id?/1` and `Helyx.Session.File.append_resume_id/3` says a resume rejects the file; the code drops the label | open: outside this ticket |

The round 2 fixes are two cuts with no new claim; no round 3 ran (45-minute limit).

Precommit: the first run had one failure in `Helyx.Provider.Codex.CommandsTest` ("a failed turn with an open command stops the provider process"), a test this change does not touch; three local runs of the file with `HELYX_SLOW=1` passed, and the second precommit run passed.

## Codex gate round 1 (reduced: Markdown only)

| Axis | Finding | Resolution |
| --- | --- | --- |
| Codex | the cut Replay section held two bounds that `long-lived-harness.md` lacked: `Helyx.HarnessIO.wire_id/1` and `tool_name/1` in `Helyx.Provider.Codex.Replay` | one row each added to the bounds of `long-lived-harness.md` |
| Codex | the TUI bullet said an event of another shape crashes the TUI; `Helyx.TUI.ViewModel.apply/2` ignores an unknown type | cut |

Spec and failure path on the changed lines: no findings. Precommit failed once on the same `Helyx.Provider.Codex.CommandsTest` test as above, then passed.

## Rows over 40 words (mechanisms to simplify)

- tool result text (45 words): one cut helper serves three readers, read and the model context with the head, bash and the harness providers with the tail, and a separate cut for one long line.
- Transcript scrollback (42 words): the cost bound needs three functions and a position that is an index, not an identity.
