# The question tool: four harnesses

Research for ticket #744. It records how other harnesses let the model ask the user one or more multiple-choice questions and wait for the answer. It records observations only; the decisions go in the feature doc.

Date: 2026-10-18. Research only. Sources:

- OpenCode: sst/opencode @ 8f7b0120eb6b4aa3da1f82b1a9094a9fb4db2d06 (branch `dev`). Paths are under `packages/`.
- Claude Code: the bundle is closed. Facts come from code.claude.com/docs (read 2026-10-18 through the Claude Code docs server): `tools-reference`, `headless`, `hooks`, `sub-agents`, `remote-control`, `agent-sdk/user-input`, `agent-sdk/typescript`, `agent-sdk/agent-loop`. They are documented behaviour, not verified code. The transport facts come from the open Python SDK, anthropics/claude-agent-sdk-python @ f93e29cc951cd5fddcaaed9f3c49c3c38dedd6ab. anthropics/claude-agent-sdk-typescript @ 9cf9f23b757f881c82fc2bfee459429ea26187df has no SDK source (examples and changelog only), so it gives no facts here.
- Codex: openai/codex @ 8d9f6466ff0294785d56f55b1fe363d132fe4133. Paths are under `codex-rs/`.
- Gemini CLI: google-gemini/gemini-cli @ ed96faedfd5571f055c44f2c9509d62321d1138d. Paths are under `packages/` unless they start with `docs/`.
- "Inference" marks a conclusion that no line states.

## OpenCode: `question`

Files: `core/src/tool/plugin/question.ts`, `schema/src/question.ts`, `core/src/form.ts`, `schema/src/form.ts`, `server/src/handlers/session.ts`, `protocol/src/groups/session.ts`, `cli/src/run/noninteractive.ts`, `cli/src/acp/elicitation.ts`.

1. Arguments: `{questions: [Prompt]}`, at least one (`Schema.isNonEmpty()`, `question.ts:23-25`). `Prompt` is `{question, header, options: [{label, description}], multiple?}` (`schema/src/question.ts:6-18`). No maximum count of questions or options. Length limits are hints in descriptions only: `header` "Very short label (max 30 chars)", `label` "Display text (1-5 words, concise)". The code does not check them.
2. Free text: the description tells the model that "A 'Type your own answer' option is added automatically" (`question.ts:19`). Each question becomes a form field with `custom: true` (`question.ts:119-131`), so the form accepts a value outside the options (`form.ts:329,352`).
3. Answer: `{answers: [[string]]}`, one string array per question, in question order (`question.ts:27-29,98-105`). An unanswered question gives `[]`. The model reads text: `User has answered your questions: "<q>"="<a, b>", ... You can now continue with the user's answers in mind.` (`question.ts:38-46`).
4. Permission: each call first asserts the permission action `question` (`question.ts:63-72`). The Build agent and the Plan agent allow it (`core/src/plugin/agent.ts:84`, `core/src/plugin/plan.ts:38`). An action with no rule gets the effect `ask` (`core/src/permission.ts:87-97`). When the last matching rule denies `question` on `*`, the tool is not in the request (`core/src/tool.ts:231,292-295`).
5. The tool is one user of a generic Form service. `Form.ask` stores a pending entry with a `Deferred`, publishes `form.created` on the bus, and waits (`form.ts:124-162`). The same service serves MCP elicitation and the websearch provider prompt.
6. Transport to the client: `form.created`, `form.replied` and `form.cancelled` go out on the SSE stream `GET /api/event` (`schema/src/form.ts:173-175`, `protocol/src/groups/event.ts:44-52`). That stream is "Volatile by contract: ... events during disconnection are missed". A client that connects later reads pending forms with `GET /api/session/:sessionID/form` (`protocol/src/groups/session.ts:717`). The client answers with `POST /api/session/:sessionID/form/:formID/reply` and body `{answer: {q0: ..., q1: ...}}`, or cancels with `DELETE /api/session/:sessionID/form/:formID?message=...` (`protocol/src/groups/session.ts:763-792`). The server checks the answer against the fields (`form.ts:235-255`).
7. Several clients: the first reply or cancel settles the form. A later one gets `Form.AlreadySettledError`, which the server maps to `FormAlreadySettledError` (`form.ts:183-184,203`, `server/src/handlers/session.ts:651-679`). Clients remove the prompt on `form.replied` or `form.cancelled` (for example `tui/src/feature-plugins/system/notifications.ts:51`).
8. Dismissal: a cancel without a message is a "deliberate defect tunnel" (`question.ts:90-97`). The tool dies with `QuestionTool.CancelledError`, which model-request turns back into a decline (`core/src/session/model-request.ts:403-418`). The step then fails the tool with "The user dismissed this question" and ends as interrupted (`core/src/session/runner/step.ts:207-221`). A cancel with a message is a normal tool failure: the model reads the message and continues (`question.ts:95-96`).
9. Headless (`opencode run`): nobody can answer, so the run cancels each question with the message "This non-interactive run cannot ask the user questions, so the question was cancelled. Continue without an answer; make reasonable assumptions and state them." (`cli/src/run/noninteractive.ts:70-71,188-206`). In V1 compatibility mode it cancels without a message and sets exit code 1. It also handles questions from child sessions of its own session, and leaves other sessions on a shared server alone (`noninteractive.ts:141-156`).
10. ACP: the question becomes an ACP `elicitation` in form mode when the client supports it (`cli/src/acp/elicitation.ts:49-64,86-97`). If the client cannot show it, the form is cancelled with "The question couldn't be shown to the user in this client. Continue without an answer: ..." (`elicitation.ts:35-36,66-70`).
11. Abort: an interrupt of the waiting fiber cancels the form (`Effect.onInterrupt(() => cancel(form.id))`, `form.ts:157-159`). Shutdown of the location cancels every pending form (`form.ts:215-227`), and the step reports "Interaction cancelled because the location shut down" (`step.ts:210`).
12. Timeout: none. A pending form has an infinite time to live; a settled form stays 10 minutes (`form.ts:8,113-114`).
13. Subagents: the built-in subagent `general` denies `question`, and `explore` denies all actions except a list that does not name `question` (`core/src/plugin/agent.ts:86-117`). For a custom subagent the rules of that agent apply. Inheritance from the parent was not traced.

