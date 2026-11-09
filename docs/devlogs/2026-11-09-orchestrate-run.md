# Orchestrator run, 2026-11-06 to 2026-11-09

One `/orchestrate` run of about three days. On 2026-11-07 the owner fixed the scope to the tickets open at that time (#492, #833, #859, #860, #869, #870, #878, #880 to #883, #885; #747 on hold). On 2026-11-08 the owner said to park nothing and to decide every open question from prior art; the decisions are listed under "Assumptions" for one review.

## Merged

| Date | PR | Ticket | Change |
|---|---|---|---|
| 11-06 | #861 | #832 | the log hold with a filter |
| 11-06 | #863 | #843 | ViewModelRule keeps failed and aborted replies |
| 11-06 | #864 | #844 | `SessionCase.await/2` delegates to `Events.wait_until/3` |
| 11-06 | #865 | #845 | Markdown recall reads the log newest first |
| 11-06 | #866 | #854 | the `:model_context` start option |
| 11-06 | #867 | #857 | ADR 0010, Helyx.Hub |
| 11-06 | #871 | #858 | ADR 0011, the UI block vocabulary |
| 11-06 | #872 | #836 | the most output tokens per message |
| 11-06 | #873 | #855 | wire conformance fixtures, protocol 3 |
| 11-06 | #874 | #835 | the prepare Task deadline for plugins |
| 11-06 | #875 | #862 | the log hold with no `:default` handler |
| 11-06 | #876 | #852 | Markdown recall by write-number names |
| 11-06 | #877 | #563 | ADR 0013, hooks |
| 11-06 | #884 | #834 | resume reads a session file of any size |
| 11-06 | #886 | #856 | ADR 0012, remote hands |
| 11-06 | #887 | #868 | the feature doc of Helyx.Hub |
| 11-06 | #888 | #553 | the system prompt of each provider call |
| 11-07 | #889 | #879 | the Hook interface |
| 11-07 | #890 | (owner request) | `--stale` between rounds, slow tests at the merge gate, no sleep waits |
| 11-07 | #891 | #492 (design) | the design of the MCP client; the ticket stays open |
| 11-07 | #892 | (owner request) | union merge of the escapes table; no precommit for Markdown only |
| 11-07 | #893 | #833 | delete a saved session and remove one message |
| 11-07 | #894 | #880 | `before_settle` and the continue turn |
| 11-08 | #895 | #881 | harness approvals through the hook chain |
| 11-08 | #896 | #883 | the command hook plugin |
| 11-08 | #897 | #878 | the UI block vocabulary, form first |
| 11-09 | #898 | #882 | the approval gate as a hook plugin |
| 11-09 | #899 | #860 | the client kit: Rust core, GPUI macOS app, wire fixtures |

All five ADR 0013 hook tickets are merged (#879 to #883).

## Open at the end of the run

| Work | Branch | State |
|---|---|---|
| #492 MCP client build | `ticket/492-mcp-client` (pushed) | 7 commits after the design: slices 1 and 2 and later slices; slice 7 drafts were in the worker's temp folder; 1 uncommitted file in the worktree |
| #869 Helyx.Hub | `ticket/869-hub` (pushed) | 9 commits, through "close the connections of a user when its access changes"; 9 uncommitted files in the worktree |
| repeat-fixes (owner request) | `chore/repeat-fixes` (pushed) | 2 commits: the `attach_test.exs:298` fix and "a precommit run on the host ends with its caller"; queued and not built: warm builds for a new branch, the `Codex.PromptTest` `:epipe` flake, the ssh keep-alive in `precommit.sh` |
| #885 | none | not started; its blockers #860 and #878 are merged, so it is ready |
| #870, #859 | none | not started; #870 waits on #869, #859 on #870 |
| #747 | none | on hold until a second provider exists |

The worktrees of the open branches stay under `.claude/worktrees/`. Each worker session can be resumed with its id in `.git/orchestrate/sessions.txt`.

## Incidents

- **A probe killed every process of the host user** (2026-11-07, about 16:57). A repeat-fixes probe sent `kill -s KILL -- -1` as the host user outside any namespace. The user's services restarted with lost state. Every worker brief now forbids a signal to a process the probe did not start and any `kill` with `-1`, `0` or a group.
- **A test froze the precommit queue twice** (#833). A port reports OS pid 0 until its program starts, and a test sent `kill -STOP 0`, which stopped the whole `mix precommit` pipeline. Test signals now go through `Helyx.Test.PerlSignal`, which checks the pid first.
- **Usage limits** stopped every worker four times. `.git/orchestrate/run-worker.sh` now waits until the printed reset time and resumes the session; before it, workers sat idle 46 minutes and 5 hours 24 minutes after two resets.
- **Workers killed with SIGTERM** at 02:28 on 2026-11-08 together with their background shells; nothing ran for about 6 hours. Workers now start detached with `nohup`.
- **Dead ssh connections** held six local precommit runs for 1.5 to 9 hours after their remote runs were gone. The local ssh config now sets a keep-alive for the precommit host (outside git); the same change in `precommit.sh` is queued on the repeat-fixes branch.
- **Stale host runs** of stopped workers kept their places in the queue, one holding the lock for 30 minutes; they were killed by hand. The repeat-fixes branch ends a host run with its caller.

## Flaky tests seen at merge gates

`apps/coding_agent` `attach_test.exs:298` (fixed on the repeat-fixes branch, not merged); `plugins/bundled` `Helyx.Provider.Codex.PromptTest` (`:epipe`), `Helyx.Watchdog.GroupTest` (a 300 ms deadline), `Helyx.Tool.BashTest` (#802 start case), `Helyx.Memory.MarkdownTest` 100,000-file recall (fixed in #891 with a stated load margin), `hooks_test.exs:741` (a 100 ms hook limit that counts the wait to start). Each passed on one rerun.

The GPUI macOS app is built only on this Mac, never at the Linux merge gate (owner's rule); a full local build of the workspace with the app is still to run after the run.

## Measurements

- Codex reviews: median 3.2 min (80 reviews), 98% model time. Workers waited about 5 h in fixed `sleep` polls before #890 removed them.
- Precommit without the slow tests (after #890): tests 29 to 44 s per project against 123 to 150 s before; a new branch's first run pays a cold Dialyzer of 167 to 219 s.
- The 100,000-file recall: 69 to 85 ms on the idle host.

## Assumptions

### Decided by the orchestrator

- **#878, can a tool request come before its `tool_call`?** Keep the Helyx call ids of each turn in a set, cap 256 per turn; a request past the cap fails its call. Reason: it closes W1 for every provider order with no real-service run; prior art: the tool queue already caps a turn's calls the same way.
- **#883, folder of the command hook at `before_settle`:** Core adds `cwd` (the session's folder) to the `before_settle` input. Prior art: Claude Code passes `cwd` in every hook input, Stop included; `before_tool` already has `cwd`.
- **#881, call-id owner:** derive it from the transcript and the hands' calls; a store only where a case cannot be derived.
- **#860, five TUI checks:** the schema is the contract; the TUI takes every frame the schema allows and cuts at render.
- **#833, hook entries of a removed call:** removed with the call, since requirement 2 of #833 says no byte stays; hook entries are only a log.
- **#492, slice 2:** `announce/1` returns `{:ok, kept}`; a source's loop must end on an exit signal from a process that is not its server Task.
- **#492, recall test:** waits `recall_ms` plus a load margin, 9,000 ms in all (measured 69 to 85 ms on the idle host; owner decision 2026-11-07).
- **repeat-fixes:** commit the `attach_test` fix; probe the host-run cleanup on the host with its own lock file and only processes the probe starts; fix the `Codex.PromptTest` `:epipe` flake the same way.

### Decided by workers (copied from their reports)
- **#881, finding 26** (a call that opens only after Core answered its Helyx tool request has no owner, so an approval for it runs the chain, against ADR 0013 §4): accepted as a stated hole. No provider in the repo reaches it (`Loop` and Codex send the call first; Claude Code sends no approval), and the order cannot be checked for every provider.
- **#881, finding 27:** the binding covers open calls, not every call of the turn ("of this turn" would need an unbounded store). The texts say "open call".
- **#881, Codex finding 32 rejected:** an approval for a call whose tool request got an immediate error result is denied; it is an answered Helyx call, and the deny fails closed.
- **#881, finding 33** (a call id reused in a later message inherits the owner of an ended call): accepted under #369, which does not check reused call ids; stated in `hooks.md`. No provider in the repo reuses a call id.
- **#881, findings 34 to 39:** built as the worker proposed (texts point to the stated exception; bounds row; `wait_ms()` in place of a fixed 5,000 ms cap; a test of the drop at an aborted result; the fallback clause of `drop/2` limited to a turn; a test asserts the deny reason), with no review round; the Codex gate checks the final code.
- **#881, `hooks_test.exs:741` flake** (a 100 ms hook limit that also counts the wait to start): left for the flake work, noted.
- **#883 (worker):** `before_settle` input fields follow Claude Code's `Stop` input (`hook_event_name: "Stop"`, `session_id`, `turn_id`, `cwd`, `stop_reason`, no `stop_hook_active`); `decision: "block"` with no reason continues with a fixed text; `continue: false` settles; `tools` in a `before_settle` entry is a broken config; the relay resets TERM and HUP to their defaults (prior art: libuv); a repeated JSON key is a failed hook (new `Helyx.JSON.decode/2` option `:unique_keys`); whitespace around the JSON object follows JavaScript's `trim()`, as the Claude Code binary does. Codex finding (bad `stop_reason` or `cwd` crashes the hook) rejected: Core builds both from checked values, and a crash is a failed hook.
- **#883, round 3 open case:** a multibyte whitespace character split at the output cut fails the hook (fail closed), built with no review round.
- **#878, past the 256-id cap (revised):** a Helyx request past the cap runs normally, but its call shows no blocks (the orchestrator's first rule failed the call, which would fail call 257 of a long agentic turn of `Helyx.Provider.Loop` for a UI-block reason). Prior art: Claude Code and Codex have no per-turn tool-call cap; `AGENTS.md`: reject the smallest unit that permits safe continuation.
- **#878 (worker):** the id set also holds at most 65,536 bytes of ids; after the cap, every provider block that names a call is dropped for the rest of the turn; UI blocks take wire protocol 5, the Hub plan moves to 6 and 7. Codex byte-bound finding rejected (a repeated id does not grow the set; the tool queue bounds request bytes).
- **#881, Codex gate finding rejected:** approval events are not matched against the current provider pid. A turn id is made per turn and sent only to that turn's provider process, so no other process can send the current turn id; tool requests use the same pattern on master (`server.ex:110-121`).
- **#883 (worker):** a split character that cannot be completed fails like any split; the cut start of a character that is not whitespace but shares its first bytes with a whitespace character fails too (fail closed).
- **#878 (worker):** a call past the cap gets `{:error, :too_many_blocks}` at once; a second request for an id past the cap runs again with no blocks (#369).
- **#883, Codex gate finding rejected:** `Helyx.JSON.decode("{}", :unique_keys)` returns `{:ok, %{}}` (checked); Codex itself could not support the finding.
- **#878, Codex gate finding rejected:** held result blocks keyed by a reused call id across concurrent runs: the reused-id case is #369's accepted hole, stated in the invariant.
- **Flake list:** `Helyx.Tool.BashTest` "a start that did not start the command leaves no held handle (#802)" failed once in the #881 merge gate; `Helyx.Watchdog.GroupTest` deadline test failed once (known).
- **#878 after #881 (worker):** an approval for a call id in the turn's Helyx set is denied (narrows #881's stated hole to calls past the cap); approvals are not denied past the cap (a denial would stop the provider's own runs); approval-chain asks end at the call's result; the branch commits were squashed to resolve the rebase once.
- **#878, gate round 2 finding rejected:** held blocks of an answered Helyx call attach to a later call that reuses its id: reused ids are #369's accepted hole.
- **#860, cycle G:** the TUI checks the size of every frame it sends, as the Rust core does; a notice is cut to its documented 4,000 bytes. Accepted: the block cut counts blocks, not bytes; the streaming message is walked in each frame; the block cut does not count tool calls in user or tool-result messages, and recall of a cut prompt loses text (only a server of another build sends such messages).
- **#860, cycle D2:** a `history` reply records a replaced instance only when it is the state's instance.
- **#860, cycle E2:** a close frame after a break is bounded by the socket's 5 s write timeout, not the send deadline (accepted).
- **precommit.sh ssh keep-alive:** every ssh call gets ServerAliveInterval=30, ServerAliveCountMax=4 (queued for repeat-fixes). Four local runs waited 1.5 to 9 hours on dead connections; the orchestrator ended the local ssh processes by hand on 2026-11-09 at 03:50.
- **#882 (worker):** rules name `tool`, optional `provider`, `action`, and the strictest match wins (deny, ask, allow; Claude Code's order); the default action is `:ask`; the wait limit is 600,000 ms; config key `:approval_hook`; answer `{"decision":"allow"|"deny"}` matched exactly; arguments cut at 16,384 bytes with the block's `cut` field; picker keys `y` and `n` (Codex); the gate is not added to the coding agent's plugin list; "don't ask again" and a deny note are left out.
- **#882, the owner's flag for sandboxed runs:** `default: :allow` with no rules is that flag; the doc names it.
- **#882, the picker on a short terminal:** the "more arguments" row is decided after the trim and drawn first, then the options, then the arguments (fixed with no review round).
- **ssh keep-alive in the local ssh config** (2026-11-09 09:22): `~/.ssh/config` gets `ServerAliveInterval 30`, `ServerAliveCountMax 4` for the precommit host only (backup at `~/.ssh/config.bak-20261109`). It applies at once to every worktree's ssh and rsync; two more runs (#860 5 h, #882 2.5 h) had hung on dead connections. The `precommit.sh` change stays queued for repeat-fixes.
- **#860 (worker):** the Rust core speaks protocol 5; master's #880 fixture case of a hook user message with no id changed from a break to valid (schema-valid, the origin is dropped); the app does not draw UI blocks yet (the core holds them); the core counts a number's bytes at the server's text; two files stay at 400 lines by rewrapping doc comments; earlier branch commits do not pass alone after the protocol-5 rebase, only the last does.
- **#882 (worker):** `Helyx.Hook.Approval.asked/1` public with doc false for a test; fewer than 3 rows puts both options on one line (Codex); the picker asks for at least 5 rows.
- **#882, Codex gate finding rejected:** a late allow after the hook's limit or an abort: since #879 the hands kill a hook Task at its limit and at an abort (an untrappable kill) and record the hook as failed, so the Task cannot return `:allow`.
- **#860 (worker):** the core keeps one fact, that a welcome came on one of its connections; before it any end stops (as the TUI's first connect), after it every end but a break or refused reconnects, once each 1,000 ms with no limit; the network thread ends when the window is gone.
