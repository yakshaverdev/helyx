# Session not found, and client start errors

## Goal

A client that calls a session that is not running gets an error value, not an exit. A client that starts or resumes a session gets a start error from a closed list. Issue #188, from ADR 0006, section 2 and Consequences, ticket 1.

User story: I keep the TUI open, and the session behind it ends. When I press Enter, the TUI does not crash with a `noproc` exit. The text stays in the composer, and the status bar says that the session ended. A remote client that starts a session with a bad tool gets `{:start_failed, text}`, and the server log has the full reason.

Today:

- `Helyx.Session.subscribe/1` registers the caller in the events Registry and then calls the session. For a session that is not running, the call exits, the caller crashes, and the registration stays until the caller ends.
- `prompt/2`, `steer/2`, `follow_up/2`, `abort/1`, and `set_model/2` exit the same way.
- `Helyx.TUI.mount/1` checks with `Session.pid/1` that the session is alive before the subscribe, and catches the exit of the subscribe.
- `start/2` and `resume/2` can return any term, for example a supervisor error that holds a module.

## Interface changes

### A session that is not running

`Helyx.Session` sends every operation of the contract through one private function, `call/3`. It reads the pid with `Session.pid/1`, calls it, and returns `{:error, :session_not_found}` when the session is not running:

- No process has the id in the sessions Registry, because the session ended or never existed. `pid/1` gives `nil`.
- The Core has stopped, so its Registries are gone. A Registry function then raises `ArgumentError`. `pid/1` gives `nil`, and `subscribe/1` and `set_model/2` return the error.
- While the Core stops, the events Registry can exist without its partition. The register of `subscribe/1` then raises `ErlangError` (`:noproc` of the link), and `subscribe/1` returns the error. Its removal of a registration does not raise when the Registry is gone.
- A Core that stops ends each process that subscribed to its sessions and does not trap exits, because `Registry.register/3` links the caller to the Registry partition. Such a client gets no `:session_not_found`; it ends with `:shutdown`. A transport that serves many sessions from one process traps exits or subscribes from one process for each session.
- The process is dead but still registered, because the Registry removes the name of a dead process asynchronously. The call exits with `:noproc`.
- The process died during the call, with any reason. The supervisor logs the crash, so no reason is lost.
- A call that exits with `:timeout` and a process that still lives: the session is running but did not answer in time. This is not a missing session, so the exit goes on to the caller, as before. A session that stops with the reason `:timeout` gives the same exit, so `call/3` checks that the process lives.

Changed specs:

```elixir
@spec subscribe(t()) :: {:ok, Snapshot.t()} | {:error, :session_not_found}
@spec prompt(t(), String.t()) :: :ok | {:error, :turn_running | :invalid_utf8 | :queue_full | :session_not_found}
@spec steer(t(), String.t()) :: :ok | {:error, :invalid_utf8 | :queue_full | :session_not_found}
@spec follow_up(t(), String.t()) :: :ok | {:error, :invalid_utf8 | :queue_full | :session_not_found}
@spec abort(t()) :: :ok | {:error, :session_not_found}
@spec set_model(t(), String.t()) :: :ok | {:error, model_error() | :session_not_found}
```

`subscribe/1` registers the caller, then calls the session. The order register, then snapshot, stays (`docs/features/session-snapshot.md`). A caller holds at most one registration for a session: the events Registry has duplicate keys and sends an event once for each entry, so a second entry would deliver each event twice. A second subscribe from the same process, a reconnect for example, does not register again; it gets a new snapshot, which replaces the state of the client (ADR 0006, section 3).

When the call returns `{:error, :session_not_found}`, or the snapshot call exits on its timeout, `subscribe/1` removes the caller's registration for the id (`Registry.unregister/2`). This includes the registration of an earlier subscribe of the same process: the session is not running, or it did not answer, and a new subscribe replaces what the earlier one gave. After a timeout the exit goes on to the caller, and the caller subscribes again to get events.

Accepted hole: after a failed subscribe, an event can stay in the caller's mailbox. The session can send it to the new registration before it ends, or, on a timeout, between its read of the Registry and its send. The failed subscribe does not remove it. A client drops it by `instance_id` and `seq` once it has a snapshot: an event of an earlier instance, or of another Core with the same id, has another `instance_id` (#204, `docs/features/session-instance.md`). The review record has the history (`docs/reviews/2026-09-27-188-session-not-found.md`).

A text that is not UTF-8 still returns `{:error, :invalid_utf8}` before the call, and a model ref that does not resolve still returns its model error before the call. So these errors win over `:session_not_found`.

`model/1` is not in the contract (ADR 0006, section 2) and keeps its exit.

