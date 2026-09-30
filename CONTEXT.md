# Helyx

Helyx is an Elixir substrate for agent-native, stateful products. This glossary fixes the words used in code, docs, issues, and tests.

## Components

**Core**:
The part of Helyx every product needs: plugin registration, OTP supervision, and interface dispatch.
_Avoid_: framework, kernel, runtime

**Interface**:
A behaviour plus a public API that products call. It declares a mode: `single` (one active plugin) or `multi` (many active plugins).
_Avoid_: extension point, slot, contract

**Plugin**:
A module that implements an interface. Bundled plugins use the `Helyx` root; external plugins use their own root.
_Avoid_: extension, adapter, integration

**Product**:
Independent software built on Helyx. It selects plugins and owns its domain code.
_Avoid_: app, application, host

## Runtime

**Session**:
One conversation with one agent. A supervised process that owns the transcript, the queues, and the current turn.
_Avoid_: conversation, chat, thread, agent

**Session instance**:
One start of a session process. A resume keeps the session id and makes a new instance, and two Cores can hold one session id with two instances. An event and a snapshot carry the instance id.
_Avoid_: incarnation, generation

**Turn**:
One pass of the loop: build context, call the provider, run tool calls, repeat until the provider stops. A session runs one turn at a time.
_Avoid_: run, step, iteration

**Hands**:
The process that owns a working directory and runs tools for a session. In local mode it lives on the same node as the session. It may live on another node.
_Avoid_: sandbox, executor, worker

**Client**:
Anything that renders a session from its events and sends prompts to it. A client holds no session state.
_Avoid_: frontend, UI, view

**Program turn**:
A turn that a harness provider's program starts by itself, for example when a background task ends. The session shows it as a turn with no user message, marked with `origin: :program` in its `turn_start`.
_Avoid_: background turn, notification turn

**Steer**:
A message delivered inside the current turn, before the next provider call. On an external turn, it aborts the turn and starts a new one with the message.
_Avoid_: interrupt, inject, interject

**Follow-up**:
A message delivered as a new turn after the current turn ends.
_Avoid_: queue, pending prompt, next

**Abort**:
Ending the current turn now. Queued steers and follow-ups are dropped.
_Avoid_: cancel, stop, kill

## Providers

**Provider**:
A plugin that produces assistant messages for a session. A provider has a local turn or an external turn (`turn/0`). On a local turn, Helyx runs the turn and the tools. On an external turn, the provider runs the whole turn and its own tools in one call.
_Avoid_: backend, model, LLM, driver

**Model provider**:
A provider that calls a model API. Helyx runs the turn and the hands run the tools.
_Avoid_: API provider, native provider

**Harness provider**:
A provider with an external turn. It drives an external agent program, such as Claude Code or Codex. The external program runs its own loop and its own tools. Helyx records the result.
_Avoid_: subprocess provider, CLI provider, wrapper

**Harness session**:
The external program's own conversation, named by an id the program issues. Helyx stores the id so it can resume the harness.
_Avoid_: thread, external session, subprocess session

**Model ref**:
The string that names a model for a session, in the form `provider/model`. The prefix selects the provider plugin.
_Avoid_: model id, model name, model string

## Transcript

**Transcript**:
The ordered record of a session: messages and session entries. Append-only.
_Avoid_: history, log, messages, context

**Message**:
One of user message, assistant message, or tool result message. A message holds content blocks.
_Avoid_: entry, turn, chat message

**Content block**:
One of text, thinking, tool call, or image. The provider-neutral unit of message content.
_Avoid_: part, chunk, segment

**Entry**:
One line of a session file. A message or a session record such as a model change. Every entry has an id and a parent id.
_Avoid_: record, row, event

**Context**:
The messages a provider sees on one call, derived from the transcript by the model context plugin.
_Avoid_: prompt, window, history

**Compaction**:
Replacing older transcript content with a summary so the context fits the model.
_Avoid_: summarization, pruning, truncation

## Events

**Event**:
A fact emitted by a session that clients render from. Every event carries the session id, the session instance id, and a sequence number within the instance.
_Avoid_: message, notification, update

**Tool**:
A plugin that the hands can run on behalf of a session. A tool has a name, a description, a parameter schema, and an execute function.
_Avoid_: function, action, command, capability
