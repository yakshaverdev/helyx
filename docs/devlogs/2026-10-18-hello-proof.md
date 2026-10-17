# 2026-10-18: the challenge and the proof (#763)

Done:

- Protocol 2. The server sends `challenge` with a nonce of 32 random bytes at the upgrade. `hello` carries `proof`, the base64 of HMAC-SHA256 of the nonce with the key, the SHA-256 of the token. No frame holds the token.
- The key is in a closure in the plug options, and so in every process state. `child_spec/1` puts the token in a closure, because the supervisor of the product keeps its start arguments.
- The protocol number is checked before the proof, so a client of protocol 1 gets `refused`.
- Tests: the three open log paths of #660 on a loopback socket, each with a raw log handler (a formatter drops the `conn` metadata) and a frame mask of zero, so the log holds the frame text; the state of every process under the transport and the child spec.

What broke:

- A first test for the supervisor report of a failed start got no event: Elixir drops sasl reports by default. The tree test checks the child spec instead.
- `inspect/1` prints a binary with a byte that is not printable as a list of bytes, so the handshake log did not show the proof as text. The tests inspect each event twice, the second time with `binaries: :as_strings`.

Next: none for this ticket. A client in another language computes the proof from `docs/features/wire-protocol.md`.
