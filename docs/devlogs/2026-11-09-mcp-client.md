# 2026-11-09: MCP client (#492)

## Done

The ten slices of `docs/features/mcp-client.md`, each its own commit:

1. The tool name rule (1 to 52 bytes of `[A-Za-z0-9_-]`).
2. Tool sources in Core: the source process, the registry, `launch/1`, `announce/1`, `put_tools/2`.
3. Deferred tools, `activate/1`, `deferred/2`, the `tools_change` entry.
4. Wire protocol 8: the `tools_change` event and the snapshot field `activated`, in the server, the TUI decoder, the fixtures, and the Rust client kit of #860.
5. `tool_search`.
6. The harness providers follow the active tool set.
7. `Helyx.Tool.MCP.Config`.
8. The release record of `Helyx.Watchdog` (`Helyx.Watchdog.Record`), with a lease for a release killed in the middle.
9. The MCP start and listing (`Helyx.Tool.MCP`, its source, server Task, launch, lines, listing, result), the `:deadline` and `:unset` options of `Helyx.Watchdog.start/4`, and Core `Helyx.Tool.notice/1`.
10. The calls, the cancel and restart of decision 14, the call handle, and the wiring in the coding agent.

Three rebases on master: the UI blocks of #878 took wire protocol 5 and the Hub of #869 and #870 took 6 and 7, so this branch speaks 8, in the server, the TUI, the Rust client core of #860, and the fixtures.

## What broke

- A usage limit and two stops of the orchestrator cut the run; the work went on from the branch each time.
- The precommit host timed out twice on ssh; a later run passed.
- On this machine `~/.agents/skills` holds 86 skills, so `tui_test.exs` and the CLI tests of `print_test.exs` fail locally with the notice "15 skills were left out"; the precommit host has no such folder.

## Next

- The in-turn render of a tool change on a harness provider needs an observed run of a real program (decision 10).
- The spec's tests of a `kill(1)` that stalls in the cleanup of a failed start need a test hook inside `Helyx.Watchdog.start/4`.
- `plugins/bundled/clients/tui/lib/helyx/tui/wire/decode.ex` holds 400 lines; its next line needs a seam.
