# 2026-10-02: the context request and no normal exit (#299)

Step 2 of `docs/features/one-provider-path.md`.

## Done

- The action `{:need_context, turn_id}` and the request `{:context, turn_id, result}` (C1–C5). The loop accepts the action only for the live turn with no open request. `end_tools` clears the open request. The session builds the context with the same prepare Task as before `{:turn, ...}`, under `prepare_ms`. A context goes through `write_result/4`, as a tool result does, and it is outside the pool of 8.
- L1: `ProviderProcess.run/1` returns the process body as a fun of the connect kill. The fun runs `init/3` and the loop in one `try` with `catch :exit, :normal`, and always exits `{:shutdown, reason}`. The hands map `{:exit, {:shutdown, reason}}` to `reason`.
- `Helyx.Session.ProviderRequest` holds the request rules (the armed kill, its cancel, the kinds, the replies). `Wait.interrupt/2` came from `server.ex`. So `server.ex` and `hands.ex` did not grow, and `provider_process.ex` went from 429 to 416 lines.
- The test provider `Helyx.Test.Connected` links a process at init, so the lifetime tests can check that it ends.

## Broke

- Three tests asserted a `:normal` exit of a closed provider process. They now assert `{:shutdown, :closed}`.

## Next

- Step 3: `Helyx.Provider.Loop` (L2–L4), OpenAI and the test fakes on it, and the deletion of the local path.
- See the accepted holes in `docs/reviews/2026-10-02-299-context-request.md`.
