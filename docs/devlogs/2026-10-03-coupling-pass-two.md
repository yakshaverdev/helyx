# 2026-10-03: coupling pass two

A second roll-forward `/orchestrate` run, after the decoupling run of the same day (`2026-10-03-decoupling-run.md`). The input was a second review of Core, the providers and the other plugins, with two questions: where is the coupling too strong, and which design choices reduce coupling and code together. The owner accepted the recommendations: the Tier A tickets, the `TurnLoop` module, and the session closing the assistant message (with the loss of per-message usage for harness providers). The TUI items need ADR 0006 and stayed out of the run.

## Merged

| Ticket | PR | What changed |
|---|---|---|
| #382 | #387 | Resume terms in Core: `origin: :provider` in `turn_start`. The stored string `"harness_session"` stays, so old session files resume. |
| #381 | #388 | `Watchdog.start/4` has one failure shape. `Text.cap/3` is the one cut helper. The composer UTF-8 gate is removed: ex_ratatui text is always a Rust `String`. |
| #379 | #389 | The open calls are derived from the transcript (`Transcript.open_calls/1`). `Turn.calls` and its second abort writer are removed. |
| #384 | #392 | The Codex sent-steer set and both `admit/3` are removed. `{:cancel_tool, call_id}` and `HarnessIO.close/2`. |
| #380 | #394 | The Loop uses the model call id. Arguments that are not a JSON object are a generic `Stream.check` rejection, and the model gets "tool call not run". The Core event `rejected_tool_call` is removed. |
| #383 | #396 | The provider event `{:notice}` and `max_notice_bytes/0` are removed. The reason bound is `@reason_max_bytes` in `Helyx.Watchdog`. `Stream.check` caps both terminals once. One `Helyx.Message.scrub/1`. |
| #393 | #397 | One generic required-callback check for every interface (`behaviour_info(:callbacks)` minus the optional ones). The provider-only check is removed. |
| #390 | #398 | `HarnessIO.keep_port/1` and its port monitor are removed. A dead watchdog takes the generic path: the provider process ends with `:epipe`, and the session fails the turn. |
| #385 | #399 | The session is the one owner of the assistant message boundary. Claude Code and Codex stop emitting `message_end`. At an abort or a failure, a message with a call joins the transcript, and its calls get `aborted`. |
| #386 | #400 | `Server.TurnLoop` owns every `activity` and `conn` transition. Abort and failure are one pipeline. The session owns the prepare Task, so preparing no longer waits behind a hands release. `server.ex` 613 to 366 lines, and its `.credo.exs` entry is removed. |
| #391 | #401 | Core comments use interface terms: provider, resume id, a turn the provider starts. |
| #395 | #402 | The pure struct `Helyx.Session.Tools` decides tool scheduling and returns effects. `Server.Tools` only runs them. |

Totals from `591fb5d` to `e2cac0c`: production code +1,080 / −1,117, tests +489 / −527, docs +647 / −134. The net line count is small this time, because the run moved code into modules with one owner (`TurnLoop`, `Session.Tools`). The plugins lost 152 lines net.

## Decisions taken alone

- I rejected the removal of the session's monitor of the provider process. The monitor tells that a process died before the send. A reconnect in `:submitting` could run a turn twice.
- #380: arguments that are not a JSON object get a generic rejection. I rejected `%{}` as arguments, because it runs a tool with arguments that the model did not send. I rejected a session path for them, because it keeps the coupling.
- #382 keeps the stored string in the session file.
- #383 keeps its bound in `Helyx.Watchdog`, which `HarnessIO` reads.
- #385 does not close the message at a Helyx `tool_request`, because a close there splits a harness message while its calls still arrive. Before the gate, I found that an abort while the program's own tool ran lost the open message from the session file. The worker fixed it in round 3. The loss was also on master, because the harness providers did not send `message_end` before their tools ran.
- #386: `State` keeps `ask/4` and `provider_pid/1`, because `Steering`, `Tools` and `Stop` use them.
- #391: links to `docs/features/long-lived-harness.md` stay, because a path names a file, not a concept.
- #395: `Record` is not split. Its write-failure policy sends the notice through `emit`, so a split removes no code and no dependency.
- The external review (pi agent, through deepwiki) was checked point by point. The double terminal cap was true and went into #383. The provider-only callback check was true and became #393. The tool scheduler with effects became #395. The claim about persistence was overstated, because `Record.persist` already owns the policy. The resume policy in Core stays, because every provider that resumes needs it.

## Escapes

| Ticket | Ship | Codex gate | System change |
|---|---|---|---|
| #382 | r1: 0 | r1: 0 | none |
| #381 | r1: 0 | r1: 0; a wrong statement in the commit message, corrected | none |
| #379 | r1: 0 | r1: 0 | Codex runs with the shared broker variable unset |
| #384 | r1: 0 | r1: 0 | none |
| #380 | commit 1: r1 1, r2 0; commit 2: r1 1, r2 the same mechanism | r1: 0 | review checklist: raw provider values in generic errors are bounded by the provider limits |
| #383 | r1: 0 | r1: 0 | none |
| #393 | r1: 1, r2: 0 | r1: 0 | none |
| #390 | r1: 0 | r1: 0 | none |
| #385 | r1: 1, r2: 0, r3: 0 | r1: 0 | none; the orchestrator found the loss before the gate |
| #386 | r1: 0 | r1: 0 | none |
| #391 | r1: 0 | r1: 0 | none |
| #395 | r1: 0 | r1: 0 | none |

Every ticket passed the Codex gate in round 1.

One system change: a worker found that a Codex review can read another worktree through the shared broker variable `CODEX_COMPANION_APP_SERVER_ENDPOINT`. The gate commands in `/ship` and `/orchestrate` now unset it.

## Owner answers during the run

- `keep_port/1`: delete it (#390).
- #351: closed as wontfix.
- Core comment terms: ticket a rename (#391).
- ADR 0006: after this run.

## Open, no ticket

- No run checked that Claude Code and Codex resume after a failed turn with an unanswered call of their own (#385). The real programs are not allowed in the worker sandbox.
- `TurnLoop.program_turn` is a Core function name that names the harness concept. `CONTEXT.md` still defines "Harness provider" and "Harness session".
- `State.tools` (tool specs) and `Turn.tools` (the scheduler) share a name, and two modules are named `Tools`.
- `Hands.spawn_armed/6` keeps a `turn_id` argument that is always nil.
- A plugin entry that is not a module raises in `Interface.implemented_by/1`. A reviewer found it; no run showed it.

## Next

- ADR 0006 (the TUI builds tool cells from the message, one contract version per build, snapshot through the live fold). A draft goes to the owner first.
