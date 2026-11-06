# Wire conformance fixtures

Fixtures of the wire protocol 3 (`docs/features/wire-protocol.md`) as plain JSON, for a client or a server in any language. They describe protocol 3 as it is. Each file names its `protocol`; a protocol change fails the Elixir tests until the fixtures follow it.

The Elixir code runs every case: `plugins/bundled/test/helyx/transport/web_socket_fixtures_test.exs` runs `client_frames.json` against the server, and `plugins/bundled/test/helyx/tui/wire_fixtures_test.exs` runs `server_frames.json` against the client of the TUI and `folds.json` against its view model. The runners are in the bundled project and read this folder by its path in the repository.

## The match rule

An expected object matches an object that holds each of its keys with a matching value; the other keys are not checked, so a `res` matches with no `text` of its error. An expected list matches a list of the same length, item by item. Any other value matches an equal value.

## `client_frames.json`: a server must pass every case

Each case runs on its own connection to a server with no live session and no saved session.

- `phase`: `"hello"` starts after the `challenge`. `"open"` starts after the `welcome`: the client sent a `hello` with the protocol of the server, and the proof when the server has a token.
- `token`: the server has this token. With no `token`, the server has none.
- `send`: the texts that the client sends, in order, each in one WebSocket text frame. An object is sent as its JSON text. A string is sent as it is, as a text that is not JSON. The string `"$proof"` in a `hello` stands for the proof of the nonce of the challenge with the token (rule O1).
- `expect.frames`: the frames that the server sends next, in order, by the match rule. A WebSocket ping between them is skipped.
- `expect.close`: the close code that the server ends the connection with, next after those frames.
- With no `expect.close`, the connection stays open: the reply to a next request is the next frame. The Elixir run sends `sessions.live`.

The case of a valid op names a session that does not exist, so the reply shows that the params passed their check: `session_not_found`, `unknown_sub`, or `not_found` for a well-formed session id. The `start` case has a `cwd` with a NUL byte, so the reply is `invalid_cwd` and no session starts.

## `server_frames.json`: a client must pass every case

- `handshake`: the frames that the server sends after the upgrade; the server sends the first, reads the `hello` if the client sent one, then sends the rest. `expect` is `"welcome"`, `{"refused": n}` for a server of protocol `n`, or `"broken"`: the client ends the connection as a contract break.
- `res`: a reply to a request of `op`, with the `id` of that request in place of its `id`. `"valid"`: the client takes it. `"broken"`: a contract break. The cases cover the ops whose results the client of the TUI reads; it does not send `sessions.live` or `history`, so the shapes of their results are in the schema only.
- `event`: an event frame after the subscribe reply of its `sub`, `"0"`. `"valid"`: the client takes it. `"ignored"`: an event of a type that the client does not know, which it skips. `"broken"`: a contract break.
- `session_end`: the frame after the subscribe reply of its `sub`. `"valid"`: the subscription ends with its reason. `"broken"`: a contract break.

## `folds.json`: a client must hold the state of every `expect` step

Each fold is a list of steps, applied in order:

- `client`: a request that the client sends. A `subscribe` with `after` names the `instance_id` and the `seq` of the state that the client holds.
- `server`: a frame that the client applies. A `subscribe` reply with a `snapshot` replaces the whole state; one with a `replay` applies its events in order. An event applies to the state. An error reply and `session_end` change nothing.
- `close`: the server closes the connection with this code; `null` is a connection lost with no close frame. The state stays, and the next step is on a new connection.
- `expect`: the state that the client holds now, by the match rule:
  - `instance_id`: that of the last snapshot.
  - `seq`: that of the last snapshot or of the last event applied after it.
  - `model`, `queue`, `asks` (the ids of the open asks, oldest first).
  - `running`: true from a snapshot with a `turn` or a `turn_start`, until a `turn_end`.
  - `messages`: the ids of the transcript, oldest first: each user and assistant message, and each tool result after the assistant message of its call.

A reply follows its request before the next request. The Elixir run serves the steps from a fake server to the client of the TUI, one connection up to each close, and folds what the client gives into its view model. The client of the TUI sends only `subscribe` among the requests of the folds: it does not page `history`, so no fold has the `instance_changed` error of `history`; a client that gets it subscribes again, and the fold of an instance that changed shows the snapshot that it gets.

## Rules in prose only

These rules have no fixture here; the feature doc states them, and the Elixir tests named below check them.

- The time limits: the `hello` within 5,000 ms (`4401`), a ping every 15,000 ms, and 45,000 ms with no inbound frame (`4408`); the deadlines of the operations. `web_socket_test.exs`.
- The bounds at their limits. A case at a bound is generated by a test, not stored, so each file stays small enough to read in a review: a frame at 1 MiB and parts over 25 MiB (`4413`), the decode bounds, the 64 connections, 16 requests in flight, 16 subscriptions, the outbound queue (`web_socket_test.exs`, `web_socket_subscribe_test.exs`); the tail bound of 16,777,216 bytes (`test/helyx/session/history_test.exs` in the root project); the outbound decode bounds of a client (`test/helyx/tui/wire/connection_test.exs`).
- The rules that need a running session or two requests at once: a duplicate request `id` (`4400`), an `ack` above the last `seq` sent (`4400`), the `:slow` end after 16,384 unacked events (`4408`), the order rules O2 to O6, the tail cut at a user or assistant message, the pages of `history`, and the replay ring. `web_socket_subscribe_test.exs`, and `test/helyx/session/history_test.exs` and `ring_test.exs` in the root project. The folds hold the client side of these rules; they do not drive a server.
- The `Origin` check (HTTP 403) and the 65th connection (HTTP 503), and the closes of the WebSocket server (`1000`, `1002`, `1008`, `1009`, `1011`).

The feature doc lists what the prose does not pin down for an implementation that does not run on the BEAM: `docs/features/wire-protocol.md`, "Conformance fixtures".
