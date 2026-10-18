# helyx serve

Ticket #661. Decisions of the orchestrator, 2026-10-18 (owner away), in the comment of the ticket.

## Goal

`helyx serve` runs the coding agent as a headless server: Core with the plugins of the agent, and `Helyx.Transport.WebSocket` (`docs/features/wire-protocol.md`). It stays up until SIGINT or SIGTERM. Clients connect over the wire. This is the step to the end state of ADR 0008: one long-running server owns the sessions.

User stories:

- A user runs `helyx serve` on a home machine and connects from the laptop and the phone, through an SSH tunnel or a TLS proxy.
- Two terminals start `helyx serve` in one data folder at the same moment. One server starts. The other exits 1 with a line that names the address of the first.

Decisions:

1. **The command.** `helyx serve [--host ip] [--port n] [--model provider/model]`. `serve` is the first argument; a folder with the name `serve` is `./serve`. The server starts Core and the transport and prints one line on stdout when it is ready: `helyx: serving on ws://<host>:<port>`. No output holds the token. `--model` is the default model of the server (the Core option `:model`), default the default model of the agent. A product owns its daemon: the server is in `apps/coding_agent`, not in Core and not in the transport.
2. **The stop is a Core stop.** SIGTERM, and SIGHUP, start the stop: the server removes the server file, stops the transport, which closes every connection, stops Core, and releases the lock. Then `helyx serve` exits 0. A Core stop ends each session in its `terminate/2`: the session file stays, and a running turn ends as a Core stop ends it (`docs/features/server-management.md`, Out of scope: no aborted results in the file; a resume gives the open calls interrupted results). Reason: the sessions are the state of the user; a stop of the server must not change them more than a crash does.
3. **SIGINT.** The BEAM cannot handle SIGINT (`os:set_signal/2` refuses it, OTP 28), and its break handler stops the VM with no Core stop. So the launcher of the release (`docs/features/local-release.md`) starts `serve` in its own process group, with perl (`setpgrp`), so the SIGINT of a terminal reaches only the launcher. The launcher stays in the foreground, traps SIGINT, SIGTERM, and SIGHUP before it starts the VM, and sends SIGTERM to the VM for each; a signal that comes before the pid of the VM is known sends SIGTERM once the pid is known. It exits with the status of the VM. Every other command keeps the `exec` of before. `mix helyx serve` has no launcher: SIGINT there keeps the BEAM default, as in print mode.
4. **One lock per data folder.** The data folder is the sessions folder, the storage root of Core (`:sessions_dir`, default `~/.helyx/sessions`). The lock is the `flock` of the session lock (`docs/features/session-lock.md`), on `<data folder>/server.lock`, taken with `Helyx.Session.Lock.take/1`. The serve process owns the port of the lock. No second lock mechanism. The server makes the data folder with `Helyx.Session.File.mkdir/1`, so a folder that it makes gets mode 0700, as at the start of a session (#683). It refuses a data folder that its group or other users can write (`helyx: other users can write the data folder <data folder>; run chmod go-w on it`, exit 1), before it takes the lock: such a user could swap `.server.tmp` after its chmod and get the token (decision 8). The parent folders of the data folder are the trust boundary of the user, as for the session files. The lock is taken before Core starts, so two starts cannot make two servers.
5. **A second start.** When the lock is held, `helyx serve` reads the server file and exits 1 with `helyx: a server runs for <data folder> at ws://<host>:<port>`. The holder writes the file after its listener is up, so the second start reads the file again every 100 ms, at most 5,000 ms. With no valid file in that time, it exits 1 with `helyx: a server holds the lock of <data folder> and gave no address in 5000 ms`.
6. **Listen.** `127.0.0.1` and a port that the OS picks, by default. `--host` takes an IPv4 or IPv6 address, not a host name; a name would need a resolve that can wait. `--port` takes 0 to 65535; 0 lets the OS pick. A host that is not loopback needs the explicit `--host`. No TLS: for another machine, use an SSH tunnel or a TLS proxy (ADR 0008 §6).
7. **Token.** Each start makes a new token: the base64url of 32 random bytes, with no padding, 43 characters. The token is the text of those 43 characters: a client computes the proof with the key `SHA-256(token)` over these bytes (`wire-protocol.md`, Connection). The transport needs the proof from every connection, also on loopback.
8. **The server file.** `<data folder>/server.json` holds `{"address", "port", "token", "protocol", "pid"}`: the listen address as text, the port that the listener has, the token, `Helyx.Transport.WebSocket.protocol/0`, and the OS pid of the VM. The server removes a `server.json` that it finds as soon as it holds the lock: the file of a server that was killed must not pass for this one while it starts. When the remove fails, the start releases the lock and exits 1 with `helyx: could not remove the stale server file: <reason>`. It writes the new file after the listener is up: it removes the folder `.server.tmp` of a start that was killed, makes it again with mode 0700, writes `server.json` in it with `O_EXCL`, sets the mode of the file to 0600, renames the file to `<data folder>/server.json`, and removes the folder. No other user can open the file while its mode is the umask mode, also in a data folder of mode 0755. `O_EXCL` refuses a file or a link that another user put in `.server.tmp` before its chmod, and no other user can swap `.server.tmp` itself, because the server refuses a data folder that they can write (decision 4). A reader sees no file or the whole new one. The file is the readiness signal: a client that finds it while the lock is held can connect. A clean stop removes it. A file with no lock holder is stale: the next start replaces it, and a client takes it as no server (#662).
9. **Handshake.** The `challenge` and `hello` of #763 is the version check. A client that gets `refused` shows its protocol number and the `server_protocol` of the frame (#662).
10. **The end of a part.** A crash of Core or of the transport, or the end of the perl process of the lock, stops the server by the same stop, and `helyx serve` exits 1 with one line. After the end of the lock, the stop does not remove `server.json`: another server can hold the lock by then, and the file can be its file. A file that this server left is stale, and the next start replaces it. Reason: with no lock, a second server can start; with no Core or no listener, the server serves nothing.

## Interface changes

- `CodingAgent.CLI`: the command `serve` with the new switches `--host ip` and `--port n`, and `--model`. `--host` and `--port` without `serve` give `--host needs serve`. `serve` with a directory argument or with another switch gives one error line; `--help` and `--version` keep their rule and win over `serve`. The usage, the switch lines, and the exit statuses in `--help` name it.
- `CodingAgent.Serve.run/1` (new): runs the server until a stop, and returns `:ok` after a stop by a signal, or `{:error, text}`. The handler in `:erl_signal_server` is global, so a caller runs one server in a VM at a time; `helyx serve` runs one VM for each server.
- `Helyx.Session.File.mkdir/1` (new): makes the sessions folder alone, with the mode rule of `mkdir/3`, which now calls it.
- The serve process reads the server file with `Helyx.Session.File.Scan.read_up_to/2`, a public `@doc false` function of Core, as `Helyx.Session.File` does.
- `Helyx.Session.Lock.take/1` is public: the lock of `<path without extension>.lock`. The serve process calls it and `release/1`. The module stays `@moduledoc false` in Core: a product of this repository uses it, and no new interface is made.
- The launcher of `mix helyx.install`: a branch for `serve` (decision 3).
- `CodingAgent.error_text/1`: `{:invalid_option, :model}` gives `the model ref is not valid; use provider/model`.

## Replaced mechanism

1. **The launcher `exec` for every command.** The launcher ran `exec <release script> eval ... "$@"` for every argument list. For `serve` it now starts the VM in a new process group, waits for it, and forwards the signals. Every other command keeps the `exec`. Test: "installs the build under its commit and the launcher passes arguments and folder" keeps its property for a command that is not `serve`; a new test checks the serve branch with a fake release script.
2. **A directory argument named `serve`.** `helyx serve` ran the TUI in the folder `serve`. It now runs the server. `helyx ./serve` keeps the old meaning.
3. `CodingAgent.run/1` is not changed: it still stops Core at its end and aborts its session. The server does not call it.

## Bounds

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| `--port` | an integer from 0 to 65535 | one error line, exit 1 | `CodingAgent.CLI` |
| `--host` | an IPv4 or IPv6 address (`:inet.parse_address/1`) | one error line, exit 1 | `CodingAgent.CLI` |
| token | 32 random bytes, 43 characters of base64url | n/a | `CodingAgent.Serve` |
| wait for the answer of the lock | 5,000 ms (`Helyx.Session.Lock`) | `{:lock_failed, text}`: one error line, exit 1 | `Helyx.Session.Lock` |
| read of the server file by a second start | a regular file, checked before the open (`Helyx.Session.File.Scan.read_up_to/2`; see Accepted holes); 4,096 bytes; a JSON object with `address` an IP address and `port` an integer from 1 to 65535 | the file is not valid: the start reads again until the wait ends | `CodingAgent.Serve` |
| wait of a second start for the server file | 5,000 ms, a read every 100 ms | `a server holds the lock ... gave no address in 5000 ms`, exit 1 | `CodingAgent.Serve` |
| the address in an output line | the address that `:inet.ntoa/1` gives for a parsed address, never the text of the file | n/a | `CodingAgent.Serve` |
| stop of the transport | the `shutdown_timeout` of Thousand Island, 15,000 ms, for the open connections | Thousand Island kills the connections | the transport supervisor |
| stop of Core | the sessions stop in parallel (`DynamicSupervisor`), each within `Stop.shutdown_ms/0`, 31,000 ms | the supervisor kills the session; perl frees its lock at its end | Core |
| release of the lock | 1,000 ms (`Helyx.Session.Lock.release_ms/0`) | the release is unconfirmed; perl frees the lock when it ends | `Helyx.Session.Lock` |
| signals | the first SIGTERM or SIGHUP starts the stop; a later one does nothing | n/a | `CodingAgent.Serve` |
| connections, requests, frames | the bounds of `wire-protocol.md` | as there | the transport |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| `flock` on `server.lock` and its perl port | `Helyx.Session.Lock.take/1` in the serve process | the serve process | `Lock.release/1` at the end of the stop | the port closes with the serve process; perl exits on the end of its stdin, and the kernel frees the lock | n/a |
| `server.lock` file | perl | the disk | stays | stays | n/a |
| `.server.tmp` and the file in it | the serve process | the serve process | the file is renamed to `server.json`, and the folder is removed | stays; the next start removes it | n/a |
| `server.json` | the rename | the disk | removed at the start of the stop; after the end of the lock, left in place (decision 10) | stays; it is stale, and the next start removes it once it holds the lock. From the `flock` to that remove, a second start can read it: open, ticket #777 | n/a |
| the serve process | `CodingAgent.Serve.run/1`, with `spawn_monitor/1` | the caller of `run/1`, which waits for its `:DOWN`; no supervisor. Cap: one in a VM at a time (Interface changes) | it ends with the result of the stop | the `:DOWN` reaches `run/1`, which swaps the handler back; the links end Core, the transport, and the port of the lock | n/a |
| listen socket and connections | the transport | the transport supervisor, linked to the serve process | the stop of the transport | the link ends the transport with the serve process | n/a |
| Core and its sessions | the serve process | Core, linked to the serve process | the Core stop | the link ends Core: each session stops by its `terminate/2` | n/a |
| the handler in `:erl_signal_server`, with the id `{CodingAgent.Serve.Signal, <serve process>}` | the serve process, after the lock | the signal server | swapped back for the OTP handler by `run/1` after the serve process ends | `run/1` swaps it back after the `:DOWN` of the serve process; when the VM ends, it goes with it | n/a |
| read of `server.json` by a second start | the second start | the second start | closed by the read | n/a | a FIFO put in place between the type check and the open blocks the open past the wait: open, ticket #777 |
| status of the VM in the launcher | the launcher | the launcher | `wait` | n/a | the VM that ends while the trap runs can give 128 plus the signal number: open, ticket #777 |
| the VM process group, in the release | the launcher, through perl `setpgrp` | the launcher waits for it | the VM exits; the launcher exits with its status | a SIGKILL of the launcher leaves the VM and its server running: send it SIGTERM. Accepted hole | n/a |

## Accepted holes

- A SIGKILL of the VM leaves `server.json`. The kernel frees the lock at the exit of perl, so the file is stale, and the next start replaces it.
- A SIGKILL of the launcher leaves the VM running in its own process group (Ownership).
- `mix helyx serve` keeps the BEAM default for SIGINT (decision 3).
- The read of the server file by a second start checks the type of the path, then opens it: it is `Helyx.Session.File.Scan.read_up_to/2`, and `Helyx.ModelInfo.Catalog` reads with the same pattern. A FIFO put in place between the two blocks the open past the wait. Open, ticket #777. A FIFO that replaces the file between the two blocks the open past the wait. Only the owner of the data folder can make it, and the review of #661 reproduced it only with a loop that swapped the file.
- From the `flock` of perl to the remove of a stale `server.json`, a second start can read that file and name the address of the server that was killed. Open, ticket #777.
- The launcher reads the status of the VM with `wait`. When the VM ends while the launcher runs its trap, the shell can reap it in that window, and the launcher then exits with 128 plus the number of the signal in place of the status of the VM. Open, ticket #777.

## Out of scope

- The attach of the TUI to a server, and the start of a server in the background (#662).
- A service unit of the OS, and TLS.
