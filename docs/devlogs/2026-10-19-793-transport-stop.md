# 2026-10-19: one bound for the stop of the transport (#793)

- Reproduced the ticket in a test: two connections that stop inside their HTTP headers made the stop take 30,005 ms.
- `Helyx.Transport.WebSocket` runs one acceptor group (`num_acceptors: 1`, `shutdown_timeout: 15_000`) and a first stop step, `Helyx.Transport.WebSocket.Drain`. It suspends the listener, closes the gate, and kills each connection outside the gate. The stop is now 20,000 ms in all; the reproduction stops in milliseconds.
- What broke: a match on `Bandit.HTTP1.Socket` in the stack missed; the protocol module is `Bandit.HTTPTransport.Bandit.HTTP1.Socket`, so the test matches `read_headers/1`.
- Codex found that the gate stayed open while the drain read it; `Gate.close/1` now does both in one call.
- Next: the accepted holes of `docs/reviews/2026-10-19-793-transport-stop.md`.