### Start errors for a client

The mapping lives in one public function of `Helyx.Session`, so every transport uses the same one:

```elixir
@spec client_start_error(term()) :: client_start_error()
@type client_start_error ::
        :invalid_cwd | :not_found | model_error() | {:start_failed, String.t()}
```

- `:invalid_cwd`, `:not_found`, `{:unknown_provider, id}`, and `{:bad_provider_turn, id}` pass unchanged. `start/2` never returns `:not_found`; only `resume/2` does.
- `{:invalid_model_ref, ref}` passes only when the ref is within the bounds of `Helyx.ModelRef`: valid UTF-8 of at most 256 bytes, with no whitespace and no character of Unicode category C (`Helyx.ModelRef.bounded?/1`, which `parse/1` also uses). Such a ref failed to parse only for its form, a missing slash or an empty part, and it is safe to print. On a resume the ref comes from the session file, which can hold up to 64 MiB. Any other ref becomes `{:start_failed, text}`, and the log has it.
- Any other term becomes `{:start_failed, "the session did not start; the server log has the reason"}`. The function logs the full term as a warning.
- `start/2` and `resume/2` do not change: the product gets the full term. A transport calls `start/2` or `resume/2`, then gives the client the result of `client_start_error/1`.

The text is fixed. A reason can hold a path, a module, or an exception message from a plugin, and a remote client must not get these. The log has them.

### The TUI

- `mount/1` calls `subscribe/1` first. On `{:error, :session_not_found}` it exits with `{:session_down, :session_not_found}`. The `try` and the alive check before the subscribe are gone.
- The monitor still needs a pid (ticket 2 of ADR 0006 removes it). After the subscribe, `mount/1` reads the pid with `Session.pid/1`. A session that ended between the subscribe and this read gives `nil`, and the mount exits with `{:session_down, :session_not_found}` too, so one state has one reason. A session that ends after the monitor is set gives a `:DOWN`.
- A steer or a follow-up that returns `{:error, :session_not_found}` keeps the text in the composer, and the status bar says "not sent: the session ended". The `:DOWN` of the monitor then ends the TUI.
- `/model` that returns `{:error, :session_not_found}` shows the notice "the session ended". The helper that makes the notice text is `switch_error/1`, not `model_error/1`, because it now also names this error.

`CodingAgent.run/1` drops the `try` around `Session.abort/1`, because the abort of an ended session now returns an error.

## Bounds

| What | Bound | Where enforced | Over the bound |
| --- | --- | --- | --- |
| each operation call | `GenServer.call` with the default 5,000 ms timeout; `abort/1` waits with `:infinity`, as before | `Helyx.Session` | a timeout exits, as before; a subscribe first removes its entry |
| `{:start_failed, text}` | a fixed text of 56 bytes | `Helyx.Session.client_start_error/1` | n/a |
| `{:invalid_model_ref, ref}` | the bounds of `Helyx.ModelRef`: 256 bytes of valid UTF-8, no whitespace, no category C character | `Helyx.Session.client_start_error/1` through `Helyx.ModelRef.bounded?/1` | `{:start_failed, text}`, and the log has the ref |
| `{:unknown_provider, id}`, `{:bad_provider_turn, id}` | the provider id of a parsed ref, which `Helyx.ModelRef` bounds | `Helyx.ModelRef.parse/1` | n/a |
| log line of a start error | the full term through `inspect/1` with its default limits. The limits apply to each collection, not to the whole line, so a deeply nested term makes a long line | `Helyx.Session.client_start_error/1` | `inspect/1` cuts each long list or binary with `...` |
| registrations of one caller for one session | one | `Helyx.Session.subscribe/1` | a second subscribe does not register again |
| TUI texts | "not sent: the session ended" and "the session ended" are fixed | `Helyx.TUI` | n/a |

## Ownership

No new resource. A subscribe to a session that is not running removes the caller's entry for the session in the events Registry before it returns. An event that the session sent before the removal stays in the caller's mailbox, and the caller owns it (the accepted hole). The client drops it by `instance_id` and `seq` (#204).

## Out of scope

- The end signal, and a TUI that does not use `Session.pid/1`: ticket 2 of ADR 0006.
- `contract_version` in the snapshot: ticket 3.
- A transport that uses `client_start_error/1`: the first remote transport.
- Session instance identity: #204, `docs/features/session-instance.md`. A resume reuses the session id and starts `seq` at 0, and two Cores can hold one id, so every event and snapshot carry an `instance_id`, and a client drops each event of another instance.
- A text of `{:start_failed, text}` that names the reason. Add it when a person needs more than the log.
