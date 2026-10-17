# Agent tool

Ticket #735. Research: `docs/research/subagents.md`.

## Goal

The model gives a task to a second agent and gets its final answer back as the tool result. `/ship` needs this: three reviewers with their own briefs, one of which must not see the reasoning of the main session. While the call runs, the TUI shows `agent: <description>` as its cell.

Decisions (ticket #735, orchestrator, owner away):

1. **A child session.** A subagent is a normal Helyx session in the same Core, started by the bundled Tool plugin `Helyx.Tool.Agent` through the public session API (`Helyx.Sessions.start/2`). Core gets no subagent concept. Reason: a session already has a lifecycle, a file, usage, an abort, and an end signal; the child reuses all of them.
2. **The tool.** Arguments: `description`, a short label for the cell, and `prompt`, the whole task. The child gets the parent's model (the model of the running turn), working folder, and tools, a fresh context with no history of the parent, and the same system prompt (the same ModelContext plugin builds it). The result is the child's final text, cut as any tool result. A child turn that fails gives an error result with the reason.
3. **A call context for tools.** `Helyx.Tool.context/0` gives the running tool call its Core, its session id, the tool names of its session, its call id, and the model of its turn. It is the smallest change that gives a tool that context: the hands put the context in the process of the tool call Task at its start, as `hold/1` and `background/0` already find the hands there. No callback changes, and every bundled tool keeps its behaviour.
4. **Depth 1.** The tool starts the child with `tools:`, the tool names of its own session but `agent`, so a child has no agent tool and cannot start a child, and gets no tool that the parent lacks. A call that reaches a limit gets an error text that tells the model to do the task itself.
5. **Concurrent.** `concurrent?/0` is `true` (#734). The cap of #734 (8 calls at once in a turn) and the Core cap (64 sessions) bound the children. A child that the Core cap refuses gives an error result, and the parent goes on.
6. **Abort and stop.** The tool holds the child (`Helyx.Tool.hold/1`), and its `release/3` stops the child with `Helyx.Sessions.stop/1`. An abort of the parent turn, a stop of the parent session, and a Core stop end the child, and the parent call gets its aborted result (at a Core stop, the parent ends too, and a resume gives the call its interrupted result, `docs/features/interrupted-calls.md`). A child that ends by itself (a crash) gives an error result.
7. **Storage and the list.** The child has its own session file, whose header links the parent session and the parent call id. The session list (`helyx --list`, the TUI `/resume` picker, `Helyx.Sessions.list_saved/2`) and the newest-session pick (`helyx --resume`) leave out every session with a parent. The result text starts with the child session id, so the TUI cell shows it, and a user can open the child later with `helyx --session <id>`.
8. **Usage.** The child's usage stays in the child session. The parent footer does not add it (follow-up).

Further decisions of this doc (owner away; the option that keeps Core smallest and matches the existing code):

- **The release stays on the hands loop.** #734 left a hole: the release of one delivery delays the results of the other calls, and the agent tool is the first concurrent tool with a release. The tool closes it for the normal end without a change to the hands: it stops its child in its own Task, then drops the hold with `Helyx.Tool.unhold/1`, before it returns. A delivery then has no handle to release. The release runs only at an abort (`:cancel`) and at a crash of the Task (`:deliver` of the crash), where it must run.
- **An owner process.** ADR 0004 asks a tool to free its resource when its Task dies with no release: the hands die first when the parent session crashes. The child is a session under the Core supervisor and is not linked to the Task. So the Task starts an owner process under the Core task supervisor, which monitors the Task, starts the child, and stops the child when the Task ends. The owner starts the child itself, so no kill of the Task between the start and the hold leaves a child that no process stops.
- **The parent link is the start option `:parent`**, `%{session_id: id, call_id: id}`, written in the header as `"parent": {"session_id": ..., "call_id": ...}`. Core reads it only in the scan of the list. A resumed child gets the tools of its Core, the agent tool too: a user who resumes a child drives it as a session of their own, and depth 1 bounds the children that a parent call starts. The header does not keep `:tools`, so a resume gives every session, a child or not, all tools of its Core.
- **One turn.** The tool sends one prompt and takes the first `turn_end` of the child. The final text is the text of the last assistant message of that turn. The child then stops, with any background run of it.
- **The result text** is `[agent session <id>]`, an empty line, then the final text, so the four lines of a collapsed TUI cell show the id. An error result starts with the same line.

## Interface changes

- `Helyx.Tool.context/0`: `%{core: Helyx.Core.name(), session_id: String.t(), tools: [String.t()], call_id: String.t(), model: String.t()}`, in a tool call Task of the hands. It raises in any other process.
- `Helyx.Session.start/2` (and `Helyx.Sessions.start/2`): the options `:parent`, `%{session_id: String.t(), call_id: String.t()}`, and `:tools`, the list of tool names that the session gets, nil (the default) for all. A bad `:parent` gives `{:error, :invalid_parent}` and a bad `:tools` `{:error, :invalid_tools}` (`Helyx.Session.resume/2` takes neither), before any file or process is created. A name of no registered tool adds nothing.
- `Helyx.Tool.specs/2`: the second argument `only`, nil or a list of the tool names to keep, applied after the checks.
- The session header: the optional key `"parent"`. The header version stays 1: a build before this one lists a child as a session, and loses nothing.
- `Helyx.Session.File.Scan.list/2` and the newest-session pick leave out a header with a `"parent"` key. `Scan.find/2` still finds the file by id.
- `Helyx.Session.Hands`: `run/4` takes the session id and the model of the turn for the context of the call; the hands add the Core, the tool names, and the call id.
- `Helyx.Tool.Agent`: the bundled tool `agent`, registered in `CodingAgent`.
- `Helyx.TUI.ViewModel.call_line/1`: a call of `agent` with a string `description` is `⚙ agent: <description>`, cut as every call line.

## Replaced mechanism

None. The hands, the queue, and the release are as #734 left them.

## Bounds

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| depth of children | 1: a child has no agent tool | a child that calls `agent` gets `unknown tool: agent` | `tools` in `Helyx.Tool.Agent.run/2`, `Helyx.Session.start/2` |
| agent calls that run at once in a turn | 8, the cap of #734 | the call waits | `Helyx.Session.ToolQueue` |
| sessions of a Core, children too | 64, the Core cap | an error result that tells the model to do the task itself | `Helyx.Sessions.start/2`; `Helyx.Tool.Agent` |
| `prompt` | a string; `Helyx.Session.max_text_bytes/0` (4 MiB), valid UTF-8 | an error result | `Helyx.Session.prompt/3` |
| `description` | a string | an error result | `Helyx.Tool.Agent.run/2` |
| `description` in the TUI cell | the 8,192-byte cut of every call line | cut | `Helyx.TUI.ViewModel.call_line/1` |
| `:parent` call id | 1 to 256 bytes of valid UTF-8, so the header stays far under the 65,536 bytes of a scan | `{:error, :invalid_parent}`; the agent tool gives an error result | `Helyx.Session.Input.parent/1` |
| `:tools` | a proper list of strings, or nil; the length has no bound of its own: it is product input, and the filter keeps only the registered names | `{:error, :invalid_tools}` | `Helyx.Session.Input.child/1` |
| `:parent` session id | a session id (`Helyx.Session.Id.valid?/1`) | `{:error, :invalid_parent}` | `Helyx.Session.Input.parent/1` |
| result text | `Helyx.Message.max_result_bytes/0`, as every result | cut, head and tail | the hands (`Helyx.Message.cut_result/1`) |
| events of the child in the Task mailbox | the Task acks each event (`Helyx.Session.ack/2`); past 16,384 unacked events the child ends the subscription | an error result | `Helyx.Session` subscribers |
| the stop of the child at the end of a call | none of its own: `Helyx.Sessions.stop/1` waits for the release of the child's hands, which has their release deadline | n/a | accepted; the parent's release deadline bounds it at an abort |
| wait for the child's turn | none: until the turn ends, the child ends, or the parent aborts; each step of the child turn has its own bounds | n/a | accepted, as the wait of any tool |
| the stop of a child in `release/3` | the release deadline (20 s); the stops of all held children run at once, so the deadline holds for each | the child stays held, reported unconfirmed: the hands refuse later calls | `Helyx.Tool.Agent.release/3` |
| listed sessions | children count in the 256 newest files that a scan reads | a full scan of children can push older parents out of the list | accepted; `Helyx.Session.File.Scan` |

Tests at the limits: the call id of 256 bytes, of 257, and of 256 bytes of multibyte text; the Core cap with 63 other sessions.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the child session | the owner process of the call, through `Helyx.Sessions.start/2` | the hands (`hold/1`), and the owner | the Task asks the owner to stop it, waits, then `unhold/1` | the hands deliver the crash and `release/3` stops it; when the hands die first, the owner sees the `:DOWN` of the Task and stops it | `release/3` (`:cancel`) stops it; the owner stops it again, a no-op |
| the owner process | the tool Task, under the Core task supervisor | itself | it exits after the stop | it monitors the Task: the `:DOWN` is its end | as on crash |

## Out of scope

Background subagents, agent definition files (agent types with their own prompt, tools, or model), a fork of the parent history, a model per call, more input to a running child, a view of the child's live events in the parent TUI, and the child's usage in the parent footer.
