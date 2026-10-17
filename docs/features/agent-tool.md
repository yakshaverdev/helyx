# Agent tool

Ticket #735. Research: `docs/research/subagents.md`.

## Goal

The model gives a task to a second agent and gets its final answer back as the tool result. `/ship` needs this: three reviewers with their own briefs, one of which must not see the reasoning of the main session. While the call runs, the TUI shows `agent <child id>: <description>` as its cell.

Decisions (ticket #735, orchestrator, owner away):

1. **A child session.** A subagent is a normal Helyx session in the same Core, started by the bundled Tool plugin `Helyx.Tool.Agent` through the public session API (`Helyx.Sessions.start/2`). Core gets no subagent concept. The one exception is the stop of the child, which acts on its pid (see "The cleanup acts on the process of the call"). Reason: a session already has a lifecycle, a file, usage, an abort, and an end signal; the child reuses all of them.
2. **The tool.** Arguments: `description`, a short label for the cell, and `prompt`, the whole task. The child gets the parent's model (the model of the running turn), working folder, and tools, a fresh context with no history of the parent, and the same system prompt (the same ModelContext plugin builds it). The result is the child's final text, cut as any tool result. A child turn that fails gives an error result with the reason.
3. **A call context for tools.** `Helyx.Tool.context/0` gives the running tool call its Core, its session id, the tool names of its session, its call id, and the model of its turn. It is the smallest change that gives a tool that context: the hands put the context in the process of the tool call Task at its start, as `hold/1` and `background/0` already find the hands there. No callback changes, and every bundled tool keeps its behaviour.
4. **Depth 1.** The tool starts the child with `tools:`, the tool names of its own session but `agent`, so a child has no agent tool and cannot start a child, and gets no tool that the parent lacks. A call that reaches a limit gets an error text that tells the model to do the task itself.
5. **Concurrent.** `concurrent?/0` is `true` (#734). The cap of #734 (8 calls at once in a turn) and the Core cap (64 sessions) bound the children. A child that the Core cap refuses gives an error result, and the parent goes on.
6. **Abort and stop.** The tool holds the child (`Helyx.Tool.hold/1`), and its `release/3` stops the process of the child that the call started (see "The cleanup acts on the process of the call"). An abort of the parent turn, a stop of the parent session, and a Core stop end the child, and the parent call gets its aborted result (at a Core stop, the parent ends too, and a resume gives the call its interrupted result, `docs/features/interrupted-calls.md`). A child that ends by itself (a crash) gives an error result.
7. **Storage and the list.** The child has its own session file, whose header links the parent session and the parent call id. The file is in `<sessions folder>/.children/`, one folder for the children of every project, so the session list (`helyx --list`, the TUI `/resume` picker, `Helyx.Sessions.list_saved/2`) and the newest-session pick (`helyx --resume`) never read it: the 256-file bound of the scan counts only sessions with no parent (orchestrator decision of 2026-10-18; `/ship` starts about ten children for each ticket). `Scan.find/2` looks in that folder too, so `helyx --session <id>` opens a child. The folder is not in a project folder because the path of a child must not depend on its cwd: the exclusive create and the lock of one child id then see one file, whatever the cwd of the start. No slug starts with `.`, and the scan hides names that start with `.`, so it is never taken for a project folder.
8. **Usage.** The child's usage stays in the child session. The parent footer does not add it (follow-up).
9. **The child id comes from the call** (orchestrator decision of 2026-10-18). Core derives the id of a session with a parent link from the link: the first 9 bytes of SHA-256 of the parent session id and the call id, as URL-safe Base64, which is a session id (`Helyx.Sessions.child_id/2`). The TUI cell of the call shows it from the call alone, before any result, so the user finds the child of an aborted or stopped call. Derived, not stored: no event, header, or result carries the id to the client. The parent session id has a fixed length of 12 characters, so the two strings join with no mark.

Further decisions of this doc (owner away; the option that keeps Core smallest and matches the existing code):

- **The release stays on the hands loop.** #734 left a hole: the release of one delivery delays the results of the other calls, and the agent tool is the first concurrent tool with a release. The tool closes it for the normal end without a change to the hands: it stops its child in its own Task, then drops the hold with `Helyx.Tool.unhold/1`, before it returns. A delivery then has no handle to release. The release runs only at an abort (`:cancel`) and at a crash of the Task (`:deliver` of the crash), where it must run.
- **An owner process.** ADR 0004 asks a tool to free its resource when its Task dies with no release: the hands die first when the parent session crashes. The child is a session under the Core supervisor and is not linked to the Task. So the Task starts an owner process under the Core task supervisor, which monitors the Task, starts the child, and stops the child when the Task ends. The owner starts the child itself, so no kill of the Task between the start and the hold leaves a child that no process stops.
- **The cleanup acts on the process of the call** (orchestrator decision of 2026-10-18). The id of a child is derivable, so after the child ends, a resume can start a new instance of the id, which the user drives. The owner reads the pid of the child with `Helyx.Session.pid/1` at once after the start and puts it in the handle, `{session, pid}`. The owner cleanup and `release/3` stop that pid with `GenServer.stop/3`, never a lookup of the id. A process that is gone needs no stop. The stop ends a running turn of the child as a Core stop does, with no abort first: the abort of the session API acts on the id. This stop is the one call of the tool outside the session API: `Helyx.Session.pid/1` is public, and the stop is OTP's. Accepted hole: a child that ends, and a new instance of its id that starts, between the return of the start and the read of the pid, would be the one that the call holds; the owner reads the pid in its next step. Open (#735 merge gate, reported to the orchestrator): the subscribe, the prompt, and the acks of the call act on the id, so a child that ends and a resume of its id between the start and the prompt give the parent's task to the new instance. An exact fix needs a prompt bound to one instance in the session API.
- **The parent link is the start option `:parent`**, `%{session_id: id, call_id: id}`, written in the header as `"parent": {"session_id": ..., "call_id": ...}`. Core uses it for the id, the folder, and the header of the file only.
- **A reused call id gets no second child.** The id of a child is a function of the parent session and the call id, so a second agent call with the call id of an earlier one in the same session would get the same id. A process of the id runs in the Core, or its file exists, so the start fails with `{:create_failed, :eexist}` before it writes (a second Core on the same sessions folder gets `{:session_locked, id}` while the first child runs), and the call gets an error result; the first child and its file stay as they are. At the Core cap the start gives `:too_many_sessions` before the id is checked. A session with no sessions folder has no file, so only a running child of the id stops the second one; a child that ended in memory left nothing to find. In one turn, an open call id already stops the provider (#734). A provider that reuses call ids across turns has no evidence today: the OpenAI and Anthropic ids are unique. A counter or the message id in the derivation would give the second call its own child, but the TUI cell would then need state that the call does not hold; the generic failure is the answer until a real provider shows the case.
- **A resume gives all tools of the Core** (orchestrator decision of 2026-10-18). A resumed child is a session that the user drives, so it gets the tools of its Core, the agent tool too, and depth 1 still bounds the children that a parent call starts. The header does not keep `:tools`, so a resume gives every session, a child or not, all tools of its Core.
- **One turn.** The tool sends one prompt and takes the first `turn_end` of the child. The final text is the text of the last assistant message of that turn. The child then stops, with any background run of it.
- **The result text** is the final text of the child, as the ticket says; an error result is the reason. The cell has the child id from the call (decision 9).

## Interface changes

- `Helyx.Tool.context/0`: `%{core: Helyx.Core.name(), session_id: String.t(), tools: [String.t()], call_id: String.t(), model: String.t()}`, in a tool call Task of the hands. It raises in any other process.
- `Helyx.Session.start/2` (and `Helyx.Sessions.start/2`): the options `:parent`, `%{session_id: String.t(), call_id: String.t()}`, and `:tools`, the list of tool names that the session gets, nil (the default) for all. A bad `:parent` gives `{:error, :invalid_parent}` and a bad `:tools` `{:error, :invalid_tools}` (`Helyx.Session.resume/2` takes neither), before any file or process is created. A name of no registered tool adds nothing.
- `Helyx.Tool.specs/2`: the second argument `only`, nil or a list of the tool names to keep, applied after the checks.
- The session header: the optional key `"parent"`. The header version stays 1. A child file is in `<sessions folder>/.children/`, which a build before this one does not read: it does not list a child and cannot open one by id.
- `Helyx.Session.File.path/4`, `mkdir/3`, and `create/5` take the parent link: a child is in the `.children` folder, and the create of every session file is exclusive, so an existing file gives `{:error, {:create_failed, :eexist}}`. `Scan.find/2` looks in the `.children` folder too; the list and the newest-session pick do not.
- `Helyx.Sessions.child_id/2`: the id of the child of a session id and a call id.
- `Helyx.Session.Hands`: `run/4` takes the session id and the model of the turn for the context of the call; the hands add the Core, the tool names, and the call id.
- `Helyx.Tool.Agent`: the bundled tool `agent`, registered in `CodingAgent`.
- `Helyx.TUI.CallLine.line/2` (the call line, moved out of `Helyx.TUI.ViewModel`) and `ViewModel.from_snapshot/2` take the session id: a call of `agent` with a string `description` is `⚙ agent <child id>: <description>`, cut as every call line; the id comes first, so the cut keeps it. `Helyx.TUI.Switch.bind/3` passes the id of the session.

## Replaced mechanism

- `Helyx.Session.start/2` attached to a running process of its id, as a resume does. It now starts through `Helyx.Session.Server.Open.create/3`, with no attach: a derived id can name a running child, and the start must not return it. `resume/2` keeps the attach of `Open.start/4`.
- The create of a session file was a plain append. It is now exclusive for every session (`Helyx.Session.File.create/5`): a derived id can name the file of an earlier child.

The hands, the queue, and the release are as #734 left them.

## Bounds

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| depth of children | 1: a child has no agent tool | a child that calls `agent` gets `unknown tool: agent` | `tools` in `Helyx.Tool.Agent.run/2`, `Helyx.Session.start/2` |
| agent calls that run at once in a turn | 8, the cap of #734 | the call waits | `Helyx.Session.ToolQueue` |
| sessions of a Core, children too | 64, the Core cap | an error result that tells the model to do the task itself | `Helyx.Sessions.start/2`; `Helyx.Tool.Agent` |
| `prompt` | a string; `Helyx.Session.max_text_bytes/0` (4 MiB), valid UTF-8 | an error result | `Helyx.Session.prompt/3` |
| `description` | a string | an error result | `Helyx.Tool.Agent.run/2` |
| `description` in the TUI cell | the 8,192-byte cut of every call line, after the child id | cut | `Helyx.TUI.CallLine.line/2` |
| `:parent` call id | 1 to 256 bytes of valid UTF-8, so the header stays far under the 65,536 bytes of a scan | `{:error, :invalid_parent}`; the agent tool gives an error result | `Helyx.Session.Input.parent/1` |
| `:tools` | a proper list of strings, or nil; the length has no bound of its own: it is product input, and the filter keeps only the registered names | `{:error, :invalid_tools}` | `Helyx.Session.Input.child/1` |
| `:parent` session id | a session id (`Helyx.Session.Id.valid?/1`) | `{:error, :invalid_parent}` | `Helyx.Session.Input.parent/1` |
| result text | `Helyx.Message.max_result_bytes/0`, as every result | cut, head and tail | the hands (`Helyx.Message.cut_result/1`) |
| events of the child in the Task mailbox | the Task acks each event (`Helyx.Session.ack/2`); past 16,384 unacked events the child ends the subscription | an error result | `Helyx.Session` subscribers |
| the stop of the child at the end of a call | none of its own: `GenServer.stop/3` of the child's pid waits for the release of the child's hands, which has their release deadline | n/a | accepted; the parent's release deadline bounds it at an abort |
| wait for the child's turn | none: until the turn ends, the child ends, or the parent aborts; each step of the child turn has its own bounds | n/a | accepted, as the wait of any tool |
| the stop of a child in `release/3` | the release deadline (20 s); the stops of all held children run at once, so the deadline holds for each | the child stays held, reported unconfirmed: the hands refuse later calls | `Helyx.Tool.Agent.release/3` |
| listed sessions | the 256 newest files of the project folders; a child is in the `.children` folder and is not counted | n/a | `Helyx.Session.File.Scan` |
| `Scan.find/2` | one listing of each project folder and of the `.children` folder; no file read but the one found | n/a | `Helyx.Session.File.Scan` |
| a reused call id | one child for each parent session and call id, whatever the cwd; in memory, one running child | an error result; the first file is not written. A kill between the exclusive create and the header write leaves an empty file at the id, which `Scan.find/2` reports as `{:invalid_file, _}`: accepted, only a reused call id names it again | `Helyx.Session.File.create/5`; the Registry (`Helyx.Session.Server.Open.create/3`) |

Tests at the limits: the call id of 256 bytes, of 257, and of 256 bytes of multibyte text; the Core cap with 63 other sessions; a scan of one file with a newer child; a second child of one link, later in another cwd, and at once in memory; a fixed value of the derived id.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the child session | the owner process of the call, through `Helyx.Sessions.start/2` | the hands (`hold/1`), and the owner | the Task asks the owner to stop it, waits, then `unhold/1` | the hands deliver the crash and `release/3` stops it; when the hands die first, the owner sees the `:DOWN` of the Task and stops it | `release/3` (`:cancel`) stops it; the owner stops it again, a no-op |
| the owner process | the tool Task, under the Core task supervisor | itself | it exits after the stop | it monitors the Task: the `:DOWN` is its end | as on crash |

## Out of scope

Background subagents, agent definition files (agent types with their own prompt, tools, or model), a fork of the parent history, a model per call, more input to a running child, a view of the child's live events in the parent TUI, and the child's usage in the parent footer.
