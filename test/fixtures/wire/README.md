# Wire conformance fixtures

Fixtures of the wire protocol 13 (`docs/features/wire-protocol.md`) as plain JSON, for a client or a server in any language. They describe protocol 13 as it is, for a server with no authority; a server under a Hub (`docs/features/hub.md`) has no case here (see "Rules in prose only"), but the records feed of a user has its own file. Each file names its `protocol`; a protocol change fails the Elixir tests until the fixtures follow it.

The Elixir code runs every case: `plugins/bundled/test/helyx/transport/web_socket_fixtures_test.exs` runs `client_frames.json` against the server, and `plugins/bundled/test/helyx/tui/wire_fixtures_test.exs` runs `server_frames.json` against the client of the TUI and `folds.json` against its view model. The runners are in the bundled project and read this folder by its path in the repository. `clients/rust/core/tests/records.rs` runs `records.json` against the client core.

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
  - `ui_blocks`: the UI blocks that the client shows from the snapshot and the `ui_block` events, each as `{call_id, key, block}`, in the order of the first of each pair of `call_id` and `key`. A `ui_block` with the same pair replaces the block in place; `tool_execution_end` drops the blocks of its call, and `turn_end` drops them all. The UI blocks of a tool result message are part of the message, not of this list.
  - `messages`: the ids of the transcript, oldest first: each user and assistant message, and each tool result after the assistant message of its call. The session pairs each result with its call, so a client does not enforce it: a tool result with no open call of its id, or with no call id, is in its place in the transcript, shown as an orphan.

A reply follows its request before the next request. The Elixir run serves the steps from a fake server to the client of the TUI, one connection up to each close, and folds what the client gives into its view model. The client of the TUI sends only `subscribe` among the requests of the folds: it does not page `history`, so no fold has the `instance_changed` error of `history`; a client that gets it subscribes again, and the fold of an instance that changed shows the snapshot that it gets.

## Rules in prose only

These rules have no fixture here; the feature doc states them, and the Elixir tests named below check them.

- The time limits: the `hello` within 5,000 ms (`4401`), a ping every 15,000 ms, and 45,000 ms with no inbound frame (`4408`); the deadlines of the operations. `web_socket_test.exs`.
- The bounds of a UI block: 65,536 bytes of JSON, and an integer of at most 100 digits in any field. A client takes a block of a kind that it does not know; a block over a bound is a contract break, for the server cuts or refuses it (`docs/features/ui-blocks.md`). `test/helyx/tui/wire/ui_blocks_test.exs`.
- The bounds at their limits. A case at a bound is generated by a test, not stored, so each file stays small enough to read in a review. The exception is a frame past a bound of Core that a client takes: `server_frames.json` holds a message of 1,025 blocks and a text of a tool result of 65,537 bytes, each on its line, since a client in another language runs only these files (#860). The generated cases: a frame at 1 MiB and parts over 25 MiB (`4413`), the decode bounds, the 64 connections, 16 requests in flight, 16 subscriptions, the outbound queue (`web_socket_test.exs`, `web_socket_subscribe_test.exs`); the tail bound of 16,777,216 bytes (`test/helyx/session/history_test.exs` in the root project); the outbound decode bounds of a client (`test/helyx/tui/wire/connection_test.exs`).
- The rules that need a running session or two requests at once: a duplicate request `id` (`4400`), an `ack` above the last `seq` sent (`4400`), the `:slow` end after 16,384 unacked events (`4408`), the order rules O2 to O6, the tail cut at a user or assistant message, the pages of `history`, and the replay ring. `web_socket_subscribe_test.exs`, and `test/helyx/session/history_test.exs` and `ring_test.exs` in the root project. The folds hold the client side of these rules; they do not drive a server.
- The rules of a server under a Hub: the `token` of `hello` and its proof (`4401`), no answer of the authority at the `hello` (`4503`), a change of access (`4403`), the check of each request and subscription, and the `hub.*` operations. `plugins/bundled/test/helyx/transport/web_socket_authority_test.exs`, and `access_test.exs`, `connections_test.exs`, and `records_test.exs` in `plugins/bundled/test/helyx/hub/`.
- The `Origin` check (HTTP 403) and the 65th connection (HTTP 503), and the closes of the WebSocket server (`1000`, `1002`, `1008`, `1009`, `1011`).

The feature doc lists what the prose does not pin down for an implementation that does not run on the BEAM: `docs/features/wire-protocol.md`, "Conformance fixtures".

## `bounds.json`: the numbers and the error codes, once

The bounds of a frame, a part, a request and a server frame, the waits and the caps of a connection, the deadlines of the operations in milliseconds, the records feed's page, pending changes, subscribers, and the client's rows, and the error codes in the order of the schema. The server and the client of the TUI read this file at compile time (`Helyx.Transport.WebSocket.Bounds`), so they hold no copy. `clients/rust/core/tests/bounds.rs` checks the constants of the Rust client against it. `docs/features/wire-protocol.md`, "Bounds", gives the reason of each number, and `docs/features/live-records.md`, "Bounds", the reason of the records numbers.

## `records.json`: a client of the records feed must pass every case

The records feed of a user (`docs/features/live-records.md`), for a client
that subscribes with `records.subscribe`:

- `reply`: a `res` of `records.subscribe`, with its `record` list and `more`.
  `expect` is the ordered ids of the rows and `more`.
- `frames`: a frame after the `records.subscribe` reply: a `record` change, a
  `record` removal, a `records` full list, or a `records_end`. `"valid"`: the
  client takes it and applies it, or ends the feed for `records_end`.
  `"broken"`: a contract break, as for a known kind with a broken shape.
- `folds`: the steps of `folds.json` for the records feed. `client` is a
  `records.subscribe` request with `{}` params. `server` is its reply or a
  frame; `close` ends a connection; `expect` gives the ordered ids of the
  rows, the status of each row, `more`, and whether the feed ended.
