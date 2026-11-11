# Print mode

## Goal

A script or another program gives the coding agent one prompt and reads the answer (#491). Before this, the agent ran only as the interactive TUI.

```sh
helyx -p "fix the failing test"
cat log | helyx -p "why does this fail"
helyx --list                    # shows the print run
helyx --session <id>            # continues it in the TUI
helyx -p "now run the tests" --session <id>   # or with one more print run
```

Decisions (owner, 2026-10-13, in #491):

- **Start.** Print mode starts only with `-p` (or `--print`), never from a TTY check. The value of `-p` is the prompt.
- **Output.** Text only. stdout holds only the final answer: the text of the last assistant message of the last turn, then one newline. The session id, the notices, and the errors go to stderr, one line each, after `helyx: `. A JSON lines event stream waits for the stdio form of the wire (ADR 0008), so that Helyx has one wire format.
- **Exit status.**
  - 0: the last turn ends normally (`:turn_end` with outcome `:done`).
  - 1: a bad argument or input, a failed start, a failed turn, an aborted turn, a session that stops, a connection that ends, a last message that stopped at the output limit (`:max_tokens`), or background runs with a held end (`docs/features/print-background-wait.md`). At the output limit the text is still printed, and a stderr line says that it was cut. A failed or aborted turn prints nothing on stdout.
  - 143 on SIGTERM and 129 on SIGHUP. The BEAM stops with status 0 on SIGTERM and dies at once on SIGHUP by default, so print mode traps both signals. Its first step installs the trap, before the logger change, the read of stdin, and any output, and the trap is never removed: every print run ends with a halt of the VM, also a failed start, a bad stdin, and an error line. The first signal ends the session's turn (see "Signals"), waits at most 3 s for that end, and halts the VM with the status and no flush (`:erlang.halt(status, flush: false)`). The signal path never waits on output: a stdout or stderr pipe that nobody reads, a stdin pipe that stays open, or a start that hangs does not hold the exit. The first SIGTERM or SIGHUP sets the status; later ones are ignored. Every other signal keeps the OTP default, as in a plain VM: SIGQUIT halts at once with 0, and SIGUSR1 writes `erl_crash.dump` and halts with 1. During the wait for the end of a SIGTERM or SIGHUP, every signal is ignored, so a later one cannot replace the first status. (Owner decisions of 2026-10-13 and 2026-10-14, and ADR 0014 for the stop rule.)
- **No timeout inside Helyx.** The caller uses `timeout(1)`, which sends SIGTERM.
- **Session.** The server saves a normal session under its sessions directory, or appends to the session the run resumes, and print mode prints `helyx: session <id>` on stderr when the session opens. No opt-out flag.
- **Piped stdin.** When stdin is not a terminal, print mode reads it to the end before the agent starts. Input that is not empty is added after the prompt as a block:

  ```text
  <prompt>

  <stdin>
  <the input>
  </stdin>
  ```

- **Background runs (#591, owner, 2026-10-14 and 2026-10-15).** Print mode stays while the session counts a running background run or a waiting end, and exits when the session settles, with the answer and the status of the last turn. A held end does not hold it. Core counts the runs; print mode reads no text, tool name, or arguments. The design is in `docs/features/print-background-wait.md`.
- **No user.** Nobody can steer or approve. No approval gate exists yet, so the tools run. #503 adds the gate and its print-mode rule.
- **Refusal.** A last message with the stop reason `:refused` ends the turn normally (outcome `:done`), so the status is 0. Its text is printed, and a stderr line says that the provider refused or filtered the answer, as the TUI says. (Proposed by the worker, kept by the owner on 2026-10-13.)
- **Resume (#574, owner, 2026-10-14).** `-p` combines with `--session <id>` and with `--resume`, through the resume path of the TUI (`CodingAgent.print/3` with `resume:`). The run continues that session with the one prompt, with the same output, stderr lines, signal rules, and exit status. `--session` keeps its rule: the session runs in the folder of its header, and a directory argument is an error. A resumed session keeps its saved model, so `--model` with `--session` or `--resume` stays an error. The session line names the resumed id. No lock: a session is open in one server at a time (see "Accepted holes"; the lock is ticket 579).

Decision of the worker (not in #491):

- **Print mode is a client.** It subscribes to the session and reads its events, as the TUI does. Core gets no print-mode code.

Decisions (owner, 2026-11-11): every command of `helyx` uses the server over the wire.

- **The server.** Print mode is a client of the server of the data folder, as the TUI is, and every operation of its session goes over the wire. With no server, the `helyx` of the release starts `helyx serve` in the background and leaves it running; `mix helyx` runs the server in its own VM until the print run ends.
- **A session that runs.** A print run on a session that another client has open (`--session id`, or `--resume` when the newest session is live) joins it: the prompt runs there, and the other client sees the turn. The line `session <id> is open in another process` no longer happens for a print run next to a TUI. If the session has a turn running, the prompt fails with the error of the server, `turn_running`, and status 1.
- **The model.** With no `--model` a new print session takes the default model of the server.
- **The end.** A print run stops its own session at its end, and on SIGTERM or SIGHUP. The server keeps at most 64 live sessions and evicts none, so a script that runs `helyx -p` many times leaves no idle session for each run. A session that was live before the run stays live and gets only an abort of its turn.
- **A killed client.** A print client that is killed with SIGKILL leaves its session running in the server.
- **Signals.** The signal handler holds a function in place of the session: `CodingAgent.print/3` gives it `Connection.stop/2` for the session that the run opened, or `Connection.abort/2` for a session that was live before. The request is on the wire before the halt, so the server ends the turn even when the halt comes first.

## Interface changes

- `CodingAgent.CLI`: the switch `-p TEXT` / `--print TEXT`. It combines with `--model` and a directory argument, or with `--resume` (and a directory argument), or with `--session`. It does not combine with `--list`. `--session` and the directory argument are checked inside print mode, after the trap. A value that starts with `-` stays the value, as for `--session`. `main/2` takes `halt` (default `&:erlang.halt(&1, flush: false)`); with `-p` it runs `Print.main/2`, which ends with `halt` and the status (0, 1, 129, or 143) and does not return. Tests pass a `halt` that reports the status and returns it. The other commands return 0 or 1 as before.
- `CodingAgent.print/3` takes `socket` and `ws` from `CodingAgent.Attach.connect/1`, the options `:prompt` (required), `:cwd`, `:model` (optional), and `:resume` (`false`, `true`, or an id), and returns the exit status of `CodingAgent.Print.run/5`, or `{:error, reason}` with the errors of the wire. It opens the connection, reads `sessions.live` before and after the open, and runs the prompt. A session that was not live before the run is the run's own. In an `after` it stops that session, or aborts the turn of one that was live before, and then ends the connection.
- `CodingAgent.Print` (new):
  - `main(fun, halt \\ &:erlang.halt(&1, flush: false))` runs `fun` as the whole of print mode. The calling process is the halter: after the trap it only starts the run in a process of its own (`spawn_monitor/1`), waits for its `:DOWN`, and halts. It runs no user code and writes nothing, so no way the run ends can skip the halt (up to the process limit of the VM, see "Accepted holes"). In this order:
    1. SIGTERM and SIGHUP are trapped: it swaps the default handler of `:erl_signal_server` for its own and sets SIGHUP to `:handle`. This is the first step, before any output. The handler starts a stop process on the first SIGTERM or SIGHUP and ignores later ones, so the signal server never waits. Outside the stop, every other signal goes to the OTP default (`erl_signal_handler`): SIGUSR1 and SIGQUIT halt the VM, the rest are ignored, as in a plain VM. During the stop, the handler ignores every signal, so the first status wins. The stop process calls the function that `run/5` registered (or none, before `run/5` names it), in a process of its own that it does not link, waits for that process to end for at most `abort_ms/0` (3,000 ms), and calls `halt` with the status.
    2. The halter starts the run process and waits for its `:DOWN`. The run process does steps 3 and 4 and ends with `exit({:shutdown, status})`.
    3. The run process sends the log to stderr: the `:default` logger handler writes to stdout, and its output type is fixed when it is added, so the run removes it and adds it again with the type `:standard_error`. Without this, a warning of Core (a failed turn logs one) reaches stdout. App config cannot set the type: under `mix helyx`, Logger starts before the app config loads (probed: a `config/config.exs` with the type left the warning on stdout).
    4. The run process calls `fun`, which returns the status, or `{:error, text}`, written as one stderr line, with status 1. A raise, throw, or exit of `fun` is caught and ends the same way: one stderr line with its banner (`Exception.format_banner/2`, through the clean pass), and status 1.
    5. On `:DOWN`, the halter takes the status from the reason `{:shutdown, 0 | 1}`. Any other reason gives 1: a raise in the error line (stderr on a pipe whose reader has exited), the exit signal of a linked process, a raise in the logger swap, or a kill of the run process. The halter writes no line for these. A raise in the run process logs a short report on stderr ("Process ... raised an exception", then the error, two lines or more); a linked crash or a kill ends with 1 and no line.
    6. The halter asks the handler to finish. The handler answers in one call, so the answer and a signal cannot both win: when no stop has started, the handler marks the run as done, so a later SIGTERM or SIGHUP is ignored, and `main/2` calls `halt` with the status; when a stop has started, `main/2` waits for its halt, so the status of the signal stands. Nothing is put back: the halt ends the VM.
  - `prompt(text)` returns `{:ok, prompt}` with the piped input added, or `{:error, text}` when the input is over the bound or not UTF-8.
  - `run(conn, ref, id, prompt, stop)` names `stop` to the signal handler, subscribes to `id` over the connection, prints the session id, sends the prompt, and waits until the session settles: the end of the turn, or of the last turn that the ends of its background runs open (`docs/features/print-background-wait.md`). It returns 0 or 1. It runs inside the run process of `main/2`, which owns the connection and the monitor `ref`, so the events of the subscription come to it. A `{:helyx_end, sub, reason}` fails it as a session that stops, and the `:DOWN` of the connection as a connection that ends. The caller stops or aborts the session and ends the connection after it.
- `CodingAgent.clean_line/1` (new, public): the clean pass of `one_line/1` and the 4,000-byte cap that `error_text/1` ends with.
- `Mix.Tasks.Helyx` passes the status of `main/2` to Mix. With `-p`, print mode halts the VM itself, so `mix helyx -p` exits with 0, 1, 129, or 143 and does not return to Mix. The release launcher (`System.halt(CodingAgent.CLI.main(System.argv()))`) does not change.

## Replaced mechanism

none in #491. This change replaces the in-node path of print mode: `CodingAgent.run/1`, which started Core and a session in the CLI VM, and the in-node subscription of `CodingAgent.Print`. `CodingAgent.print/3` attaches to the server of the data folder, as the TUI does, with `prompt`, `sessions.live`, `start`, `resume`, `subscribe`, `ack`, `abort`, and `stop` over the wire. The design of the client is in `docs/features/tui-attach.md`.

Tests: the print tests run a server of the test VM (`Helyx.Core` with the providers of the tests and `Helyx.Transport.WebSocket`), and the CLI tests start one through `CodingAgent.Attach.serve/3`. The test of the node's `:slow` end of a subscription becomes the close `4408` of a slow client.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| piped stdin | 1,048,576 bytes (1 MiB), valid UTF-8, read as raw bytes: the device is set to latin1 and read with `:file.read/2` (probed on OTP 28: in unicode mode the device changes the bytes). One line of the session file holds at most 64 MiB, and 1 MiB is about 250,000 tokens, more than the context window of the models that Helyx runs. The read takes at most one byte more than the bound | one line on stderr, status 1, before any application starts | `CodingAgent.Print.prompt/1` |
| stdin that stays open | not bounded: the read waits for the end of the input. A caller that keeps a pipe open and sends nothing gives `</dev/null`, or `timeout(1)` stops the run with 143 | a signal halts the VM | `CodingAgent.Print.prompt/1` |
| the session of `--session` or `--resume` | the bounds of `Helyx.Session.File` in the server: at most 256 files of the folder scanned, a header of at most 65,536 bytes, a line of at most 64 MiB, and a heap cap for the decode of one line; the file has no size limit (#834) | the resume error of the server, one stderr line, status 1 | `Helyx.Session.File.pick/3` and `resume_picked/3` |
| `-p` value | valid UTF-8 (the command line check); its length is the bound of the OS on arguments. An empty value is a prompt too: the turn runs with it | the argument error, status 1 | `CodingAgent.CLI` |
| wait for the end of the turn | none inside Helyx (owner decision); the end of the session ends it, and a signal halts the VM | n/a | `CodingAgent.Print.run/5` |
| wait with no turn, for running background runs | the longest remaining `timeout` of the running runs (at most 86,400 s each), plus the release grace; the whole run has no bound (`docs/features/print-background-wait.md`, "Bounds") | a signal halts the VM | `Helyx.Tool.Bash.run/2`, the hands |
| wait for the end of the session after a signal | 3,000 ms (`abort_ms/0`): the stop or the abort releases the provider and the tools, or reports them as not confirmed, and the halt can drop that report; a turn that is not ended by then is cut by the halt. From the signal to the exit: at most this bound, whatever stdout, stderr, and stdin do, from the first step of `main/2` to the halt | the halt with no confirmed end | `CodingAgent.Print.Signal` |
| state of the wait | the last assistant message of the turn and the last counts of the session (`queue_update`); the deltas are not kept | n/a | `CodingAgent.Print.run/5` |
| answer on stdout | the text of one assistant message, as the provider sent it; the provider and its output limit bound it. The write has no time bound: a pipe that nobody reads blocks it, and a signal halts the VM with no flush | n/a | `CodingAgent.Print.run/5` |
| stderr lines | one line each: a fixed sentence, or a sentence with the session id, the turn error, a notice text, or a start error, after the clean pass and the 4,000-byte cap of `CodingAgent.clean_line/1`, which the one stderr writer of print mode applies to every line | n/a | `CodingAgent.Print` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the signal handler in `:erl_signal_server` | `main/2`, first step | the VM, until the halt | never removed: `main/2` calls `halt` | any end of the run process is a `:DOWN` to the halter, and the halt follows; a kill of the halter (the CLI process) leaves the handler in place, and a signal halts the VM | the stop process halts the VM |
| the stop process, and the process of its request | the signal handler, on the first signal | nobody: not linked | the halt ends both | a crash of the request ends its wait; the halt follows | the halt |
| the SIGHUP setting `:handle` | `main/2`, first step | the VM, until the halt | never set back: the halt | as on normal end | the halt |
| the `:default` logger handler on stderr | the run process of `main/2` | the VM, until the halt | never put back: the halt; a log line in the swap window is lost | as on normal end | the halt |
| stdin encoding `:latin1` (raw bytes) | `prompt/1` | the run process | it sets `:unicode` back after the read | `after` sets it back | the halt |
| the connection, the session, and the provider process | `CodingAgent.print/3` takes the connection of `CodingAgent.Attach.connect/1`; the server starts the session and its provider | the run process owns the connection; the server owns the session | `after`: `stop` or `abort`, then the connection ends | a kill of the run ends the connection, and the session runs on in the server (an accepted hole) | after a signal: the request of the stop process, then the halt |

## Accepted holes

- A session that was live before the run keeps running, and the run only aborts its turn. The gap between `sessions.live` before the open and the open itself is a hole: a client that opens the same saved session in that gap sees its session end when the print run ends, and can resume it. (Decision of 2026-11-11.)
- A print client that is killed with SIGKILL leaves its session running in the server: no `after` runs, and the server stops no session at its cap. (Decision of 2026-11-11.)
- A lock that another OS process holds on the session file is still an error, with the term of the server (`{:session_locked, id}`) in the line; it does not happen for a client of the server (see "A session that runs").
- `--resume` takes the session of the folder that started last (the `ts` of its header) and has a message, as the TUI does; it is not the session that changed last. The id of a resumed session is the name of its file, and a file whose name is not a session id or whose header `--list` does not accept is skipped, as `--list` skips it (#581, #585).
- The answer goes to stdout as the provider sent it, with no clean pass: a script reads the exact text. Escape sequences in it reach a terminal when stdout is one.
- A turn that the provider starts by itself before the prompt makes the prompt fail with `:turn_running`; the run then fails with status 1.
- SIGINT (Ctrl+C) keeps the BEAM default: the break menu, or an exit with no abort. `os:set_signal/2` cannot handle SIGINT. (Accepted by the owner.)
- The trap starts with the first step of print mode. Before it, the VM boots and `CodingAgent.CLI` checks the options and their combination (an argument error or a bad combination writes its line there, with status 1; the directory argument and the session of `--session` are checked inside print mode); a signal in that span gets the BEAM default. The first step itself is two calls, the swap of the handler and then `:os.set_signal(:sighup, :handle)`: a SIGHUP between them gets the OS default and kills the VM with no status 129, as a SIGHUP during the boot does (the other order does not close the window, because `erl_signal_handler` ignores SIGHUP). No session and no output exist yet. This is the known ceiling of the signal guarantee. (Owner decision of 2026-10-13, after review round 4.)
- At the process limit of the VM, a `spawn` of print mode can fail, and the halt can be lost. In the handler (the stop process), gen_event removes the handler, so the signal gives no halt, and the halter's `:finish` call then fails. In the stop (the process of its request), the handler is already done, so the halter sleeps and nothing halts. In the halter (the run process), the halter raises before it waits, with no signal. (Owner decision of 2026-10-14, after review round 6.)
- The halt does not flush: a log line that the logger has not written yet is lost at the halt. The lines of print mode are written by the run process before it ends, so before the halt. The log line of a raise in the run process can be dropped by the halt too.
- After a signal, output that has not reached the pipe is lost: the halt does not flush it. The answer of a run that a signal ends is not complete.
- A turn that the abort does not end in 3,000 ms is cut by the halt: a tool process that the abort did not stop by then can outlive the VM.
- A start that hangs (a plugin that hangs in its init) is ended by a signal like any other state; Core was not started, so nothing is aborted. (Codex, review round 2; accepted by the owner.)
- Log lines reach stderr in the format of the `:default` logger handler, with no clean pass and no 4,000-byte cap: a multi-line or long log message stays so. The 4,000-byte bound of the stderr row holds for the lines of print mode only. (Accepted by the owner.)
- `mix helyx` prints the output of a compile on stdout when the source changed since the last build. The release has no compile.

## Open

Small items from review rounds 3 to 7 of #491:

- The test "SIGTERM during the turn ends the session, then halts with 143" does not prove that the end of the session comes before the halt: it can subscribe and assert `turn_end` before `{:halt, 143}`.
- The stderr case of `print_signal_test.exs` reaches the blocked write after a fixed 1 s sleep, not after a state marker.
- No test for: a raise of `fun` (one line and 1; only a throw and an exit are tested), a kill of the run process (1), a raise in the logger swap (1), a signal after the run finished (ignored). Probes pass for each.
- No test runs `mix helyx -p`; the signal tests use `elixir -e` with `CodingAgent.CLI.main/2`.
- The second-signal case of `print_signal_test.exs` orders its events by sleeps (the run returns 2 s after the trap, SIGTERM about 1 s after it): a margin of about 1 s, with no `load_` attribute. Under load the SIGTERM can come after the run returns, and the test then reads 0.

## Out of scope

- JSON lines output (the stdio form of the wire, ADR 0008).
- Several prompts in one run. A model switch in print mode.
- A turn or budget limit.
- The approval gate and its print-mode rule (#503).
