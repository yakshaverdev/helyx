# The approval gate

Ticket #882, follow-up 4 of ADR 0013 (`docs/adr/0013-hooks.md`, §7); it replaces the gate of #503. The ADR holds the decisions and their reasons: the gate is a hook plugin on `before_tool`, it asks with `Helyx.Hook.ask/1` and an `approval` UI block, it denies at once with no answerer, its limit bounds the wait, and an abort ends the ask. This doc sets what the ADR leaves to it: the rule shape, its matching, the default rule, the request and its answer, and the TUI renderer.

## Goal

A product adds `Helyx.Hook.Approval` to its plugin list, and each tool call, a Helyx tool call or a call of a provider's own tool that the provider asks about (#881), is allowed, denied, or sent to the user by a rule of the config. The TUI shows the call and the user allows or denies it; with no client that can answer, the call is denied at once and the model reads why. Every answer is a `hook` entry of the session file (ADR 0013 §6), so the user can later see what was allowed and why.

## Interface changes

### Config

The plugin reads the application env key `:approval_hook` of `helyx_plugins` (AGENTS.md, "Module naming"):

```elixir
config :helyx_plugins, :approval_hook,
  rules: [
    [tool: "read", action: :allow],
    [tool: "bash", action: :ask],
    [tool: "fileChange", provider: "codex", action: :ask]
  ],
  default: :ask,
  limit_ms: 600_000
```

