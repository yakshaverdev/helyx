# MCP clients and tool search: local sources

Research for ticket #492 (with #473 folded in). It records how other MCP clients start servers, name their tools, bound calls and results, and defer tools behind a search. It records observations only; the decisions go in `docs/features/mcp-client.md`.

Date: 2026-11-06. Research only. No program was run and no network was used: every fact comes from a package installed on the author's machine, read as files. Sources:

- MCP TypeScript SDK 1.29.0: `~/.npm-global/lib/node_modules/@modelcontextprotocol/inspector/node_modules/@modelcontextprotocol/sdk/dist/esm`. Paths below are under it. The copy inside Gemini CLI is 1.24.3.
- Gemini CLI 0.20.2: `~/.npm-global/lib/node_modules/@google/.gemini-cli-bQb4zx7C/node_modules/@google/gemini-cli-core/dist/src`. Paths below are under it.
- Claude Code 2.1.318: `/opt/homebrew/bin/claude`, a native Mach-O file. Facts come from `strings` over the binary. The code is minified, so a constant can belong to another chunk; such a fact is marked "uncertain".
- Codex 0.166.0: the native binary of the package `@openai/codex-darwin-arm64`, read with `strings`. Only names and messages are visible, not defaults.

## The protocol, from the SDK

1. Versions: `LATEST_PROTOCOL_VERSION = '2025-11-25'` and `SUPPORTED_PROTOCOL_VERSIONS = [LATEST, '2025-06-18', '2025-03-26', '2024-11-05', '2024-10-07']` (`types.js:2,4`).
2. The default timeout of a request is `DEFAULT_REQUEST_TIMEOUT_MSEC = 60000` (`shared/protocol.js:8`).
3. Stdio framing: one JSON message per line, `JSON.stringify(message) + '\n'` (`shared/stdio.js:29`). The reader splits on `'\n'` and drops a trailing `'\r'` (`shared/stdio.js:13,17`).
4. Stderr of the server: inherited by default, or a stream that the caller reads with `stderr: 'pipe'` (`client/stdio.js:71`).
5. Close of a stdio server: end its stdin, wait up to 2 s, SIGTERM, wait up to 2 s, SIGKILL (`client/stdio.js:147,152,155,160,164`).
6. Environment of the server: `{...getDefaultEnvironment(), ...server.env}`. Outside Windows the default keeps only `HOME, LOGNAME, PATH, SHELL, TERM, USER` (`client/stdio.js:24`), and drops a value that starts with `()` (`client/stdio.js:35`).
7. A tool (`types.js:1229`): `name`, `title`, `icons`, `description`, `inputSchema` (an object schema, `type: 'object'`), optional `outputSchema`, `annotations` (`title`, `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`, `types.js:1173`), `execution.taskSupport`, `_meta`.
8. A result (`types.js:1289`): `content` (default `[]`), `structuredContent` (an object), `isError`. Content kinds: text, image, audio, resource link, embedded resource (`types.js:1131`). The SDK client checks `structuredContent` against an `outputSchema` (`client/index.js:499-507`).
9. Pages: a list request takes `cursor`, a result carries `nextCursor` (`types.js:601,612`); `tools/list` uses them (`types.js:1277,1283`).
10. A change of the tool list: the notification `notifications/tools/list_changed` (`types.js:1348`), sent when the server advertises `capabilities.tools.listChanged` (`types.js:524`). The SDK client installs its handler only for a server that advertises it (`client/index.js:121`), and re-lists with a debounce of 300 ms by default (`types.js:1365,1374`).
11. Cancel: the SDK's handler of `notifications/cancelled` aborts the signal of the request's handler and sends nothing back (`shared/protocol.js:169-175`); no message confirms that the handler stopped.
12. Tasks: a tool with `execution.taskSupport` `"required"` refuses a plain `tools/call` on the SDK server (`server/mcp.js:116-118`).
13. Tool names: `/^[A-Za-z0-9._-]{1,128}$/` (`shared/toolNameValidation.js:13`). Only the server side of the SDK checks it (`server/mcp.js`); spaces, commas, and a leading or trailing `-` or `.` give warnings only (`shared/toolNameValidation.js:25-46`).

## Gemini CLI 0.20.2

