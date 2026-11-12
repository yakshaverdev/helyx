# A session picks its ModelContext

Ticket #854, part of #853.

## Goal

A session picks the ModelContext plugin that builds its system prompt when it starts, as it picks its tool set with `:tools` (`agent-tool.md`). A product that registers a coding context and a coordinator context then runs both kinds of session in one Core. Without the option, it needs one Core or one product for each prompt.

Decisions (ticket #854, orchestrator run, owner away):

1. **`Helyx.ModelContext` becomes `mode: :multi`.** Before this change the interface was `:single`, and Core refused to start with two ModelContext plugins (`{:mode_violation, Helyx.ModelContext, plugins}`). The ticket and its roadmap (#853: "a session picks its ModelContext as it picks its `:tools`") need two, so Core now takes any number. The first one in registration order (`Helyx.Core.plugins/2`) is the default. A Core with one or no ModelContext behaves as before. `Helyx.Compaction` and `Helyx.Memory` stay `:single` (see "Out of scope").
2. **The start option `:model_context`.** `Helyx.Session.start/2` and `Helyx.Sessions.start/2` take `:model_context`, the module of a ModelContext plugin that the Core registered. nil or no option gives the default of decision 1, so every existing caller keeps its behaviour. Any other value, such as a module that the Core did not register as a ModelContext, a string, or an Erlang module, gives `{:error, :invalid_model_context}`. The check runs after the check of `:tools` and before the tool specs, so nothing is created. That is the same place as for `:invalid_tools`. Reason: the session resolves its plugins once at its start (`session-stream.md`), so the option only changes which module the session resolves.
3. **A mode is a product construct.** A mode is a name that a product maps to a `:model_context` and a `:tools` list. Core knows only the two options. The product owns the names, and so will `Helyx.Hub` later (#857). Core gets no mode registry.
4. **A resume gives the default.** As with `:tools`, the session header does not keep the option, and `Helyx.Session.resume/2` does not take it. A resumed session, child or not, gets the default ModelContext of its Core. A resume that attaches to a running session gets that session as it runs, with its own ModelContext. Reason: this matches `:tools` (`agent-tool.md`, "A resume gives all tools of the Core"). If the header kept the option, it would also need a format for the module name, and a policy for a name that a later Core does not register. Accepted hole: the user who resumes a coordinator session gets the default prompt.
5. **A child gets the parent's ModelContext.** `Helyx.Tool.context/0` gains `model_context`: the ModelContext plugin of the session that runs the call, or nil when the Core has none. `Helyx.Tool.Agent` gives it to `Helyx.Sessions.start/2` as `:model_context`. A child of a coordinator session therefore gets the coordinator prompt, and decision 2 of `agent-tool.md` still holds: the same ModelContext plugin builds the system prompt of the child. The start of the child checks the module again, as any start does. A parent that was resumed passes its default.

## Interface changes

- `Helyx.ModelContext`: `use Helyx.Interface, mode: :multi`. A Core with two ModelContext plugins starts.
- `Helyx.Session.start/2` and `Helyx.Sessions.start/2`: the option `:model_context`, `module() | nil`. Error: `{:error, :invalid_model_context}`.
- `Helyx.Tool.context/0`: the new key `model_context: module() | nil`.
- `Helyx.Tool.Agent`: the child starts with `model_context: context.model_context`.
- `Helyx.ModelContext`: the optional callback `user_text/2`, which replaces the text of a user message of the user origin before the session checks it (`docs/features/skills.md`, decision of 2026-11-11). The call runs in the caller of `Helyx.Session.prompt/3`, `steer/3`, and `follow_up/3`, with `:core`, `:session_id`, and `:cwd`.

## Replaced mechanism

1. The session picked `List.first(Helyx.Core.plugins(core, Helyx.ModelContext))` in `Helyx.Session.Server.Open.start_child/3`. After this change, the start (`Helyx.Session.start/2`) checks the option in `Helyx.Session.Input.start_options/2` and puts the module, or nil, into the state. `start_child/3` keeps a module and resolves nil to the first one as before; a resume puts nil, so it gets the first. With no option, the session picks the same module as before.
2. Removed check: Core refused two ModelContext plugins. The row "two model context plugins" of the refusal table in `test/helyx/core_test.exs` is gone; the test "boots with two model context plugins and lists them in registration order" checks that the Core starts and lists both, in order. The `:single` rule still applies to `Helyx.Compaction` and `Helyx.Memory`, and the rows of those tests stay.
3. Users see one change: a product can register several ModelContext plugins. A product that registers two by mistake is no longer refused at start, and its sessions get the first one.
4. No new state without a bound: the option is one atom in the plugins map of the session state.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| `:model_context` | nil, or an atom in `Helyx.Core.plugins(core, Helyx.ModelContext)` | `{:error, :invalid_model_context}`, before any file or process | `Helyx.Session.Input.start_options/2` |
| ModelContext plugins of a Core | the plugin list of the Core; no bound of its own, as for Tool | n/a | `Helyx.Core.Plugins` |

The check compares the value with the registered modules (`Enum.member?/2` on the plugin list) and does not load or call the module. An atom that a client gives as a string never reaches the check, because the wire has no field for it (see "Out of scope").

## Ownership

None: the option creates no external resource.

## Out of scope

- **The wire field.** The wire `start` op stays `cwd` and `model` (`wire-protocol.md`). It rejects any other key with `bad_params` (`test/helyx/transport/web_socket_test.exs`, "an unknown op, a bad param, and an unknown key get their errors"), so a client over the wire gets the default ModelContext. A field for the mode is a protocol bump. Ticket #855 writes the conformance fixtures of protocol 3 at the same time, and a bump would make them stale. The field, its name-to-module map in the product, and a TUI `--mode` come in a later slice, with the product that defines modes.
- **The option on resume, and in the header** (decision 4).
- **A per-session Compaction or Memory plugin.** The shape would be the same, but nothing needs it yet. Both interfaces stay `:single`.
- **A mode registry in Core** (decision 3).
- **A mode that changes during a session** (#473 covers the tool set).
