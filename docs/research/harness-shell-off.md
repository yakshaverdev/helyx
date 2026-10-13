# Harness programs with the shell off

Date: 2026-10-13. Versions: Claude Code 2.1.296 (`claude --version`), codex-cli 0.144.1 (`codex --version`), on macOS (Darwin 25.6.0). The runs were in a temporary directory outside the repository. Ticket #478.

## Claude Code

### Flags

- `claude --help` lists `--disallowedTools, --disallowed-tools <tools...>` ("Comma or space-separated list of tool names to deny") and `--tools <tools...>` ("Specify the list of available tools from the built-in set").
- The option takes several values, so a bare `--disallowedTools Bash,Monitor` before other arguments could take the arguments after it as tool names too (inferred from the help, not run). The runs below put the bare form last. The form `--disallowedTools=Bash,Monitor`, which Helyx uses, also worked: the `init` line had no `Bash` and no `Monitor`.

### The tool list of the `init` line

`claude -p "reply ok" --output-format stream-json --verbose --model haiku --max-turns 1`, with no tool flag, listed these built-in tools: `Task`, `Bash`, `CronCreate`, `CronDelete`, `CronList`, `DesignSync`, `Edit`, `EnterWorktree`, `ExitWorktree`, `ListAgents`, `ListMcpResourcesTool`, `LSP`, `Monitor`, `NotebookEdit`, `PushNotification`, `Read`, `ReadMcpResourceDirTool`, `ReadMcpResourceTool`, `RemoteTrigger`, `ReportFindings`, `ScheduleWakeup`, `SendMessage`, `Skill`, `TaskStop`, `ToolSearch`, `WebFetch`, `WebSearch`, `Workflow`, `Write`, then the user's MCP tools.

