# Summary compaction

Ticket #490. The compaction of a provider that keeps its own history is `harness-compaction.md` (#552).

## Goal

A model provider (`Helyx.Provider.Loop`) gets its whole context from the Helyx transcript, so a long session fills the context window and then fails. With this feature, the agent writes a summary of the older part of the transcript when the context is almost full, and goes on. The user can also run `/compact`. The full history stays in the session file and in the transcript. Only the model context uses the summary.

Decisions of the owner (ticket #490, decisions comment of 2026-10-17):

1. **The policy is the plugin's.** Core dispatches and stores. The Compaction plugin chooses the trigger, the cut, and the summary instructions. Core never calls `Helyx.ModelInfo`: it passes the model ref, and the plugin uses the helper. An unknown window turns off automatic compaction, and a manual `/compact` gets a clear error.
2. **The interface.** `compact/2` returns the context as before, or `{:summarize, plan}`. A Core-defined plan holds the context of the summary call, the id of the first kept message, and the token estimate. Core checks the plan at the boundary. `Helyx.Compaction.None` keeps returning its input.
3. **The summary call** runs in a separate provider process for the model of the turn, with no tools, no recall, no compaction, and no resume history. It never goes to the session's provider process as a `{:turn, ...}`: `Helyx.Provider.Loop` resets its turn on one. It can be aborted, it is outside the 10 s prepare kill, and it has the waits of a turn. A summary asked during a context request finishes before Core answers that request. Its output is never an assistant message of the transcript.
4. **The entry.** A new entry in the session file, apart from the compaction entry of a harness: the summary, the id of the first kept message, and the tokens before. Messages appended while the summary runs are kept. A failed or aborted summary keeps the previous context and entry: a turn goes on with the context of the last summary after a `:notice` with the failure, and a `/compact` fails with it. A failed write keeps the summary in memory only, and nothing claims that it is saved.
5. **The bundled plugin.** Keep 20,000 recent tokens, reserve 16,384 tokens, clamped to the window, and cut only at a user or assistant message, so a call keeps its results. Generic sections; no file lists. A summary cap of 64 KiB. A later compaction updates the previous summary.
6. **Overflow.** Core turns a context-overflow error into one compaction and one retry. Any other failure is not retried.
7. **`/compact` on a model provider** runs this path in place of the notice of the `:unsupported` answer.

Decisions of this doc:

- **The plugin builds every context with the summary.** Core passes the current summary in `opts[:summary]` and the whole transcript as the messages, as before. The plugin cuts the messages at `first_kept_id` and puts its summary message in front. Reason: the framing of the summary is policy, and the plugin already runs before every provider call. With `Helyx.Compaction.None` a stored summary is not used, and the model gets the whole transcript, which loses nothing.
- **A first kept message that the ModelContext removed cuts nothing.** The ModelContext runs before the plugin and can remove messages. When the message of `first_kept_id` is not in the built messages, the plugin puts the summary in front of all of them, and a new summary covers the messages from the first one on. Reason: the newest user message stays in the context. A failed build would fail every turn while the ModelContext removes that message. The cost is that the messages the summary covers are sent twice, which loses nothing.
- **Core summarizes only for a model provider.** The trigger of a provider that keeps its own history (not `Helyx.Provider.Loop`) is nil: the plugin builds the context but must not ask for a summary, and a plan is a contract break. Reason: a harness compacts its own history (`harness-compaction.md`), and two summaries of one history fight each other. Such a provider still gets the context with the summary as its replay, after a model switch or a lost thread.
- **One summary for each context build.** After a summary, Core builds the context again with trigger nil and the new summary. A plan in that build is a contract break, and the build fails with `{:bad_context, :compaction}`. Reason: a plugin whose estimate stays over its threshold would otherwise summarize forever.
- **The summary cap is a Core bound.** The session keeps the text of the summary call in memory and writes it to the file, so the bound must hold where the text grows: in the session, not in the plugin. 64 KiB is the number of decision 5.
- **The overflow retry is in `Helyx.Provider.Loop`.** On a model call that fails with `{:context_overflow, detail}` before any content, the loop asks for a fresh context with the new action `{:need_context, turn_id, :overflow}` once in a turn, and calls the model again with the answer. Reason: the loop owns the held steers and the calls of the turn, and a context request keeps them. A second overflow in the turn ends the turn with the error.
- **The event is `:compaction`.** A summary gives `%{trigger: :manual | :auto, tokens_before: n, tokens_after: nil}`; an overflow summary is `:auto`. Reason: the clients show it already, and the user sees the same line for each kind of compaction.
- **The estimate of the bundled plugin.** With no summary, the estimate of #488: the `context_tokens` of the last usage, plus a quarter of the bytes of the messages after it. With a summary, a quarter of the bytes of the context to send: every usage in the kept messages counts the context from before the summary, and the entry does not tell which message came after it.
- **The window of the bundled plugin.** The `context_window` of the last usage of a message of the same model (the serving side, or the catalog through the provider's `Helyx.ModelInfo` pricing), else the `:models` config entry through `Helyx.ModelInfo.lookup/4` with no catalog id, else unknown. Reason: only the provider names its catalog id; a model that has not answered yet in this session has no catalog step, and its first call can overflow into the overflow path.
- **The coding agent registers `Helyx.Compaction.Summary`** in place of `Helyx.Compaction.None`. `None` stays as the no-op plugin.

Prior art: the cut, the keep and reserve defaults, the sections, and the update of a previous summary follow the reference agent of the ticket (checked in its source by the owner, 2026-10-04 and 2026-10-17).

## Interface changes

**`Helyx.Compaction.compact/2`** returns one of:

| Return | Session |
| --- | --- |
| a `Helyx.Context` | sent, as before |
| `{:summarize, %Helyx.Summary.Plan{}}` | the summary call runs, then the context is built again |
| `{:error, text}`, a string | the build fails: the turn fails, or the context request gets the error |

`opts` gains:

- `:model`: the `Helyx.ModelRef` of the turn.
- `:summary`: the current `Helyx.Summary`, or nil.
- `:trigger`: `:auto` before a provider call, `:manual` in a `/compact`, `:overflow` after a context overflow, or nil for a provider that keeps its own history and for the build after a summary or a failed one (no plan allowed).
- `:instructions`: the text of `/compact`, else `""`.

**`Helyx.Summary`** (`text`, `first_kept_id`, `tokens_before`): the stored summary. **`Helyx.Summary.Plan`** (`context`, `first_kept_id`, `tokens_before`): what the plugin asks for. Core checks a plan in `Helyx.Session.Stream.prepare/4`: a `Helyx.Context` with the checks of a built context, a `first_kept_id` that is the id of a user or assistant message of the transcript, and `tokens_before` from 0 to 10^9. Anything else is `{:bad_context, :compaction}`.

**The summary call.** Core starts a provider process for the provider and model of the turn, under the hands, with no tools, no resume id, and the session as its receiver, and sends `{:turn, summary_id, context}` with the plan's context and `tools: []`. Its text deltas, in order, are the summary. Thinking and message ends are dropped. A tool call, a tool request, a context request, or any other event fails the summary, and so does a `done` with a stop reason other than `:end_turn`: a cut or refused text must not replace the messages it covers. After the `done` the session closes the process.

**Provider action:** `{:need_context, turn_id, :overflow}`, which `Helyx.Provider.Loop` sends. The session answers it as `{:need_context, turn_id}`, with trigger `:overflow`; from a provider that keeps its own history the trigger is nil, as for any of its builds, so it gets a context and no summary.

**Provider error:** `{:context_overflow, detail}` is the error of a model call whose context is over the window of the model. No bundled provider gives it yet: no research note records the error that the OpenCode gateways send at overflow (open, see "Out of scope").

**Session file:** the entry `{"type": "summary", "summary": text, "first_kept_id": id, "tokens_before": n}`. A resume takes the last one. A summary entry whose text is not a string of 1 byte to 64 KiB, whose `first_kept_id` is not the id of an earlier user or assistant message, or whose `tokens_before` is not an integer from 0 to 10^9, makes the file invalid, as any other damaged entry does.

**Events:** `:compaction` as above. A failed summary outside a `/compact` gives a `:notice` with its failure. The summary call gives no other event.

**`Helyx.Session.compact/2`** on a model provider: the compaction turn builds the context with trigger `:manual`. A plan runs the summary, and the turn ends `done` with the `:compaction` event. A context (no summary, such as from `None`) gives a notice that neither the provider nor the plugin compacted. An error fails the turn with its text.

## Replaced mechanism

The `:unsupported` answer to `{:compact, ...}` ended the compaction turn with a notice (`Helyx.Session.Server.Compaction.unsupported/1`). It now builds the context with trigger `:manual`, and the notice stays for a build that returns a context. The test of the notice keeps its property for `None`.

## Bounds

| What | Bound | Over the bound | Enforced in |
| ---- | ----- | -------------- | ----------- |
| summary text in the session | 65,536 bytes | the summary fails; the previous summary stays | `Helyx.Session.Server.Summary` |
| summary text from the disk | 65,536 bytes | the file is invalid | `Helyx.Session.File.Reader` |
| summaries in one context build | 1 | the build fails: `{:bad_context, :compaction}` | `Helyx.Session.Stream.prepare/4` |
| overflow retries in one turn | 1 | the turn fails with the overflow error | `Helyx.Provider.Loop` |
| connect of the summary process | 30 s armed kill, as any provider process | the summary fails at its `provider_down` | `Helyx.Session.Hands` |
| answer to the summary `{:turn, ...}` | 2,000 ms armed kill | the summary fails at its `provider_down` | OTP timer server |
| the start of the summary process | the 5 s default of the `GenServer.call` in `Hands.start_provider/3`, as at a turn start; the hands can be busy past it while a release runs (up to 20 s), and the summary adds a start in the middle of a turn | the call exits the session; open in #677 | `Helyx.Session.Hands` |
| the model call of the summary | unbounded, as a turn | the user aborts | client |
| the end of the summary process after an abort or a close | the release deadlines of the hands; the wait holds until its `provider_down` | the hands report it | `Helyx.Session.Hands` |
| the plan's `tokens_before` | 0 to 10^9 | `{:bad_context, :compaction}` | `Helyx.Session.Stream` |
| a tool result in the summary input (bundled plugin) | 2,000 bytes | cut to its first 2,000 bytes, with no mark | `Helyx.Compaction.Summary` |
| the summary input as a whole (bundled plugin) | unbounded: a first summary, or one after the ModelContext removed the first kept message, of a transcript far over the window can overflow the summary call | the summary fails, and the turn goes on with the previous context; accepted, with no retry of the summary call (question 5 of the ticket body) | none |
| the error text of the Compaction plugin | 4,000 bytes, as any failure reason | cut | `Helyx.Reason.text/1` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| summary provider process | session, through `Hands.start_provider/3` | hands (a Task of the hands); the session holds its pid in `summary_call` | the session asks `:close` after the `done`; the hands release it and send `provider_down` | the session's death takes the hands, which take the Task | the turn end stops it with `{:shutdown, :aborted}`; the wait holds until its `provider_down` |

## Out of scope

- A provider that gives `{:context_overflow, detail}`: the OpenCode gateways need an observed overflow response first. Until then the overflow path runs only with a provider that gives it.
- The usage and the cost of the summary call: no message holds them.
- The summary in the snapshot of a session, and a line for it at a resume.
- A summary that the user can read.
- A retry of a summary call that overflows (question 5 of the ticket body; the decisions do not ask for it): the summary fails, and the turn goes on with the previous context.
