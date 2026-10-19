# Provider parity

Ticket #651. ADR 0002, revision of 2026-10-17, states the rule and holds the one list of named trade-offs and limits. The facts are in `docs/research/provider-parity.md`.

## Goal

A product picks a model ref, and the provider kind does not change what the product gets. A harness provider (`Helyx.Provider.ClaudeCode`, `Helyx.Provider.Codex`) gives the model the system prompt of the turn's `Helyx.Context`, exactly the session's tools, and none of the user's own harness config. So a product that is not a coding agent can run on `claude-code/<m>` or `codex/<m>` with no code change, and the coding agent on a harness shows the same Helyx tool cells as on an API provider. Each difference that stays is a named trade-off or limit in the ADR 0002 list; any other difference is a bug.

## Interface changes

- `Helyx.Provider` moduledoc: a harness provider uses the `system` of the turn's context too. Only the context per call stays a named limit. No callback changes.
- `Helyx.HarnessIO.harness_tools/1` is removed: every provider gets the session's tools.
- New in `Helyx.HarnessIO`: `session_id/2` and `resumable/2` for the stored id with its digest, and `finish/1`, the end of a program that another one replaces. Before each launch, `HarnessIO` releases the groups of the program before and drops their handles from the hands with `Helyx.Tool.unhold/1`, new in Core.
- `Helyx.Provider.Codex.Items`: a `dynamicToolCall` item gives the Helyx tool name and arguments, and its result is the text of its `contentItems`, an error when `success` is false. Claude Code: the transcript has the Helyx name of a tool use, without the `mcp__helyx__` prefix. So the cells and the snapshot are the same as with an API provider.

### The prompt

- The effective prompt is `context.system`, or `""` when it is nil: a nil system is an empty product prompt and never the native coding prompt (the research note shows that the empty value removes the native prompt on both programs).
- A program or a thread that needs the prompt starts at the first turn of the provider process, not in `init/3`. `init/3` keeps its checks (the model, the program on `PATH`); Codex also starts the program and answers `initialize` there.
- Each provider keeps the effective prompt of its running program (`system` in its state). At a turn start, a prompt that is not the kept one restarts the program with a resume of its harness session and the new prompt: at most once per turn, because only the turn start checks it. The text is kept, not a digest: the comparison is exact, and a Claude relaunch after a lost session needs the text.
- Claude Code: the launch has `--system-prompt=` (empty) and `--system-prompt-snapshot=off`, and the first line on stdin is the control request `initialize` with `systemPrompt`. The prompt goes on stdin, so its size has the stdin bound of the watchdog and no argv bound. A resume with `off` takes the new prompt (research). An error response to `initialize` stops the provider process with `%Helyx.ProviderError{kind: :initialize, text: text}`, or `{:initialize, ""}` with no text; with no response the request still has the empty prompt of the flag, never the native one.
- Codex: `baseInstructions` on `thread/start` and on `thread/resume`. A resume in a new program takes the new text; on the program that has the thread loaded it does not (research). So a changed prompt ends the program and starts a new one that resumes the thread. A steer of the old program with no answer yet gets `{:error, :restarted}`: the session queue does not wait for a steer answer before the next turn, so one can be open.
- On both, the new program starts only after the old one exited (`HarnessIO.finish/1`): two programs never run one harness session.
- A compaction is not a model turn and has no context. It keeps the prompt of the running program. Codex keeps the running program too. Claude Code runs it in a program without `--disable-slash-commands` (see "Exact tools"): the running program is replaced by one that resumes its harness session, as at a prompt change, and the next turn replaces that one again. With no program yet and a stored id, it opens the program with the empty prompt; the next turn then restarts it with its own prompt.

### Exact tools