- No `BashOutput` or `KillShell` tool exists in this version. A background shell is a `Bash` call with `run_in_background`, and `TaskStop` stops a background task, a sub-agent included (from the tool's description, not run).
- `Monitor` runs a command and streams its output.

With `--disallowedTools Bash,Monitor` the list had no `Bash` and no `Monitor`, and it had `Glob` and `Grep`, which the default list does not have. Every other tool stayed.

### Runs with `Bash` and `Monitor` denied

All with `--permission-mode bypassPermissions --model haiku`.

1. Prompt: run `echo probe478`, or say `NO_SHELL` and list the tools. The model answered `NO_SHELL` and ran nothing. The deny holds with `bypassPermissions`.
2. Prompt: start one general-purpose sub-agent with the `Agent` tool (the `init` line names it `Task`; the tool use named it `Agent`), which runs `echo probe478` if it has a shell tool. The sub-agent answered `NO_SHELL`; its tools were `Agent`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `ToolSearch`, `Write` and MCP tools, with others deferred. The deny holds for sub-agents.
3. Through Helyx (`Helyx.Provider.ClaudeCodeRealTest`, `claude-code/haiku`, the four bundled tools in Core): the prompt asked for the command `echo $$ > fg.pid; exec sleep 90`. The model called `mcp__helyx__bash`, the only tool call of the turn. The abort ended the turn with `:aborted`, and the process of the command was gone after it. The test passed in 4.7 s.

## Codex

### Flags and features

- `codex features list` shows `shell_tool` and `unified_exec` as `stable`, both `true`.
- `codex app-server --help` lists `--disable <FEATURE>` ("Equivalent to `-c features.<name>=false`").
- The user's `~/.codex/config.toml` of the run machine sets `unified_exec = true` under `[features]`. With the `--disable` flags, the model ran no command of the program in the probe below. The probe shows behaviour only: the app-server protocol sends no tool list. "The tool list of the model request" below reads the list from the request to the model.
- `codex debug models` listed `gpt-5.6-sol`, `gpt-5.6-terra` and `gpt-5.6-luna` as visible. A thread with `gpt-6.1-sol` or `gpt-6-luna` started, and the turn failed with status 400: "The '<model>' model is not supported when using Codex with a ChatGPT account".

### The probe

`codex app-server --disable shell_tool --disable unified_exec` through `Helyx.Provider.Codex`, model `codex/gpt-5.6-luna`, with the four bundled tools in Core (so the thread got only `bash` as a dynamic tool). The work directory had `calc.py` with `return a - b` in `add`, and `test_calc.py`, which asserts `add(2, 3) == 5` and prints `PASS`. The prompt asked to read `calc.py`, fix `add`, run `python3 test_calc.py`, and report the output.

- `thread/start` with the features off succeeded.
- The model read the files with the Helyx `bash` (`sed -n` and `rg`), two `dynamicToolCall` items with `tool` `bash`.
- It changed `calc.py` with one `fileChange` item (`apply_patch`), to `return a + b`.
- It ran `python3 test_calc.py` with the Helyx `bash`; the result was `PASS`.
- The turn ended `:done`. No `commandExecution` item came.

### codex-cli 0.162.1

The machine has more than one `codex`. A login shell finds codex-cli 0.144.1 first, which ran the probe above. A shell with `~/.bun/bin` first on `PATH` finds codex-cli 0.162.1, and `HarnessIO.find/1` takes the first one on the `PATH` of the BEAM.

- `codex --disable shell_tool --disable unified_exec features list` on 0.144.1: `shell_tool` and `unified_exec` both `false`.
- The same on 0.162.1: `shell_tool` `false`, `unified_exec` `true`. 0.162.1 also lists `unified_exec_tty` (`stable`, `true`).
- The probe above, run again on 0.162.1 with the same model and task: the model read and ran the test with the Helyx `bash` (`dynamicToolCall` items), changed `calc.py` with one `fileChange` item, the test printed `PASS`, and the turn ended `:done`. No `commandExecution` item came. This shows behaviour only: it does not prove that 0.162.1 gives the model no shell tool.

### The tool list of the model request

Date: 2026-10-13. codex-cli 0.144.1 (`~/.local/bin/codex`) and 0.162.1 (`~/.bun/bin/codex`), ticket #548. No model ran: a local Python HTTP server took the place of the Responses API and wrote each request body to a file.

- A `CODEX_HOME` with only this `config.toml`: `model_provider = "fake"` and `[model_providers.fake]` with `base_url = "http://127.0.0.1:<port>/v1"` and `wire_api = "responses"`. A Python script drove `codex app-server` as `Helyx.Provider.Codex` does: `initialize` with `experimentalApi`, `thread/start` with `approvalPolicy` `never`, `sandbox` `danger-full-access`, and one dynamic tool `bash`, then `turn/start`.
- The request has no top-level `tools`. Its first `input` item has the type `additional_tools`, with one namespace `functions` that holds `exec`, `wait`, and `request_user_input`. This holds on both versions; every other tool is a nested tool of `exec`. The description of `exec` on 0.162.1 says that it runs JavaScript in a V8 isolate ("no Node, no file system, no network access"), that it calls the nested tools on its `tools` object, and that deferred nested tools can be left out of the description but are listed in `ALL_TOOLS`.
- So the fake server answered the first request with a `custom_tool_call` of `exec` with the input `text(JSON.stringify(ALL_TOOLS.map(t => t.name)));`, and read the result in the `custom_tool_call_output` of the next request.

The command tools in `ALL_TOOLS`, per launch flags (every list also had `apply_patch`, the Helyx `bash`, the goal tools, `view_image`, and the `multi_agent_v1__*` tools; 0.144.1 also `update_plan`, 0.162.1 also the MCP resource tools):

| Launch flags | 0.144.1 | 0.162.1 |
|---|---|---|
| none | `exec_command`, `write_stdin` | `exec_command`, `write_stdin` |
| `--disable unified_exec` | `shell_command` | `exec_command`, `write_stdin` |
| `--disable shell_tool` | none | none |
| `--disable shell_tool --disable unified_exec` | none | none |

- On 0.162.1, `--disable unified_exec` has no effect on the tools, as `features list` shows. `--disable shell_tool` takes out every command tool on both versions, `exec_command` included.
- Both flags and the user's own `~/.codex/config.toml` (`unified_exec = true` under `[features]`; the provider set with `-c model_provider=fake -c 'model_providers.fake={...}'`), on each version: no command tool. Each list also had the MCP tools of the user's config, among them one named `mcp__node_repl__js`. The probe did not call it.
- A sub-agent with both flags, on each version: the parent's `exec` called `multi_agent_v1__spawn_agent` with the message `child probe`, and the fake server answered the child's first request with the same `ALL_TOOLS` call. The child on 0.144.1 had `apply_patch`, the goal tools, `update_plan`, and `view_image`. The child on 0.162.1 had `apply_patch`, the goal tools, the MCP resource tools, and `view_image`. Neither had a command tool or the Helyx `bash`.
- The instruction text in the `input` messages of the 0.162.1 request still names `exec_command` with both flags.