## Claude Code: `AskUserQuestion`

1. Arguments (docs `agent-sdk/typescript`, `hooks`):

   ```typescript
   type AskUserQuestionInput = {
     questions: Array<{
       question: string;
       header: string;
       options: Array<{ label: string; description: string; preview?: string }>;
       multiSelect: boolean;
     }>;
     answers?: Record<string, string>;
     annotations?: Record<string, { preview?: string; notes?: string }>;
     metadata?: { source?: string };
   };
   ```

   Limits from `agent-sdk/user-input`: "each `AskUserQuestion` call supports 1-4 questions with 2-4 options each"; `header` is "max 12 characters". `preview` is present only when the SDK option `toolConfig.askUserQuestion.previewFormat` is `"markdown"` or `"html"`.
2. Free text: the terminal UI has an `Other` row and a notes field (`tools-reference`). An SDK client adds its own "Other" choice and puts the typed text as the answer value (`agent-sdk/user-input`, "Support free-text input").
3. Answer: the answer is part of the tool input. The host returns `allow` with `updatedInput` = the original `questions` plus `answers`, a map from question text to the chosen label. A multi-select answer is an array of labels or labels joined with `", "`. An optional `response` is a free reply that answers no single question; then Claude reads "The user responded: …" (`agent-sdk/user-input`). A `deny` with a message: "Claude sees the message".
4. Transport (SDK): the tool goes through the permission flow. The SDK starts the CLI with `--permission-prompt-tool stdio` (`claude_agent_sdk/types.py:2281-2304`). The CLI sends a `control_request` with subtype `can_use_tool`, `tool_name`, `input` and `tool_use_id`; the SDK answers with a `control_response` with `behavior: allow|deny` (`_internal/query.py:586-640`). The CLI sends `control_cancel_request` when it abandons a request, and the SDK then writes no response (`_internal/query.py:420-426,691-693`). In TypeScript the callback gets an `AbortSignal`; in Python the signal is "reserved for future use" (`agent-sdk/user-input`).
5. A `PreToolUse` hook can answer the question: `permissionDecision: "allow"` with `updatedInput` that holds `questions` and `answers`. `"allow"` alone is not enough. `"defer"` ends a `-p` run with `stop_reason: "tool_deferred"` and the call in `deferred_tool_use`, so the caller can ask in its own UI and resume (`hooks`).
6. Headless (`-p`): the tool is offered only when the run has a permission host, such as a `canUseTool` callback or a `--permission-prompt-tool` (`hooks`, "allow with updatedInput"). With `--permission-prompts none` "Claude Code removes the tools that need an answer from a person, such as `AskUserQuestion`" (`headless`). In `dontAsk` mode `AskUserQuestion` is denied even when an allow rule matches (`headless`, `agent-sdk/agent-loop`).
7. Timeout: "The callback can stay pending indefinitely" (`agent-sdk/user-input`). In the terminal, questions stay open by default. The setting `askUserQuestionTimeout` (`60s`, `5m`, `10m`) closes an idle question: it "submits any options you'd already selected and tells Claude you may be away from your keyboard". The timer does not run in a background session, in screen reader mode, or with Remote Control (`tools-reference`). Before week 27 of 2026 the dialog auto-continued by default (`whats-new/2026-w27`).
8. Several clients: with Remote Control, the session syncs to "all connected devices"; questions are forwarded and "stay open until you answer them" (`remote-control`). Which answer wins when two devices answer was not documented.
9. Abort: the docs do not state the tool result when the user presses Esc on the question.
10. Subagents: `AskUserQuestion` is removed from every subagent, "even when listed in the `tools` field". A fork skips that filter and gets the main tool pool (`sub-agents`). The SDK page says: "`AskUserQuestion` is not currently available in subagents spawned via the Agent tool" (`agent-sdk/user-input`).