- The value is a keyword list of `rules`, `default`, and `limit_ms`, each at most once and each optional. An unset env key, and a key that the list leaves out, give the default; a key that is there has a value of its type, so `nil` is a broken config (below), except for `provider`.
- `rules` is a list of rules, `[]` by default. A rule is a keyword list: `tool`, the tool name, a string, required; `provider`, nil or a provider id, a string, nil by default; and `action`, `:allow`, `:deny`, or `:ask`, required. A rule with `provider` nil names a Helyx tool; a rule with a provider id names a tool of that provider's own, which reaches the gate through an approval request of the provider (`docs/features/hooks.md`, "Harness approvals").
- **Matching.** A rule matches a call when its `tool` is the call's tool name and its `provider` is the call's `provider`. When several rules match, the strictest wins: `:deny`, then `:ask`, then `:allow`. Prior art: Claude Code checks its deny rules first, then ask, then allow (`settings.json` `permissions`), so a deny that a user adds anywhere holds. opencode prompts per command (`docs/research/coding-tools.md`, "Sandbox"); a rule by a pattern of the arguments is out of scope here.
- `default` is the action of a call that no rule matches: `:allow`, `:deny`, or `:ask`, `:ask` by default. Reason: a product adds the gate to gate calls, and a gate that lets unnamed calls through when its config is missing fails open.
- `limit_ms` is the limit of the hook at `before_tool`, 600,000 by default, the most that Core allows: the wait for a person (ADR 0013 §3), and the abort ends it sooner. `limit/1` gives it as the config has it, so Core refuses a bad one at its start (`{:invalid_hook_limit, Helyx.Hook.Approval}`), as for the command hook (`docs/features/command-hook.md`); a top that is not a keyword list gets the default there, and fails at each run.
- **A broken config.** The config is read and checked at each run, the whole value, which is small and of the config, not of the model. A top that is not of this shape, a rule that is not, an unknown key or a key twice, a missing `tool` or `action`, or a value of another type (`nil` is no value, except for `provider`, where nil names a Helyx tool) is a failed hook: `before_tool` denies the call (ADR 0013 §5) with the reason `its config :approval_hook is invalid: <path>`, where the path names the first bad value, such as `[:approval_hook, :rules, 0, :action]`, with the index of the rule.
- **The flag of a sandboxed run** (the owner decision on #503 of 2026-10-13, from #491: "a flag, which this ticket's feature doc names, allows all calls for sandboxed runs") is `default: :allow` with no rule: every call, of a Helyx tool or of a provider's own tool, is then allowed with no ask. A product that runs sandboxed can also leave the gate out of its plugin list.

### The answers

| Action | Answer of `before_tool/1` |
|---|---|
| `:allow` | `{:allow, "the rule for <tool> allows the call"}`, or `{:allow, "no rule names <tool>, and the default allows the call"}` |
| `:deny` | `{:deny, "the rule for <tool> denies the call"}`, or `{:deny, "no rule names <tool>, and the default denies the call"}` |
| `:ask`, the answer `%{"decision" => "allow"}` | `{:allow, "the user allowed the call"}` |
| `:ask`, the answer `%{"decision" => "deny"}` | `{:deny, "the user denied the call"}` |
| `:ask`, any other answer | `{:deny, "the answer of the client was not an allow or a deny"}` (ADR 0013 §7: any other answer is a deny) |
| `:ask`, `{:error, :no_client}` | `{:deny, "no user can approve the call in this run: no client that can answer is attached, as in a print run or the session of a sub-agent; try another way"}` (#491: the model can try another way) |
| `:ask`, `{:error, :not_running}` | `{:deny, "the call no longer runs"}` |

`<tool>` is the tool name, with ` of <provider>` for a call of a provider's own tool. Core gives a deny to the model as `the hook Helyx.Hook.Approval denied the call: <reason>` and writes every answer, an allow too, as a `hook` entry, the reason cut at 4,096 bytes (`docs/features/hooks.md`). A hook killed at its limit, while the user has not answered, is a failed hook, and the call is denied (ADR 0013 §5); the session ends its ask with `ask_end` `ended`. An abort ends the hook and its ask with the call.

### The request: an `approval` UI block

The request of the ask is an `approval` UI block (`docs/features/ui-blocks.md`, "The vocabulary"):

```json
{"kind": "approval", "text": "allow bash?", "tool": "bash", "provider": null,
 "arguments": "{\"command\":\"mix test\"}"}
```

- `tool` is the tool name, `provider` nil or the provider id, each cut at 256 bytes at a character boundary.
- `arguments` is the JSON text of the arguments as Core checked them, cut at 16,384 bytes at a character boundary. A text, not an object, so a cut keeps one shape.
- `text` is `allow <tool>?`, or `allow <tool> of <provider>?`, with the cut tool and provider.
- `cut` is `true` when one of the three was cut, as ADR 0011 §2 asks of an emitter that cuts its own block; absent otherwise.

The worst case is under the 65,536 bytes of JSON of an ask request (`Helyx.Session.Ask`): the arguments text holds no control character, since the JSON encode escaped each, so its escape at most doubles it, 32,770 bytes; `tool` and `provider` are at most 1,538 bytes each with every byte a control character, and `text` holds both; with the keys, under 40,000 bytes.

### The TUI renderer

The TUI shows the oldest open ask that it can answer in the place of the composer (`Helyx.TUI.Question`): a `form`, or an `approval` whose `tool` and `arguments` are strings and whose `provider` is nil or a string. The approval picker (`Helyx.TUI.Approval`):

- Its title is the `text` of the block (`allow bash?`), cut at 1,024 bytes and made one line. Its body is the arguments text, cleaned (`Helyx.TUI.Wrap.sanitize/1`) and wrapped at the box width, at most 8 rows; then a dim row `… more arguments` when a part of the arguments is left out, by the 8 rows, by the room of the screen, or by a cut (`cut` true, or the bound of the picker below); then two options: `Allow` and `Deny`.
- The room goes first to the dim row and the two options, then to the arguments rows, and the dim row is decided after the arguments rows are cut to the room. The picker asks for at least 5 rows (its borders, the dim row, and the options; `Helyx.TUI.Composer.fit/2` with a least of 5), so both options show and a hidden part is marked. On a screen too short for that, where the layout gives it fewer rows, the two options share one line, and with one row inside the box the dim row joins that line.
- Up and Down move between the two, Enter sends the one under the cursor, `y` sends allow and `n` deny. Escape aborts the turn, as with the form picker. A sent answer shows `answer sent` until its `ask_end`.
- The picker keeps the first 16,384 bytes of the arguments text, the bound of the gate's own request, so a block of another emitter, up to the 65,536 bytes of an ask, wraps at most twice that in a frame: once for the rows of the layout, and once for the draw.
- An `approval` whose fields the TUI cannot read shows its `text` under its call, and the TUI gives no answer, as for a kind that it does not know (`docs/features/ui-blocks.md`, "Rendering in the TUI").

## Replaced mechanism

1. The gate of #503 was never built: no tool call asked anyone, and a Codex approval request with no `before_tool` hook is denied (ADR 0013 §4). With the gate in the plugin list, each call gets an answer of its rules; without it, nothing changes.
2. The TUI picker: `Helyx.TUI.Question.sync/1` opened only a `form`; it now opens the oldest ask that is a `form` or an `approval` that it can read. The field `question` of the TUI state holds either picker. The form tests keep their property; the new tests are in `plugins/bundled/test/helyx/tui/approval_test.exs`.
3. A user sees the approval picker where before an `approval` ask showed its `text` under its call.
4. Test: `plugins/bundled/test/helyx/tui/ui_blocks_test.exs`, "a kind that the TUI does not know shows its text under its call and gets no picker", sent an ask of the kind `approval` with no `tool` and no `arguments` as a kind that the TUI did not know. The TUI knows `approval` now, so the test sends the kind `confirm` and keeps its property; an `approval` whose fields the TUI cannot read is tested in `plugins/bundled/test/helyx/tui/approval_test.exs`.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| the wait for the user | the hook's limit, `limit_ms`, 1 to 600,000 ms, default 600,000, checked at Core start | killed by the hands: a failed hook, the call is denied, the ask ends | Core (`docs/features/hooks.md`) |
| `tool`, `provider` in the request | 256 bytes each | cut at a character boundary, `cut: true` | `Helyx.Hook.Approval` |
| `arguments` in the request | 16,384 bytes of JSON text | cut at a character boundary, `cut: true` | `Helyx.Hook.Approval` |
| the request | under 40,000 bytes of JSON, by the cuts above; the ask bound is 65,536 | not reachable | `Helyx.Session.Ask` checks it |
| an answer | 16,384 bytes of JSON, the answer bound of Core | `{:error, :invalid_answer}` to the client | `Helyx.Session.check_answer/1` |
| the config | read at each run: three top keys, the rules a list of the config, not of the model | a failed hook: the call is denied | `Helyx.Hook.Approval` |
| the arguments text that the TUI picker keeps | 16,384 bytes | the rest is left out, with a dim row | `Helyx.TUI.Approval` |
| the title of the picker | 1,024 bytes of the `text` of the request, then one line | cut at a character boundary | `Helyx.TUI.Approval` |
| the rows of arguments in the picker | 8, and the room of the screen after the dim row and the two options; the picker asks for at least 5 rows (`Helyx.TUI.Composer.fit/2` with a least of 5) | the rest is left out, with the dim row | `Helyx.TUI.Approval` |

## Ownership

None: the gate holds no external resource. The ask is the session's, and the hook Task is the hands' (`docs/features/hooks.md`).

## Out of scope

- An allow for the rest of the session ("don't ask again"), and a note of the user with a deny: Claude Code and Codex have both; each is a later kind or answer field, and a later ticket.
- Rules by a pattern of the arguments, such as a command prefix of `bash`; a rule names a tool.
- An automatic reviewer, and a sandbox (ADR 0013 §7).
- The rendering in the client kit (#860) and the GPUI app (#885).
- The gate in the plugin list of the coding agent (`apps/coding_agent`), with a config file for its user: the coding agent has no hook plugin and no user config today.
