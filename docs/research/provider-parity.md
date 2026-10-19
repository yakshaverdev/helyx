# Harness programs with the product's prompt, exact tools, and no user config

Date: 2026-10-17. Ticket #651. Versions: Claude Code 2.1.302 (`/opt/homebrew/bin/claude`), codex-cli 0.163.0 (`~/.bun/bin/codex`, the first `codex` on the `PATH` of the run), on macOS (Darwin 25.6.0). The runs were in temporary folders outside the repository. The observations are of these versions, not a contract.

## Method

- **Local model servers.** Most runs sent no request to a real model. A local Python HTTP server took the place of the model API and wrote the body of each request to a log (never the headers). For Claude Code, `ANTHROPIC_BASE_URL` named it, and it answered a canned stream: a text `ok`, or one `tool_use` of `mcp__helyx__bash` and then `ok`. For Codex, `-c model_provider=fake` with `[model_providers.fake]` (`wire_api = "responses"`), or `-c openai_base_url=...` with `--disable enable_request_compression` to keep the built-in provider and its hosted tools; it answered a text `ok`, or one `exec` call that returns `ALL_TOOLS` (the method of `docs/research/harness-shell-off.md`).
- **Drivers.** A Python script drove each program over stdio as the Helyx provider does: Claude with the stream-json flags of `Helyx.Provider.ClaudeCode` and the SDK MCP server `helyx` (one tool `bash`), and Codex with `initialize` (`experimentalApi`), `thread/start` with `approvalPolicy` `never`, `sandbox` `danger-full-access`, and the dynamic tool `bash`, then `turn/start`.
- **Sentinels.** Each work folder had a `CLAUDE.md` and an `AGENTS.md` with a marker text, a project `.claude/settings.json` with a `SessionStart` and a `UserPromptSubmit` hook that each touch a marker file, a project skill in `.claude/skills` and `.agents/skills`, and a project `.mcp.json` server that touches a marker file when it starts. The user's own setup of the run machine served as a second set: a global `CLAUDE.md`, installed Claude plugins (one with a `SessionStart` hook that injects text), user MCP servers, a `~/.codex/AGENTS.md`, Codex plugins and hooks, and a `[mcp_servers]` table in `~/.codex/config.toml`.
- **Real inference.** Five turns in total, with the cheapest models (Claude `haiku`, which reported `claude-haiku-5-5`; Codex `gpt-5.6-luna`): R1 to R3 below, and the two turns of "Edit quality". Claude reported `total_cost_usd` 0.000239, 0.000181, 0.001445, and 0.000602: USD 0.0025 together, billed to the subscription. The Codex turn used 2,584 tokens (2,579 in, 5 out), billed to the ChatGPT plan.

## Claude Code

### The request today

With the flags of `Helyx.Provider.ClaudeCode` today (no isolation), the request had the full native coding prompt (9,344 characters of `system`), 29 built-in tools, the tools of the user's MCP servers (a user server and a claude.ai connector), and `mcp__helyx__bash`. It held the text of the project `CLAUDE.md`, the user's `CLAUDE.md`, the plugin hook text, and the skill lists. Both project hooks ran, and the project MCP server started.

### Isolation

Two flag sets, each with `--tools=` (no built-in tool) and the product prompt:

- A: `--safe-mode`.
- B: `--setting-sources=` and `--strict-mcp-config`.

For both, the request was the same: `tools` held only `mcp__helyx__bash`, no sentinel text was in the body, no marker file was made, and the `init` line listed only the MCP server `helyx`. The differences were in the `init` line only: A listed the user's installed plugins in `plugins`, B listed only the three built-in plugins (`cc-plugin-agents-md`, `cc-plugin-telemetry`, `cc-plugin-plugin-authoring`). Both listed the bundled skills in `skills` and `slash_commands`; the request had no `Skill` tool to call them. Help text: safe mode keeps admin-managed (policy) settings, and `--setting-sources` keeps managed settings and `--settings`.

What every request still had, in both sets (residuals):

