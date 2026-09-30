# External turn

> Superseded on 2026-09-30 (#265, ADR 0002 amendment): the per-turn `:external` mode, `turn/0`, and `{:bad_provider_turn, id}` are removed. A provider has a local turn or is connected.

## Goal

Replace the provider `kind` (`:model` or `:harness`) with one flag that names the behaviour: `turn: :local` or `turn: :external`. With an external turn, the provider runs the whole turn and its own tools in one call. Core then decides on what a provider does, not on the word "harness". Issue #123, from the Core cleanup plan (`docs/reviews/2026-09-26-core-cleanup-plan.md`).

The owner decided on 2026-09-26 (comment on #123):

- One flag, not separate capabilities. Today the four behaviours below always go together: ClaudeCode and Codex have all four, and the OpenAI provider has none. Separate capabilities would allow 16 combinations, and only 2 are real. A split comes when a provider needs one behaviour alone, for example an API with server-side tools (behaviour 2), a stateful API such as a `previous_response_id` (behaviour 3), or a local model process (behaviour 4). All the branches are then in one place, so that split is mechanical.
- The steer on an external turn does not change: it aborts the turn and starts a new turn with the steer text.

This is a rename of the decision, not a change of behaviour. The events, their order, the transcript, and the session file do not change.

## What `turn: :external` switches

| # | Behaviour | Where, after #120 |
| --- | --- | --- |
| 1 | A steer aborts the turn and starts a new turn with the steer text | `handle_call({:steer, _}, ...)` in `Helyx.Session.Server` |
| 2 | Tool calls arrive with their results; the session records them and does not run them. A call with no result at the end gets an aborted result | `end_turn/2` in `Helyx.Session.Server`; the `:message_end` and `:tool_result` events in `consume/4` of `Helyx.Session.Stream` |
| 3 | The provider keeps its own conversation state: the session stores its id and passes `:harness_session_id` on the next call | `call_provider/1` in `Helyx.Session.Server` (`Transcript.resumable/3`, the option); the `:harness_session` event in `Helyx.Session.Stream` |
| 4 | The stream runs as a Task of the hands, so its OS processes are held and released there (ADR 0003, ADR 0004) | `start_stream/3` in `Helyx.Session.Server` |

## Interface changes

`Helyx.Provider`:

```elixir
@callback turn() :: :local | :external
@optional_callbacks turn: 0, release: 3

@spec turn(module()) :: {:ok, :local | :external} | :error
```

- `turn/0` replaces `kind/0`. It is optional, and the default is `:local`. `Helyx.Provider.turn/1` replaces `Helyx.Provider.kind/1`, with the same rule: a `turn/0` that raises, throws, exits, or returns another value is an error, and the session calls it in the same place.
- The error `{:bad_provider_kind, provider_id}` of `Helyx.Session.start/2`, `resume/2`, and `set_model/2` becomes `{:bad_provider_turn, provider_id}`.
- The `Helyx.Provider` moduledoc describes an external turn by the four behaviours in the table, not as "a harness provider".
- `Helyx.Provider.ClaudeCode` and `Helyx.Provider.Codex` define `turn/0` as `:external` in place of `kind/0` as `:harness`.

`Helyx.Session.Server` and its modules, all internal:

- The `kind` field of `State` and of `Helyx.Session.Turn` becomes `turn_mode`, with the values `:local` and `:external`.
- The `harness?` key of `Helyx.Session.Stream.run/1` becomes `external?`.
- The five branches (the steer, `call_provider/1`, the two clauses of `start_stream/3`, and `end_turn/2`) and the guard in `consume/4` read `:external` and `:local`.

The old names are removed, with no alias and no delegate. Every caller is in this repository.

## What keeps the word "harness"

These names are data, not decisions. They stay, because a rename changes the session file format (ADR 0001) or the event contract of the clients:

- the stream event `{:harness_session, id, cut}`, the event type `:harness_session`, and its data keys
- the session file entry `harness_session`, `Helyx.Session.File.append_harness_session/3`, and `Helyx.Message.harness_id?/1`
- the provider option `:harness_session_id`, and the `harness_sessions` field of the session state
- `Helyx.HarnessIO`, a helper of `plugins/bundled`, not Core
- the product term "harness provider" in `CONTEXT.md` and in the docs of ClaudeCode and Codex

A rename of these to a neutral name (for example `provider_session`) is a separate decision with a file format migration, and it is out of scope.

## Bounds

No new input, buffer, or wait. Every bound of the harness rows in `docs/features/coding-agent.md` applies to an external turn with no change. The rows that name the provider kind name the turn flag.

## Ownership

No new resource. The row "provider stream Task" does not change: a local turn's stream is a Task of the Core task supervisor, and an external turn's stream is a Task of the hands. The rows "Claude Code program" and "Codex program" do not change.

## Tests

- The session tests, the stream tests, and the provider tests pass with no change to their assertions, except the names that this doc renames: `kind` to `turn`, `:model` to `:local`, `:harness` to `:external`, `harness?` to `external?`, and `:bad_provider_kind` to `:bad_provider_turn`.
- The test providers in `test/support/interfaces.ex` change with them: `Helyx.Test.Harness` defines `turn/0` as `:external`; `BadKind` and `RaisingKind` become `BadTurn` and `RaisingTurn`, with the ids `bad_turn` and `raising_turn`.
- A test shows that a provider with no `turn/0` gets a local turn.
- `grep -rn "kind" lib/helyx/session.ex lib/helyx/session/ lib/helyx/interfaces/provider.ex` finds no provider kind, and `grep -rn ":harness\b\|harness?" lib/helyx` finds no branch.

## Docs

- ADR 0002 gets a `## Revision` section, in the style of ADR 0004, with this text (approved by the owner on 2026-09-26):

  > 2026-09-26: The two provider kinds are now one flag named by behaviour, `turn/0`: `:local` (the default) or `:external`. An external turn runs the whole turn and its own tools in one provider call. The session records the tool results and does not run the tools. The provider keeps its own conversation state, which the session resumes by id. The stream runs under the hands. A steer aborts the turn. Claude Code and Codex have external turns. The reasons of this decision do not change. The product term "harness provider" stays and names a provider with an external turn (#123).
- `CONTEXT.md`: the entry **Provider** says that a provider has a local or an external turn. The entry **Harness provider** stays as the product term, and says that it is a provider with an external turn. The entry **Steer** says "an external turn" in place of "a harness turn".
- `docs/features/coding-agent.md`: each sentence that decides on "a harness provider" or "a harness turn" says "an external turn", where the sentence is about the decision of Core. Sentences about ClaudeCode or Codex keep their names.

## Known gap

An abort of an external turn closes the turn at once. A tool result that finished before the abort but arrives after it shows as `aborted` in the transcript and the session file. An example is the result of a Codex command of a sent message, when its line is still in the pipe at the abort. A Codex held result is lost in a different way: its call is in a held message, and the held messages never reach the transcript (`docs/features/coding-agent.md`, the Codex paragraph). In both cases the program's own thread keeps the real result, and the next turn resumes that thread. Accepted (#112).

## Out of scope

- Separate capabilities for the four behaviours (see Goal).
- A rename of the `harness_session` data names (see "What keeps the word harness").
- A steer that waits for the end of an external turn.