## Codex: `request_user_input`

Files: `core/src/tools/handlers/request_user_input_spec.rs`, `core/src/tools/handlers/request_user_input.rs`, `protocol/src/request_user_input.rs`, `core/src/session/mod.rs`, `app-server/src/bespoke_event_handling.rs`, `app-server-protocol/src/protocol/v2/item.rs`, `exec/src/lib.rs`, `tui/src/bottom_pane/request_user_input/mod.rs`.

1. Arguments: `{questions: [{id, header, question, options: [{label, description}]}]}`, all fields required, `additionalProperties: false`, `strict: false` (`request_user_input_spec.rs:16-89`). Limits are hints in descriptions: questions "Prefer 1 and do not exceed 3"; options "Provide 2-3 mutually exclusive choices"; `header` "12 or fewer chars"; `label` "1-5 words"; `id` "snake_case". The code checks only that every question has a non-empty `options` (`request_user_input_spec.rs:105-114`).
2. Free text: the handler sets `is_other = true` on every question (`request_user_input_spec.rs:116-118`), and the description says "the client will add a free-form \"Other\" option automatically". The protocol type also has `is_secret`; the model cannot set it (`protocol/src/request_user_input.rs:15-29`). The TUI shows the extra row as "None of the above" with a notes field (`tui/src/bottom_pane/request_user_input/mod.rs:65-66`).
3. Answer: `{answers: {<question id>: {answers: [string]}}}` (`protocol/src/request_user_input.rs:44-52`). The model gets this JSON as the tool output (`request_user_input.rs:96-102,148-151`). The TUI puts the chosen label first and notes as `"user_note: <text>"` (`tui/.../request_user_input/mod.rs:882-893`).
4. Availability: on by default; `[tools] experimental_request_user_input.enabled = false` turns it off (`core/src/config/mod.rs:2763-2769`). It works only in Plan mode (`protocol/src/config_types.rs:700-702`); in Default mode only with the feature `default_mode_request_user_input`, stage "under development", off (`tools/src/tool_config.rs:6-15`, `features/src/lib.rs:1830-1833`). In another mode the call fails with "request_user_input is unavailable in <mode> mode" (`request_user_input_spec.rs:91-103`). A call in Plan mode has `is_blocking = true` (`request_user_input.rs:81-85`).
5. Core wait: the session stores a oneshot sender in the turn state, keyed by the turn id, and emits `EventMsg::RequestUserInput` (`core/src/session/mod.rs:3236-3271`). A second request in the same turn overwrites the first with a warning ("Overwriting existing pending user input"). The answer arrives as `Op::UserInputAnswer {id, response}` (`core/src/session/handlers.rs:670-671`, `mod.rs:3278-3309`).
6. App-server transport: the event becomes the JSON-RPC server request `item/tool/requestUserInput` with `ToolRequestUserInputParams {threadId, turnId, itemId, questions, isBlocking, autoResolutionMs}`; the response is `ToolRequestUserInputResponse {answers}` (`app-server-protocol/src/protocol/common.rs:1810-1812`, `v2/item.rs:1736-1814`, `bespoke_event_handling.rs:833-880`). A client error, or a response that does not decode, is sent to core as an empty answer map (`bespoke_event_handling.rs:1652-1720`).
7. Several clients: the request goes to every connection subscribed to the thread (`app-server/src/outgoing_message.rs:336-440`). One callback exists per request id; the first response takes it, and a later one logs "could not find callback" (`outgoing_message.rs:473-500`). Then `serverRequest/resolved` goes to the subscribers (`request_processors/thread_lifecycle.rs:1020-1042`), and the TUI removes the question (`tui/.../request_user_input/mod.rs:946-959`). A connection that resumes the thread gets the pending requests again (`outgoing_message.rs:452-471`, `thread_lifecycle.rs:962-963`).
8. Abort: at `TurnStarted`, `TurnComplete` and `TurnAborted` the app-server aborts the pending server requests of the thread with a "turn transition" error (`bespoke_event_handling.rs:159-161,189-192,1218-1220`). In core, `clear_pending` drops the waiters (`core/src/state/turn.rs:139-145`, `core/src/session/input_queue.rs:315-319`), and the handler returns "request_user_input was cancelled before receiving a response" (`request_user_input.rs:87-94`).
9. Headless (`codex exec`): exec rejects the server request with "request_user_input is not supported in exec mode for thread `<id>`" (`exec/src/lib.rs:2134-2143`). By item 6, core then gets an empty answer map (inference). Exec does not run in Plan mode by default, so the tool usually fails first with the mode error of item 4 (inference).
10. Timeout: none for a blocking request. For a non-blocking request the TUI waits 60 s, shows a 60 s countdown, then submits an empty answer map (`tui/.../request_user_input/mod.rs:73-74,270-290,922-944`). Input snoozes the countdown. `autoResolutionMs` is deprecated.
11. Subagents: the tool is registered for every thread, but a non-root thread gets "request_user_input can only be used by the root thread" (`request_user_input.rs:67-71`, `core/src/tools/spec_plan.rs:1307-1314`).
12. A second tool, `request_user_input_async` (`{questions: [{title, options?: [string]}]}`, `minItems: 1`), is registered only for the root thread and only when the model catalog lists it (`spec_plan.rs:1316-1340`, `request_user_input_async.rs:40-80`). Its answer path was not traced.