1. Config: `mcpServers` at the top level of `settings.json`, in a system file, the user file `~/.gemini/settings.json`, and a workspace file `.gemini/settings.json` (`config/storage.js:31`, `utils/paths.js:9`). A server has `command, args, env, cwd, url, httpUrl, headers, tcp, timeout, trust, description, includeTools, excludeTools, extension, oauth, authProviderType, targetAudience` (`config/config.js:66-82`).
2. Transport by key: `httpUrl` streamable HTTP, `url` SSE, `command` stdio (`tools/mcp-client.js:333,336`). A stdio server gets the whole environment of the CLI plus `env` (`tools/mcp-client.js:977-985`); its stderr is logged in debug mode only (`tools/mcp-client.js:988`).
3. Timeout: `MCP_DEFAULT_TIMEOUT_MSEC = 10 * 60 * 1000` (`tools/mcp-client.js:25`), the same value for the connect (`:705`) and for each call (`:494,542`).
4. Names: `generateValidName` replaces every character outside `[a-zA-Z0-9_.-]` with `_`; a name over 63 characters keeps its first 28, then `___`, then its last 32 (`tools/mcp-tool.js:268-275`, with the comment "Gemini API says max length 64, but actual limit seems to be 63"). The bare tool name is used. On a clash, the incoming tool decides: an incoming MCP tool whose name is known already, built-in or MCP, becomes `serverName__toolName` (`tools/tool-registry.js:150-153`, `tools/mcp-tool.js:152-155`); an incoming tool that is not from MCP replaces the known one and logs "Overwriting" (`tools/tool-registry.js:154-157`).
5. Discovery reads one page of `tools/list` and does not follow `nextCursor` (`tools/mcp-client.js:483`). A server that fails closes, is reported, and the other servers go on (`:461-466`). A server that errors later is marked disconnected (`:442-444`); no reconnect was found. `notifications/tools/list_changed` is not handled.
6. Results: text as text; image and audio as a text label plus inline data; an embedded resource as its text, or for a blob a text label plus the blob as inline data, which reaches the model (`tools/mcp-tool.js:182-194`); a resource link as the text `Resource Link: name at uri`; other kinds are dropped (`tools/mcp-tool.js:160-230`). No size cap was found.
7. Project trust: the workspace settings are dropped for an untrusted folder (`config/settings.js:277`), but folder trust is off by default, and then every folder is trusted (`config/trustedFolders.js:149,167`).
8. No tool search and no deferred tools were found.

## Claude Code 2.1.318 (strings)

1. Startup timeout: `MCP_TIMEOUT`, else 30,000 ms (`function Yl(){let _=i.MCP_TIMEOUT;return _&&_>0?Math.min(_,2147483647):30000}`). A connect timeout `MCP_CONNECT_TIMEOUT_MS`, default 5,000.
2. Call timeout: the server's `timeout` (at least 1,000), else `MCP_TOOL_TIMEOUT`, else a constant. The constant is about 1e8 ms: uncertain (minified names repeat between chunks).
3. Output cap: `MAX_MCP_OUTPUT_TOKENS`, else a remote flag, else 25,000 tokens.
4. Names: `mcp__${serverName}__${toolName}`. No length cap was found.
5. The log line "Received tools/list_changed notification, refreshing tools", and a telemetry event for paginated lists.
6. Tool search: on by default from 10% of the context window (`ENABLE_TOOL_SEARCH`, `auto:N`). A deferred tool is known by its name only, listed in a system reminder, until the model fetches it ("there is no parameter schema, so the tool cannot be invoked"). The search takes `select:A,B` for exact names, keywords for up to `max_results` best matches (default 5), and `+term` to require a term in the name. Matches come back as `<function>{...}</function>` lines. The strings also hold `tool_search_tool_bm25`, `tool_search_tool_regex`, and `defer_loading`.
7. The repo's own note on the stream-json control protocol records the init capabilities `sdk_mcp_tools_list_changed` and `sdk_mcp_manifests` from claude 2.1.287 (`docs/research/claude-code-stream-json.md:123`). Whether a tool list change of an SDK MCP server reaches the model inside a running turn was not observed.

## Codex 0.166.0 (strings)

1. A `tool_search` handler, "Searches over deferred tool metadata with BM25 and exposes matching tools for the next model call", with the parameters `query` and `limit` ("limit must be greater than zero"); the default limit is not visible.
2. Exposure modes `code_mode`, `deferred`, `direct`.
3. Names `mcp__server__tool`, and a setting `error_on_tool_collisions`.
4. Config keys `startup_timeout_sec` and `tool_timeout_sec`; their defaults are not visible.
5. The type of `notifications/tools/list_changed` exists; whether Codex re-lists on it is not visible.
6. The repo's note on the app server records that dynamic tools are fixed at `thread/start`, that `thread/resume` has no `dynamicTools`, and that a dynamic tool spec may carry `deferLoading` or be a `namespace` (`docs/research/codex-app-server.md:124,128-129`). A function name must match `^[a-zA-Z0-9_-]+$` (`docs/research/codex-app-server.md:42`).

## Open questions

- Whether `notifications/tools/list_changed` from Helyx's SDK MCP server reaches the model of Claude Code inside a running turn, and in which control message it travels. Needs an observed run with a real program and model.
- Whether Codex honours `deferLoading` on a dynamic tool of the app server, and whether its own `tool_search` then finds it. Needs an observed run.
- The name limit of the Anthropic API for a tool that Claude Code exposes as `mcp__helyx__<name>`. Not found in these sources.
