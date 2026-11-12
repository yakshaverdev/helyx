# 2026-11-12: the print signal test that failed at the gate

`apps/coding_agent/test/coding_agent/print_signal_test.exs`, "SIGTERM with
stdout blocked ends the run with 143 in the bound", failed in 3 of 4 gate runs
on the Linux host, at `await_answer/1` (line 55), with "the condition did not
hold in time". The other rows of the module passed.

## Cause

A crash in the server, not a slow boot. The test dir of a failed run on the
host (`~/precommit/w1c/apps/coding_agent/tmp/CodingAgent.PrintSignalTest/...`)
still held the run's `err`:

```text
helyx: could not run the prompt: no connection to the server
...
** (ArgumentError) ... :erlang.binary_to_existing_atom("answers")
    lib/helyx/transport/web_socket/ops.ex:295: Ops.keyword/1
    lib/helyx/transport/web_socket/ops.ex:191: Ops.subscribe_params/2
    lib/helyx/transport/web_socket/connection.ex:127: request/4
```

`Helyx.Transport.WebSocket.Ops.keyword/1` turned the keys of a wire param into
atoms with `String.to_existing_atom/1`. The atom of a key exists only when some
module that names it is loaded, and `:answers` is named by the session modules
(`Helyx.Session.History`, `Events`) alone. Print mode starts a server in its own
VM, so the connection process that reads `subscribe` and the session server
that loads those modules run at once: when the connection won, `subscribe`
raised, the connection died, the print run ended with 1 before its turn, no
session file held "assistant", and the wait timed out.

Reproduced with no race, in a VM with the two ebins of Helyx:

```sh
elixir -pa <helyx_plugins ebin> -pa <helyx ebin> -e \
  'Helyx.Transport.WebSocket.Ops.subscribe_params(Helyx.Core, %{"session" => "abc", "answers" => true})'
# ** (ArgumentError) ... binary_to_existing_atom("answers")
```

The in-process tests never saw it: their VM loads `Helyx.Session.History` for
other reasons, so the atom is there.

## The other bound in the same path

The gate timeline (a throwaway watcher in the test dir; `pid` is the child VM's
pid file, before the apps) found a second, latent failure: the client gave the
server that print mode starts **5,000 ms** (`CodingAgent.Serve.wait_ms/0`, the
bound of the read of the file of a running server), and the boot took most of
it:

| Run | pid | `server.json` | session file | answer |
| --- | --- | --- | --- | --- |
| gate a | 2.5 s | 7.1 s (4.7 s after the start) | 10.7 s | 12.4 s |
| gate b | 0.7 s | 3.4 s (2.7 s) | 7.6 s | 10.2 s |
| gate c | 1.9 s | — | — | 8.4 s |
| alone | 0.2 s | 0.9 s | 1.0 s | 1.1 s |

With a 6 s delay in the server's start, the run gave exactly the symptom of the
flake: `could not attach to the server of <dir> in 5000 ms: the server did not
start`, status 1, no session file.

## Fix

- `Helyx.Transport.WebSocket.Ops`: `@option_atoms` names the atoms of the keys
  that `keyword/1` converts, so the transport holds them. A test
  (`plugins/bundled/test/helyx/transport/web_socket/ops_test.exs`) runs a
  `subscribe` in a fresh VM and fails before the fix.
- `CodingAgent.Attach`: a server that the client starts waits
  `start_ms/0` (15,000 ms, three times the measured start), for the launcher
  and for the VM of `mix helyx`; `connect/1` keeps `Serve.wait_ms/0`. A
  launcher that takes 6 s to start a server is attached to (new test in
  `attach_test.exs`).
- `print_signal_test.exs`: the wait reads `Attach.start_ms/0`, and a run that
  ends before the answer fails at once with its stderr instead of a bare
  timeout.

## Next

`Helyx.Hub.Api.answer/1` still turns a wire error code into an atom with
`String.to_existing_atom/1`. The codes come from the Hub of the same VM today,
so the atoms exist; a Hub in another VM would make it a fresh-VM bug of the
same class.
