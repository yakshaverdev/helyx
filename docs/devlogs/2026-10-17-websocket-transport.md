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

## Round 3 (2026-10-18)

- The connection keeps the highest ack of each subscription and gives one at a time, none before the subscribe reply; a subscription starts its acks at the credit base. 100,000 acks before the reply leave no message in the subscription mailbox.
- The transport keeps the SHA-256 of the token. A part before `welcome` closes with 4400.
- Codex found that Bandit keeps a handler after a normal stop and hands it later frames. Every close now stops with `{:shutdown, :closed}`, which ends the process.
- Limit tests at 1 MiB and 25 MiB, one under each, `Outbound.taken/2`, and the crash of the gate.

## Merge gate round (2026-10-18)

- The worker cancels its deadline timer at its end, so a connection holds at most 16 timers.
- Any part before `welcome` closes with 4400. A writer exit answers every id of the writer.
- The log of the hello took three review rounds: a ThousandIsland crash report, then a Bandit HTTP/1 protocol error after a refused upgrade, then an HTTP/2 warning. The server now speaks only one HTTP/1.1 upgrade per connection and logs no protocol error.
- Open, in Bandit and ThousandIsland: a `:tcp_error` crash report, an exception in the handshake with the `conn` in its metadata, and the TLS-sniff warning. A fix needs a dependency change or a `:logger` filter of the product.