- `system` starts with two blocks of the program: a billing header line (`x-anthropic-billing-header: cc_version=...; cc_entrypoint=sdk-cli;`) and the line `You are a Claude agent, built on Anthropic's Claude Agent SDK.`. The product prompt is the third block.
- The first user message starts with a `<system-reminder>` that gives the email address of the signed-in account as context.
- A message with the role `system` after the first user message holds an `# Environment` section: the working directory, whether it is a git repository, the platform, the shell, the OS version, the model name and its knowledge cutoff, the date, and a rule about downloaded files.
- `thinking` `adaptive` and `output_config.effort` `medium`.

R1 (real, flags B): the model called `mcp__helyx__bash` with `echo hi`, got the result from the driver, and answered with it. The OAuth login of the subscription worked, and the SDK MCP server worked with `--tools=`. R2 (real, flags A, one word): the login worked.

### The prompt

- `--system-prompt=<text>` replaced the native prompt (the third block above). `--system-prompt=` (empty) left only the two program blocks.
- `--help`: `--system-prompt-snapshot <on|off>`, default `on`, records the prompt at the first request of a conversation and sends the record on every later request and resume "even when a later launch passes different text, until the conversation is compacted". `off` renders the prompt fresh on every request.
- One program, `--system-prompt-snapshot=off`: two turns (the first with a tool call), `/compact`, and one more turn. Every request, the compaction request included, had the launch prompt.
- Resume (`--resume=<id>`) with a new `--system-prompt`: with `off` at both launches, the request had the new prompt. With the default at both launches, it had the old prompt. A conversation recorded with the default, resumed with `off`, had the new prompt.
- The control request `initialize` with `systemPrompt` (first line on stdin, before the first user line) gave the request that prompt, also over `--system-prompt=`. On a resume with `off`, a new `initialize` prompt replaced the old one. The response was `success` with the `commands` list. A `systemPrompt` that was not a string (`42`) also got `success`, and the request then had the `--system-prompt=` value (empty).
- `--system-prompt-file=<path>` also worked; the help names it only in the text of `--bare`.

### Resume of a conversation from before the isolation

A conversation started with today's flags, resumed with flags B and a new prompt: the request had the new prompt and only `mcp__helyx__bash`, but the earlier messages still held the project `CLAUDE.md`, the user's `CLAUDE.md`, the plugin hook text, and the skill list. The program stores the injected context in the conversation.

### A hook before each model call

Not run. The hook event names in the program binary are `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `UserPromptSubmit`, `SessionStart`, `Stop`, `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact`, `PermissionRequest`, and `Notification`. None names a model call. `PostToolBatch` and `PostToolUse` come after tool results and before the next model call of the same turn, and `UserPromptSubmit` before the first. Whether the SDK `hook_callback` path works with `--setting-sources=` was not checked.

## Codex

### The request today

With the flags of `Helyx.Provider.Codex` today, the request had no top-level `tools`. Its first input item was `additional_tools` with the namespace `functions`: `exec`, `wait`, and `request_user_input`; every other tool is a nested tool of `exec`. Developer messages: the native prompt (`You are Codex, ...`, 17,730 characters), skill instructions, permission instructions, app instructions, plugin instructions, recommended plugins, and the text of a plugin `SessionStart` hook. User messages: `# AGENTS.md instructions` with the user's `~/.codex/AGENTS.md` and the project `AGENTS.md`, then `<environment_context>`. With the built-in provider, `ALL_TOOLS` had 112 names: `apply_patch`, `bash`, the goal tools, `image_gen__imagegen`, the MCP resource tools, the user's MCP server tools (`mcp__node_repl__js` and two more), 92 `mcp__codex_apps__*` tools, the `multi_agent_v1__*` tools, `request_plugin_install`, `view_image`, and `web__run`.

### The prompt

- `baseInstructions` on `thread/start` replaced the native prompt: the first developer message was the given text. An empty string gave no such message.
- `thread/resume` with a new `baseInstructions`, in a new program: the request had the new text, and not the old one.
- `thread/resume` with a new `baseInstructions` on the program that has the thread loaded: the answer was a success, and the next request still had the old text.
- `turn/start` has no instructions parameter (schema of 0.163.0).
- Times, with no model call: `thread/start` took 45 to 211 ms in 8 runs with the local fake provider, and 62 to 871 ms in 3 runs with the ChatGPT login and the isolation flags below. With a base URL that nothing listened on, it took about 3 s. The `initialize` answer of a new program came after 110 to 340 ms.

