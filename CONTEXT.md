# Helyx

Helyx is an Elixir substrate for agent-native, stateful products. This glossary fixes the words used in code, docs, issues, and tests.

## Components

**Core**:
The part of Helyx every product needs: plugin registration, OTP supervision, and interface dispatch.
_Avoid_: framework, kernel, runtime

**Interface**:
A behaviour that plugins implement. It declares a mode: single, at most one plugin, or multi, any number.
_Avoid_: extension point, slot, contract

**Plugin**:
A module that implements an interface.
_Avoid_: extension, adapter, integration

**Product**:
Independent software built on Helyx. It selects plugins and owns its domain code.
_Avoid_: app, application, host

## Runtime

**Session**:
One conversation with one agent, named by its session id. When it is saved to disk, its session file stores it. Each start of its process is a session instance.
_Avoid_: conversation, chat, thread, agent

**Session instance**:
One start of a session process. It owns the transcript, the queues, and the current turn. A resume keeps the session id and makes a new instance, and two Cores can hold one session id with two instances. An event and a snapshot carry the instance id.
_Avoid_: incarnation, generation

**Turn**:
The work from one turn start to its turn end. A turn ends done, aborted, or failed; a session that stops during a turn ends it with no turn end. A session runs one turn at a time.
_Avoid_: run, step, iteration

**Prompt**:
The user messages that open a turn.
_Avoid_: input, query

**Snapshot**:
The session state that a client gets when it subscribes, valid at one sequence number of the session instance.
_Avoid_: state dump, sync

**Hands**:
The process that owns a working directory, runs tools for a session, and hosts the provider process. In local mode it lives on the same node as the session. It may live on another node.
_Avoid_: sandbox, executor, worker

**Client**:
Anything that renders a session from its snapshot and events and sends prompts to it. A client holds only a rendered copy of the session state. A bundled client, such as the TUI, implements no interface.
_Avoid_: frontend, UI, view

**Provider turn**:
A turn that a provider starts by itself, for example when a background task ends. The session shows it as a turn with no user message, and its turn start names the provider as its origin.
_Avoid_: background turn, notification turn

**Steer**:
A message delivered inside the current turn, before the next model call. The provider takes it at its next model call, at most once.
_Avoid_: inject, interject

**Follow-up**:
A message delivered as a new turn after the current turn ends.
_Avoid_: queue, pending prompt, next

**Abort**:
Ending the current turn now. Queued steers and follow-ups are dropped.
_Avoid_: cancel, stop, kill

## Providers

**Provider**:
A plugin that produces assistant messages for a session. It runs in its provider process. It is a model provider or a harness provider.
_Avoid_: backend, model, LLM, driver

**Provider process**:
The process in which a provider runs for one session. The hands host it. It lives across turns. It ends when it fails, when the session ends, or when it closes. It closes when it is idle and agrees to close, or when its model is not the model of the session and no turn and no wait runs.
_Avoid_: provider task, provider worker

**Model provider**:
A provider that calls a model API. Helyx runs the turn: the hands run the tools, and when each tool call of an answer has a result, Helyx calls the model again. An answer with no tool calls ends the turn, unless the provider holds a steer for the next model call.
_Avoid_: API provider, native provider

**Model call**:
One request to the model and its answer. A turn of a model provider makes zero or more model calls.
_Avoid_: turn, round, step

**Harness provider**:
A provider that drives an external agent program, such as Claude Code or Codex. The external program runs its own loop and its own tools, and can ask Helyx to run Helyx tools. Helyx records the result.
_Avoid_: subprocess provider, CLI provider, wrapper

**Stream event**:
A fact that a provider sends to the session during a turn, such as a delta, a tool call, a tool result, a Helyx tool request, or a terminal event. Core checks each one before the session uses it.
_Avoid_: chunk, provider message

**Terminal event**:
The stream event that ends a turn: done, or an error.
_Avoid_: final event, stop event

**Helyx tool request**:
A stream event in which a provider asks the session to run one Helyx tool call on the hands.
_Avoid_: tool callback, remote tool call

**Withdraw**:
The provider takes back one Helyx tool request of the running turn. A withdrawn call that has no result yet gets an aborted result.
_Avoid_: cancel, revoke

**Interrupt**:
The provider part of an abort: the session asks the provider to end the turn.
_Avoid_: cancel, stop

**Resume id**:
The id that a provider gives for its own conversation state. Helyx keeps it with the session, and in the session file when there is one. It gives the id to a later provider process when the transcript shows that the process can continue that state. Otherwise the process starts fresh.
_Avoid_: harness session, thread, external session

**Model ref**:
The string that names a model for a session, in the form `provider/model`. The prefix is the provider id, and the rest is the model.
_Avoid_: model id, model name, model string

**Provider id**:
The prefix of a model ref, which selects the provider plugin. It is durable: the session file keys resume ids by it.
_Avoid_: provider name, provider key

**Model**:
The part of a model ref after the first slash.
_Avoid_: model name, engine

## Transcript

**Transcript**:
The ordered messages of a session. Append-only.
_Avoid_: history, log, messages, context

**Message**:
One of user message, assistant message, or tool result message. A message holds content blocks.
_Avoid_: entry, turn, chat message

**Content block**:
One of text, thinking, tool call, or image. The provider-neutral unit of message content.
_Avoid_: part, chunk, segment

**Entry**:
One line of a session file. A message or a session entry such as a model change. Every entry has an id and a parent id.
_Avoid_: record, row, event

**Context**:
What a provider sees on one call: the system prompt, the messages, and the tool specs. The session builds it from the transcript, and the model context and compaction plugins can change it. A harness provider may use only the messages.
_Avoid_: prompt, window, history

**Compaction**:
Shrinking the context of one provider call so it fits the model. The transcript does not change.
_Avoid_: summarization, pruning, truncation

## Events

**Event**:
A fact emitted by a session that clients render from. Every event carries the session id, the session instance id, and a sequence number within the instance.
_Avoid_: message, notification, update

**Tool**:
A plugin that the hands can run on behalf of a session. A tool has a name, a description, and a parameter schema.
_Avoid_: function, action, command, capability