- Claude Code: `--tools=` turns off every built-in tool. The model sees only `mcp__helyx__<name>` for each session tool. `--disallowedTools=Bash,Monitor` goes: `--tools=` covers it.
- Claude Code (#754): every program that takes a model turn has `--disable-slash-commands`, so a user line runs no program command or skill. The flag also takes out `/compact`, and no control request compacts (research), so the program of a compaction runs without it (`docs/features/harness-compaction.md`). The program still reads a first word that starts with `/` as a command name: a named limit in ADR 0002.
- Codex: `--disable shell_tool --disable unified_exec` as before, and the isolation flags below. The program keeps some tools of its own (a named limit). The probe of #754 found no `codex app-server` option, feature, or thread parameter of 0.163.0 that removes them; the config key `model_catalog_json` was not tried (research).
- The coding agent registers `read`, `edit`, `write`, and `bash`, so its model uses the Helyx file tools on a harness too.

### No user config

- Claude Code: `--setting-sources=` and `--strict-mcp-config`, with the Helyx `--mcp-config` server. The login stays (research R1). `--safe-mode` gave the same request, but its `init` line still listed the user's installed plugins; `--setting-sources=` listed only the built-in ones, so it is the one used.
- Codex: `--disable apps --disable plugins --disable hooks --disable goals --disable view_image --disable image_generation -c project_doc_max_bytes=0 -c web_search="disabled" -c skills.include_instructions=false -c skills.bundled.enabled=false -c include_permissions_instructions=false -c include_apps_instructions=false`. The ChatGPT login stays (research R3).
- Neither set gives full isolation. Each residual of the research is a named limit in ADR 0002.

### Resume eligibility

- The stored id of a harness session is `<id>#<digest>`, the first 16 hex digits of the SHA-256 of the JSON of what the program fixes at the start of the session and does not change on a resume: the isolation flags, and for Codex also the `dynamicTools`. A stored id whose digest is not the one of the current flags and tools starts a fresh harness session with the replay. So a session stored before this change, whose history holds the user's `CLAUDE.md` or `AGENTS.md` text (research), is not resumed.
- The prompt is not in the digest: both programs take a new prompt on a resume. Claude's tools are not in it: the program asks `tools/list` at each launch. `--disable-slash-commands` is not in it: it is a flag of one launch, the compaction's program has none, and a session stored before #754 is resumed.
- The replay does not depend on the prompt or the tools. Historical tool calls are not rewritten.

## Replaced mechanism

| Old | New |
| --- | --- |
| `HarnessIO.harness_tools/1` drops `read`, `edit`, `write` by name | removed; every session tool goes to the program |
| Claude `--disallowedTools=Bash,Monitor`; the native tools stay | `--tools=` |
| the native prompt; `context.system` ignored | the effective prompt replaces it |
| the user's `CLAUDE.md`, hooks, skills, plugins, and MCP servers load | `--setting-sources=`, `--strict-mcp-config` |
| Codex reads `AGENTS.md`, skills, plugins, hooks, apps | the isolation flags above; residuals named |
| Claude launches in `init/3` | launches at the first turn, or at a compaction with a stored id |
| Codex starts or resumes the thread in `init/3` | `init/3` starts the program and `initialize`; the thread opens at the first turn, inside the reply bound of `{:turn, ...}` |
| Claude stored id `<uuid>` | `<uuid>#<digest>`; an old id is not resumed |
| Codex stored id `<thread>#<tools digest>`, or `<thread>` with no tools | `<thread>#<digest of flags and tools>` always; an old id is not resumed |
| a compaction keeps the running program | Claude Code: the compaction runs in a program without `--disable-slash-commands`, which resumes the harness session, and the next turn replaces it with a program that has the flag (#754) |
| Claude: `close` and `idle_close` before the first turn end a program | answer `:ok` at once: no program runs (Codex keeps its program from `init/3`) |

Tests: the file-tool filter tests (`harness_tools_test.exs` for the filter, the `@file_tools` cases of both `helyx_tools_test.exs`) now check that the file tools reach the program. The connect tests of Codex move to the first turn. A Claude test that read the launch arguments after `init/3` reads them after the first turn.

Users see: the model of a harness has the product prompt and the Helyx tools only; the coding agent's file edits are Helyx `edit` and `write` cells. A session stored before this change starts a fresh harness session with the replay, once. A compaction before any turn of a resumed session starts the program.

## Bounds

| What | Bound | Over the bound | Where |
| --- | --- | --- | --- |
| prompt restarts | one per turn start; Claude Code also one per compaction, for its flags | none: only the turn start and the compaction check | `request/3` of each provider |
| Claude prompt size | the stdin bound of the watchdog, 16 MiB (`@stdin_max_bytes`) | the watchdog stops the program group; the provider process stops | `Helyx.Watchdog` |
| Codex prompt size | the same stdin bound; no limit of `baseInstructions` is known | as above; a rejection by the program fails the turn through its error path | `Helyx.Watchdog` |
| Codex thread open at the first turn: `thread/start` or `thread/resume`, then the replay and `turn/start` | the reply bound of `{:turn, ...}`, 2,000 ms (`@provider_reply_ms`). Observed `thread/start`: 62 to 871 ms with the login, about 3 s with an unreachable base URL (research) | the armed kill; the turn fails with `:provider_timeout`. A named limit: a slow network can fail a first turn that would have failed at the model call | Core |
| Claude launch at the first turn: the watchdog start | the same 2,000 ms; the launch waits only for the watchdog's go-ahead, not for the program | the same | Core |
| Claude relaunch at a compaction: the old program's exit, the release, the launch | the 2,000 ms reply bound of `{:compact, ...}`, as a prompt relaunch | the same | Core |
| exit of the old program at a prompt relaunch, or at a Claude compaction and the turn after it | 1,000 ms after the end of its input (`@end_wait_ms` in `Helyx.HarnessIO`). Observed: a Helyx close of Claude took 615 and 628 ms (`docs/research/claude-code-stream-json.md`, "Processes"); not measured for Codex | the program is stopped (TERM, grace, KILL), and the turn fails with `:program_not_ended`; the provider process stops | provider |
| Codex relaunch after a prompt change: the old program's exit, program start, `initialize`, `thread/resume`, `turn/start` | the same 2,000 ms | the same | Core |
| release of the groups of the program before, at a launch | 500 ms (`@let_go_ms` in `Helyx.HarnessIO`). At a turn start it is part of the 2,000 ms reply bound: with the 1,000 ms exit wait, at most 1,500 ms of it, and the rest is for the launch (and for Codex `initialize`, `thread/resume`, and `turn/start`). A Claude lost-session relaunch runs in a turn, with no reply bound: the turn takes up to 500 ms longer. The groups of a program that exited are gone, so the release only confirms it | the handles of a group that is not gone stay held, and the next launch or the end of the provider process releases them. The release probes every group before any signal or wait, so a group that ignores TERM keeps only its own handle, not the handles of the gone groups. While such a group stays, each launch gives it a TERM again and waits the 500 ms | provider |
| digest of the stored id | 16 hex digits; an id is at most 36 + 1 + 16 bytes (Claude) or the thread id + 17 (Codex) | not reached: under the 256 bytes of `Helyx.Message.resume_id?/1` | provider |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| --- | --- | --- | --- | --- | --- |
| program port, watchdog, program group | the first turn (Claude), `init/3` (Codex), a prompt relaunch, a Claude compaction relaunch, a Claude lost-session relaunch | as in `docs/features/long-lived-harness.md` | as there | as there | as there |
| the program replaced by a prompt or compaction relaunch | as above | the provider process until the relaunch | `HarnessIO.finish/1`: the end of its input, then its exit, before the new launch: two programs never run one harness session | as above | n/a: the relaunch is at the start of a turn or a compaction |
| the hands' handles of a replaced program | `Helyx.Watchdog.start/4` at its launch | the hands | at the next launch, the provider's own `release/3`, then `Helyx.Tool.unhold/1` of the confirmed handles: the hands hold the handles of one program, not two per relaunch | the hands release them when the provider process ends | as at a crash |

## Out of scope

- A product option for the native tools or an appended prompt: it comes with a product that needs it.
- Images and attachments.
- The OpenAI-compatible endpoint config (#652).
- A hook before each harness model call: research only (#650 keeps its harness exceptions).