## Gemini CLI: `ask_user`

Files: `core/src/tools/ask-user.ts`, `core/src/tools/definitions/model-family-sets/gemini-3.ts`, `core/src/confirmation-bus/types.ts`, `core/src/scheduler/confirmation.ts`, `core/src/policy/policies/non-interactive.toml`, `core/src/agents/local-executor.ts`, `cli/src/acp/acpSession.ts`, `docs/tools/ask-user.md`.

1. Arguments: `{questions: [{question, header, type, options?, multiSelect?, placeholder?}]}`, `minItems: 1`, `maxItems: 4` (`gemini-3.ts:618-694`). `type` is `choice` (default), `text` or `yesno`. A `choice` question must have 2 to 4 options, each with a non-empty `label` and a string `description`; the tool checks this (`ask-user.ts:45-88`). `header` has no limit in the schema; the doc says "max 16 chars" (`docs/tools/ask-user.md`).
2. Free text: "An 'Other' option is automatically added for 'choice' and 'yesno' types" (`gemini-3.ts:658`). `text` is free input only. With `multiSelect` the UI adds "All the above" (`docs/tools/ask-user.md`).
3. Answer: the model gets `{"answers": {"0": "...", "1": "..."}}`, keyed by question index, one string per question (`ask-user.ts:203-247`). A multi-select answer is joined with `", "` (`cli/src/ui/components/AskUserDialog.tsx:646`). A dismissal gives "User dismissed ask_user dialog without answering." (`ask-user.ts:190-201`); an empty submit gives `{"answers":{}}`.
4. Transport: the question rides the tool confirmation flow. `shouldConfirmExecute` returns details of type `ask_user` (`ask-user.ts:159-181`). The scheduler waits on the in-process message bus for a `TOOL_CONFIRMATION_RESPONSE` with the same `correlationId`; the payload carries `answers` (`core/src/scheduler/confirmation.ts:63-103`).
5. Several clients: the wait returns on the first response with the matching `correlationId` (`confirmation.ts:73-88`). The CLI has one UI per process. Over ACP, the confirmation becomes a `requestPermission` with only "Allow" and "Reject" (`cli/src/acp/acpUtils.ts:85-96,171-174`), and `onConfirm` gets the outcome without a payload (`cli/src/acp/acpSession.ts:746-774`). So an ACP "Allow" gives empty answers (inference).
6. Headless: the policy `non-interactive.toml` denies `ask_user` with priority 999 when the run is not interactive. The policy engine lists denied tools in `getExcludedTools`, and config adds them to the exclude set (`core/src/policy/policy-engine.ts:1118-1133`, `core/src/config/config.ts:2462-2469`).
7. Abort: the abort signal ends the wait with "Operation cancelled" (`confirmation.ts:68-70,92-102`).
8. Timeout: none. A comment recommends that the caller pass a signal with a timeout "in the event of a lost connection (e.g. IDE crash)" (`confirmation.ts:55-57`). The scheduler does not use `AbortSignal.timeout` (inference from a search of `core/src/scheduler`).
9. Subagents: a local subagent gets clones of the parent tools except tools of kind `Agent` and `update_topic` (`core/src/agents/local-executor.ts:203-216`). The generalist agent takes all tool names, so `ask_user` is not filtered (inference from `generalist-agent.ts:57`). Its confirmations go to the parent bus with the subagent name (`local-executor.ts:177-178`). The subagent system prompt says "You are running in a non-interactive mode. You CANNOT ask the user for input or clarification." (`local-executor.ts:1473-1476`).