### Isolation

`--strict-config` with a `-c` override rejects an unknown key, so it checked each key below. `codex app-server` has no `--ignore-user-config` (`codex exec` has it).

These flags, after `--disable shell_tool --disable unified_exec`, gave the same request as a longer list of 17 disabled features:

```text
--disable apps --disable plugins --disable hooks --disable goals --disable view_image
--disable image_generation -c project_doc_max_bytes=0 -c web_search="disabled"
-c skills.include_instructions=false -c skills.bundled.enabled=false
-c include_permissions_instructions=false -c include_apps_instructions=false
```

The request then had the product prompt, the user's `~/.codex/AGENTS.md`, `<environment_context>` (cwd, shell, date, timezone), and the user prompt. No project `AGENTS.md`, skill list, hook text, plugin text, or marker file. `ALL_TOOLS`: `apply_patch`, `bash`, `list_mcp_resource_templates`, `list_mcp_resources`, `read_mcp_resource`, the user's three `mcp__node_repl__*` tools, and the five `multi_agent_v1__*` tools; `exec`, `wait`, and `request_user_input` stayed at the top.

What did not remove a residual: `-c 'mcp_servers={}'` and `thread/start` `config: {"mcp_servers": {}}` (the user's servers stayed; only `-c mcp_servers.<name>.enabled=false` names one), `--disable multi_agent` (the `multi_agent_v1__*` tools stayed), and `project_doc_max_bytes=0` (only the project `AGENTS.md` went). `apply_patch_tool_type` is a field of the model catalog, not a config key. A `CODEX_HOME` of Helyx would drop all of the user's config, but the ChatGPT login lives in `$CODEX_HOME/auth.json`, and a copy or link of it was not tried: a token refresh in a copy could end the user's own login.

R3 (real, `gpt-5.6-luna`, the isolation flags, `baseInstructions`): the ChatGPT login worked, and the model answered `ready`.

### A hook before each model call

Not checked. The user's Codex hooks (`session_start`, `user_prompt_submit`, `stop`) run at turn bounds.

## Edit quality

One file `app.py` with three faults; one prompt asked for three edits (fix `add`, change the text of `greet`, make `scale` multiply by 3, where `return x * 2` is in the file twice). One real turn each, `haiku`, flags B:

| Tools | Prompt | Calls | Failed calls | File equal to the expected file |
| --- | --- | --- | --- | --- |
| native `Read` and `Edit` (`--tools=Read,Edit`) | native | 1 `Read`, 3 `Edit` | 0 | yes |
| the Helyx `read` and `edit` specs over `helyx` | the base prompt of `Helyx.ModelContext.Default` | 1 `read`, 3 `edit` | 0 | yes |

The driver ran the Helyx edit as an exact single match. In both runs the model made the duplicated line unique with the line before it. One task is too small to show a difference.

## Files and network

- The isolated Claude runs made no marker file and started no project or user MCP server. Only `/v1/messages` reached the local server; other hosts of the program (telemetry, for example) were not observed.
- The Codex runs reached the local server with `GET /v1/models`, and with the built-in provider first with seven `GET /v1/responses`, then `POST` (inferred: a WebSocket try first). The user's MCP servers started (their tools were in the list).

## Program commands, and the Codex tools again (2026-10-19, #754)

The same versions: Claude Code 2.1.302 and codex-cli 0.163.0, on macOS. No run sent a request to a network service: each program ran under `sandbox-exec` with a profile that denies every outbound connection except to localhost. No real inference.

### Claude Code: `--disable-slash-commands`

Method: the local model stub of "Method", a fake API key, and an empty config folder (`CLAUDE_CONFIG_DIR`), so no login and no user config was used. A Python driver started the program with the flags of `Helyx.Provider.ClaudeCode`, sent `initialize` with a `systemPrompt`, and wrote user lines, with and without the flag.

- `claude --help`: `--disable-slash-commands  Disable all skills`.
- Without the flag, the `initialize` answer listed 44 commands, and the `init` line 44 `slash_commands` and 16 `skills`. With the flag, all three lists were empty.
- Without the flag, `/compact` compacted (`compact_boundary`), and `/init` sent the program's own prompt of the command (write a `CLAUDE.md`) to the model.
- With the flag, `/compact`, `/init`, `/context`, and `/help` made no model request. The program wrote an `assistant` line with the text `/<name> isn't available in this environment.` and no stream delta, then a `result` with `subtype` `success` and that text. `/compact` gave no `compact_boundary`. A rerun by the review (`/compact keep it short`, `/init`, `/help`) had `command_lifecycle` `started`, the `assistant` line, and a `result` with `is_error` false and `queued_turn_count` 0.
- With the flag, `/code-review please` (the name of a bundled skill, not of a built-in command) went to the model as the text of the line, after a `<system-reminder>`: "The user's message starts with the slash command /code-review, but no command with that name is available in this session, so it did not run. No slash commands are available in this session. Treat the message as a plain request and do the task with the tools you have. ..."
- The line `/init` and its answer stayed in the harness session: the next request had `/init`, then `<local-command-stdout>/init isn't available in this environment.</local-command-stdout>`.
- The request of a plain line (`hello`) was the same with and without the flag in every field (`system`, `tools`, `messages`, `thinking`, and the others).
- Source (the binary of 2.1.302): the flag sets a launch option once, at the start, and the command list is then empty. A line of a headless session whose command name is a built-in name gets the "isn't available" answer. No control request compacts: the program handles about 70 subtypes (`initialize`, `interrupt`, `set_model`, `get_context_usage`, `rewind_conversation`, and others), and none of them is a compaction. The command filter of the interactive mode has no CLI flag.
- One harness session over three programs: A with the flag (`--session-id`) ran a turn, and `/compact` got the fixed answer with no request. B without the flag (`--resume`) ran `/compact`, which compacted (`compact_boundary` with `trigger` `manual`, one model request). C with the flag (`--resume`) ran a turn, and its request held the summary. `total_cost_usd` went on over the three programs: 1.5e-06, 3e-06, 4.5e-06 (the prices of the stub's counts).

### Codex: options that could remove its own tools

Method: the help, the feature list, and the protocol schema of `codex app-server`, and the strings of the binary. No `codex app-server` ran, and no turn.

- `codex app-server --help`: `-c`, `--enable`, `--disable`, `--strict-config`, `--code-mode-host`, `--analytics-default-enabled`, and the transport and WebSocket options. None names a tool.
- `codex features list`: no feature for `apply_patch` (`apply_patch_freeform` is `removed`) or for the MCP resource tools. `default_mode_request_user_input` is `under development` and off, and the request of #651 had `request_user_input` with it off. `multi_agent` is `stable` and on; in #651, `--disable multi_agent` kept the `multi_agent_v1__*` tools.
- `codex app-server generate-json-schema --experimental`: `thread/start` takes `dynamicTools`, an open `config` object, and `multiAgentMode`, marked "@deprecated Ignored". `thread/resume` and `turn/start` take no tool list. The `Config` of `config/read` has `tools` with only `web_search`.
- `codex debug prompt-input`, with an empty `CODEX_HOME`, renders the input items with no tool list, so it does not show the tools.
- The strings of the binary have `enabled_tools` and `disabled_tools` only next to other keys of an MCP server (`startup_timeout_sec`, `default_tools_approval_mode`, `oauth`): keys of one named server, as `mcp_servers.<name>.enabled` (inferred from the order).

- Found by the review of #754: the binary has the top-level config key `model_catalog_json`, and `codex debug models --bundled` (no network) shows `apply_patch_tool_type`, `experimental_supported_tools`, `shell_type`, and `tool_mode` on each bundled model. A catalog of Helyx could change these fields. Not tried: it needs a model request to see the tool list.

So in 0.163.0, no option, feature, or thread parameter that was found removes `apply_patch`, `request_user_input`, the `multi_agent_v1__*` tools, or the MCP resource tools. Open: whether a `model_catalog_json` catalog removes any of them, with a model request through a local fake provider.
