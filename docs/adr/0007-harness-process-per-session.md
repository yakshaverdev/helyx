# A harness program lives for the session, not for the turn

Status: accepted on 2026-09-27, ticket #192.

ADR 0002 made Claude Code and Codex harness providers, and its revision made the provider flag `turn: :external`. Each external turn started the program, resumed the harness session, and ended the program. A harness could not take a message inside a turn, so a steer aborted the turn and sent it again. An abort killed the program's group. Helyx tools were not visible to the harness, because that needed an MCP server.

The research of 2026-09-26 (`docs/research/claude-code-stream-json.md`, `docs/research/codex-app-server.md`) shows that both programs support one process for many turns over the same stdio. Both take a message inside a running turn: a user line during a tool call for Claude, and `turn/steer` for Codex. Both stop a turn in the program and stay alive: the control request `interrupt` for Claude, and `turn/interrupt` for Codex. Both take tools from the client over stdio: an SDK MCP server for Claude, and `dynamicTools` for Codex. t3code keeps one process per session for both programs (`docs/research/t3code-harness-adapters.md`). It does not use all of these parts: it sends Codex messages as `turn/start`, not `turn/steer`, its Claude interrupt closes the session, and it gives tools through an HTTP MCP server.

## Decision

A harness program lives for the whole session. The hands start it on the first external turn, hold its OS resources, and end it when the session ends or the provider changes. A crash of the program fails the running turn. There is no reconnect inside a turn. The next turn starts a new program, which resumes or replays as today.

The program runs in a harness process, a long-lived Task of the hands that runs a Core loop. The provider callbacks run only in that process. So the hands know the pid before plugin code runs, and `Helyx.Tool.hold/1` works as it does for a stream Task today.

A steer goes to the running turn, at most once. An abort first stops and releases the turn's Helyx tool calls, then asks the program to stop the turn within a deadline. When the program cannot confirm that no queued work remains, Helyx stops the program with TERM, not with end of input, because Claude runs its queued turns after end of input. A deadline is a kill armed at the OTP timer server with the request (`:timer.kill_after/2`), and the harness loop cancels it before it replies. No Helyx process enforces a request deadline with its own timer: a blocked provider callback blocks the harness loop, the hands block during a release, and the session writes files and has an unbounded mailbox. A turn sends nothing to the harness before its prompt, and the harness loop rejects a steer after the terminal of its turn and ends no turn while a written steer is unresolved. So a steer never starts a program turn outside an active Helyx turn. From the send of the prompt, an abort must interrupt or stop the harness, because the program can start the turn before its answer reaches the session. Every end of a turn, a normal end too, kills and releases the Helyx tool Tasks that the turn left before the next turn can start. The harness gets the Helyx tools next to its own tools.

Plugin code still never runs in the session process. Every event of the program still passes the check of `Helyx.Session.Stream`.

## Considered options

- Keep one program per turn. Rejected: every steer loses the running command, and every turn pays the start, the resume, and the replay.
- Use the Agent SDK. Rejected: it is Node or Python, and it adds a runtime to the node for a protocol that Elixir can speak directly.
- Expose the Helyx tools through an HTTP MCP server, as t3code does. Rejected for now: both programs take tools over the stdio that Helyx already owns, so no server, port, or token is needed.

## Consequences

- ADR 0002: "A steer aborts the turn" in its revision no longer holds for a provider with a long-lived program, and neither does "During a harness turn, Helyx tools are not visible to the model".
- ADR 0003: the hands hold one long-lived harness process per session, next to the Tasks of the tool calls.
- ADR 0004: the harness process holds its handles with the hands, like a stream Task today. Its release path does not change: its link to the hands, and the watchdog at the port. The watchdog gets a byte cap on the stdin of a command (#196), because the harness program now reads Helyx writes for the whole session. On `SIGTERM`, both programs end their own commands (verified: Claude 2.1.283, Codex 0.157.1). A background task of Claude can outlive the turn that started it. It lives until the program ends (#194). The program closes after 30 minutes with no turn, unless it runs a background task (#195): the session sends `:idle_close`, and the provider answers `:busy` or closes the program.
- The harness's approval requests reach Helyx on the same request path as the tool calls. Approvals stay `accept` until a UI ticket.
- Codex `turn/interrupt` does not end a running command (#198). An abort of a Codex turn with an open command stops the program, and the next turn resumes as today (#201).
- A provider without the new callbacks keeps one program per turn. Superseded on 2026-09-30, see the amendment.
- The session mailbox between the event sender and the session stays unbounded, as for every provider today (#197).

## Amendment

2026-09-30 (#265, approved by the owner): a provider is one of two kinds. An API provider has a local turn: Helyx runs the loop and the tools, and the provider implements `stream/3` (today the OpenAI-compatible provider). A harness provider is connected: it exports `harness_init/3` and the harness callbacks of this ADR (today Claude Code and Codex). The export of `harness_init/3` is the only signal. The `turn/0` callback, the per-turn `:external` mode, and the start error `{:bad_provider_turn, id}` are gone, and `stream/3` is optional for a connected provider. No bundled provider used the per-turn mode; only test fakes did. A future harness program with no persistent-process mode, one that cannot keep a process across turns, would need the per-turn path again: a new decision that brings back a stream of the whole turn under the hands and a steer that aborts the turn.

2026-10-02 (#300, `docs/features/one-provider-path.md`): the provider process is for every provider, not only a harness. An API provider runs in it through `Helyx.Provider.Loop` (ADR 0002, revision of 2026-10-02). The rules of this ADR, the request protocol, the deadlines, and the ownership by the hands, hold for it unchanged.
