# 2026-10-17: the WebSocket transport (#660)

## Done

- `Helyx.Transport.WebSocket` on Bandit 1.12.5 and WebSock 0.5.3, with thousand_island pinned to 1.5.0 (1.6.0 was two days old). Plug is now a normal dependency of `helyx_plugins`.
- The connection, the outbound queue, the parts codec, the subscription processes, the ops table with their deadlines, and the connection gate.
- The conformance client `Helyx.Test.WireClient` on raw `:gen_tcp`, with tests on loopback port 0.
- The doc and ADR 0008 say "per subscription" for the credit bound, with the reason. An inbound frame over 1 MiB closes with 1009, not 4413: Bandit closes before it reads the payload.

## Broke

- Bandit logs `{:deserializing, :max_frame_size_exceeded}` at a 1009 close. Log noise only.
- Two edit scripts failed after `mix format` changed their target text.

## Next

The review record `docs/reviews/2026-10-17-660-websocket.md` lists the open findings: the ack mechanism (a mailbox with no bound before the subscribe reply, and the start of `acked`), the token in the connection state, the worker params outside the byte bound, and the missing limit tests.