## Observations

| | OpenCode | Claude Code | Codex | Gemini CLI |
| --- | --- | --- | --- | --- |
| Questions per call | 1 or more, no maximum | 1-4 | "do not exceed 3" (hint only) | 1-4 (schema) |
| Options per question | no limit | 2-4 | 2-3 (hint), at least 1 (checked) | 2-4 for `choice` (checked) |
| Multi-select | `multiple` | `multiSelect` | no | `multiSelect` |
| Free text | added by client | `Other` row and notes | `isOther` forced, notes | `Other`, plus `text` type |
| Answer key | question index | question text | question `id` | question index |
| Path to client | generic Form over SSE + REST | permission request (`can_use_tool`) | JSON-RPC server request | tool confirmation on a bus |
| Headless | cancel with a message, model continues | removed or denied without a host | rejected; empty answers | denied by policy |
| Timeout | none | none by default; opt-in idle timeout | none when blocking; 2 min TUI auto-resolve when not | none |
| Subagents | denied for built-in subagents | removed (forks keep it) | root thread only | not filtered; prompt says no |

- All four put the "other" answer in the client, not in the model's options. OpenCode and Codex tell the model not to add an "Other" option; Gemini CLI tells the model that one is added.
- Only Gemini CLI checks the option count in code. Codex checks only that options are not empty, OpenCode checks only that there is one question, and for Claude Code the check is not visible.
- In OpenCode, Claude Code and Gemini CLI, the question is a case of a general prompt path that other features share (forms, permission prompts, tool confirmation). Codex has its own event and server request for it.
- With several clients, OpenCode and Codex settle on the first answer and tell the other clients that the request is settled. Both also let a late client see the pending request (`GET .../form`, replay on resume).
- Headless runs differ in what the model sees: OpenCode returns a text that tells the model to continue; Claude Code and Gemini CLI remove the tool from the model's tool list; Codex returns an error or empty answers.
- Only OpenCode gives two cancel results: one ends the step as interrupted, the other is a tool error with a message.
- Bugs in the issue trackers were not searched.
