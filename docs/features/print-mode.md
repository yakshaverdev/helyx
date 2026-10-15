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
- **Output.** Text only. stdout holds only the final answer: the text of the last assistant message of the last turn, then one newline. The session id, the notices, and the errors go to stderr, one line each, after `helyx: `. A JSON lines event stream waits for the Transport plugin, so that Helyx has one wire format.
- **Exit status.**
  - 0: the last turn ends normally (`:turn_end` with outcome `:done`).
  - 1: a bad argument or input, a failed start, a failed turn, an aborted turn, a session that stops, a last message that stopped at the output limit (`:max_tokens`), or background runs with a held end (`docs/features/print-background-wait.md`). At the output limit the text is still printed, and a stderr line says that it was cut. A failed or aborted turn prints nothing on stdout.
  - 143 on SIGTERM and 129 on SIGHUP. The BEAM stops with status 0 on SIGTERM and dies at once on SIGHUP by default, so print mode traps both signals. Its first step installs the trap, before the logger change, the read of stdin, and any output, and the trap is never removed: every print run ends with a halt of the VM, also a failed start, a bad stdin, and an error line. The first signal aborts the turn, waits at most 3 s for the abort, and halts the VM with the status and no flush (`:erlang.halt(status, flush: false)`). The signal path never waits on output: a stdout or stderr pipe that nobody reads, a stdin pipe that stays open, or a start that hangs does not hold the exit. The first SIGTERM or SIGHUP sets the status; later ones are ignored. Every other signal keeps the OTP default, as in a plain VM: SIGQUIT halts at once with 0, SIGUSR1 writes `erl_crash.dump` and halts with 1, also during the abort wait of a SIGTERM or SIGHUP, where it replaces the status of that signal. (Owner decisions of 2026-10-13 and 2026-10-14, after review rounds 2, 3, and 6.)
- **No timeout inside Helyx.** The caller uses `timeout(1)`, which sends SIGTERM.
- **Session.** A print run saves a normal session under the sessions directory, or appends to the session it resumes, and prints `helyx: session <id>` on stderr when the session starts. No opt-out flag.
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
- **Resume (#574, owner, 2026-10-14).** `-p` combines with `--session <id>` and with `--resume`, through the resume path of the TUI (`CodingAgent.run/1` with `resume:`). The run continues that session with the one prompt, with the same output, stderr lines, signal rules, and exit status. `--session` keeps its rule: the session runs in the folder of its header, and a directory argument is an error. A resumed session keeps its saved model, so `--model` with `--session` or `--resume` stays an error. The session line names the resumed id. No lock: a session must be open in one process at a time (see "Accepted holes"; the lock is ticket 579).

Decision of the worker (not in #491):

- **Print mode is a client.** It subscribes to the session and reads its events, as the TUI does. Core gets no print-mode code.

## Interface changes

- `CodingAgent.CLI`: the switch `-p TEXT` / `--print TEXT`. It combines with `--model` and a directory argument, or with `--resume` (and a directory argument), or with `--session`. It does not combine with `--list`. `--session` and the directory argument are checked inside print mode, after the trap. A value that starts with `-` stays the value, as for `--session`. `main/2` takes `halt` (default `&:erlang.halt(&1, flush: false)`); with `-p` it runs `Print.main/2`, which ends with `halt` and the status (0, 1, 129, or 143) and does not return. Tests pass a `halt` that reports the status and returns it. The other commands return 0 or 1 as before.
- `CodingAgent.run/1` takes the option `:prompt`. With it, `CodingAgent.Print.run/2` is the client in place of the TUI, and `run/1` returns its exit status. Core and the session start and stop as before.
- `CodingAgent.Print` (new):
  - `main(fun, halt \\ &:erlang.halt(&1, flush: false))` runs `fun` as the whole of print mode. The calling process is the halter: after the trap it only starts the run in a process of its own (`spawn_monitor/1`), waits for its `:DOWN`, and halts. It runs no user code and writes nothing, so no way the run ends can skip the halt (up to the process limit of the VM, see "Accepted holes"). In this order:
    1. SIGTERM and SIGHUP are trapped: it swaps the default handler of `:erl_signal_server` for its own and sets SIGHUP to `:handle`. This is the first step, before any output. The handler starts a stop process on the first SIGTERM or SIGHUP and ignores later ones, so the signal server never waits. Every other signal goes to the OTP default (`erl_signal_handler`): SIGUSR1 and SIGQUIT halt the VM, the rest are ignored, as in a plain VM. The stop process aborts the session that `run/2` named (or none, before `run/2` names one: the session can already run, but it has no prompt yet), in a process of its own that it does not link, waits for that process to end for at most `abort_ms/0` (3,000 ms), and calls `halt` with the status.
    2. The halter starts the run process and waits for its `:DOWN`. The run process does steps 3 and 4 and ends with `exit({:shutdown, status})`.
    3. The run process sends the log to stderr: the `:default` logger handler writes to stdout, and its output type is fixed when it is added, so the run removes it and adds it again with the type `:standard_error`. Without this, a warning of Core (a failed turn logs one) reaches stdout. App config cannot set the type: under `mix helyx`, Logger starts before the app config loads (probed: a `config/config.exs` with the type left the warning on stdout).
    4. The run process calls `fun`, which returns the status, or `{:error, text}`, written as one stderr line, with status 1. A raise, throw, or exit of `fun` is caught and ends the same way: one stderr line with its banner (`Exception.format_banner/2`, through the clean pass), and status 1.
    5. On `:DOWN`, the halter takes the status from the reason `{:shutdown, 0 | 1}`. Any other reason gives 1: a raise in the error line (stderr on a pipe whose reader has exited), the exit signal of a linked process (Core is linked to the run), a raise in the logger swap, or a kill of the run process. The halter writes no line for these. A raise in the run process logs a short report on stderr ("Process ... raised an exception", then the error, two lines or more); a linked crash or a kill ends with 1 and no line.
    6. The halter asks the handler to finish. The handler answers in one call, so the answer and a signal cannot both win: when no stop has started, the handler marks the run as done, so a later SIGTERM or SIGHUP is ignored, and `main/2` calls `halt` with the status; when a stop has started, `main/2` waits for its halt, so the status of the signal stands. Nothing is put back: the halt ends the VM.
  - `prompt(text)` returns `{:ok, prompt}` with the piped input added, or `{:error, text}` when the input is over the bound or not UTF-8.
  - `run(session, prompt)` names `session` to the signal handler, subscribes, prints the session id, sends the prompt, and waits until the session settles: the end of the turn, or of the last turn that the ends of its background runs open (`docs/features/print-background-wait.md`). It returns 0 or 1. It runs inside the run process of `main/2`.
- `CodingAgent.clean_line/1` (new, public): the clean pass of `one_line/1` and the 4,000-byte cap that `error_text/1` ends with.
- `Mix.Tasks.Helyx` passes the status of `main/2` to Mix. With `-p`, print mode halts the VM itself, so `mix helyx -p` exits with 0, 1, 129, or 143 and does not return to Mix. The release launcher (`System.halt(CodingAgent.CLI.main(System.argv()))`) does not change.

## Replaced mechanism

none. The TUI path does not change. `CodingAgent.run/1` picks the client from the options.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| piped stdin | 1,048,576 bytes (1 MiB), valid UTF-8, read as raw bytes: the device is set to latin1 and read with `:file.read/2` (probed on OTP 28: in unicode mode the device changes the bytes). The session file holds at most 64 MiB, and 1 MiB is about 250,000 tokens, more than the context window of the models that Helyx runs. The read takes at most one byte more than the bound | one line on stderr, status 1, before any application starts | `CodingAgent.Print.prompt/1` |
| stdin that stays open | not bounded: the read waits for the end of the input. A caller that keeps a pipe open and sends nothing gives `</dev/null`, or `timeout(1)` stops the run with 143 | a signal halts the VM | `CodingAgent.Print.prompt/1` |
| the session of `--session` or `--resume` | the bounds of `Helyx.Session.File`: at most 256 files of the folder scanned, a header of at most 65,536 bytes, a file of at most 64 MiB, and a heap cap for its decode | the resume error, one stderr line, status 1 | `Helyx.Session.File.resume/3` |
| `-p` value | valid UTF-8 (the command line check); its length is the bound of the OS on arguments. An empty value is a prompt too: the turn runs with it | the argument error, status 1 | `CodingAgent.CLI` |
| wait for the end of the turn | none inside Helyx (owner decision); the end of the session ends it, and a signal halts the VM | n/a | `CodingAgent.Print.run/2` |
| wait with no turn, for running background runs | the longest remaining `timeout` of the running runs (at most 86,400 s each), plus the release grace; the whole run has no bound (`docs/features/print-background-wait.md`, "Bounds") | a signal halts the VM | `Helyx.Tool.Bash.run/2`, the hands |
| wait for the abort after a signal | 3,000 ms (`abort_ms/0`): the abort releases the provider and the tools, or reports them as not confirmed, and the halt can drop that report; a turn that is not aborted by then is cut by the halt. From the signal to the exit: at most this bound, whatever stdout, stderr, and stdin do, from the first step of `main/2` to the halt | the halt with no abort | `CodingAgent.Print.Signal` |
| state of the wait | the last assistant message of the turn and the last counts of the session (`queue_update`); the deltas are not kept | n/a | `CodingAgent.Print.run/2` |
| answer on stdout | the text of one assistant message, as the provider sent it; the provider and its output limit bound it. The write has no time bound: a pipe that nobody reads blocks it, and a signal halts the VM with no flush | n/a | `CodingAgent.Print.run/2` |
| stderr lines | one line each: a fixed sentence, or a sentence with the session id, the turn error, a notice text, or a start error, after the clean pass and the 4,000-byte cap of `CodingAgent.clean_line/1`, which the one stderr writer of print mode applies to every line | n/a | `CodingAgent.Print` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the signal handler in `:erl_signal_server` | `main/2`, first step | the VM, until the halt | never removed: `main/2` calls `halt` | any end of the run process is a `:DOWN` to the halter, and the halt follows; a kill of the halter (the CLI process) leaves the handler in place, and a signal halts the VM | the stop process halts the VM |
| the stop process, and its abort process | the signal handler, on the first signal | nobody: not linked | the halt ends both | a crash of the abort ends its wait; the halt follows | the halt |
| the SIGHUP setting `:handle` | `main/2`, first step | the VM, until the halt | never set back: the halt | as on normal end | the halt |
| the `:default` logger handler on stderr | the run process of `main/2` | the VM, until the halt | never put back: the halt; a log line in the swap window is lost | as on normal end | the halt |
| stdin encoding `:latin1` (raw bytes) | `prompt/1` | the run process | it sets `:unicode` back after the read | `after` sets it back | the halt |
| Core and the provider process | `CodingAgent.run/1` | the run process (linked) | `after`: abort, then `Supervisor.stop/1` | a crash of the run: the link stops Core; then the halt | after a signal: the abort of the stop process, then the halt |

## Accepted holes

- Two processes on one session: since #579 the second open fails with `helyx: session <id> is open in another process` and status 1 (`docs/features/session-lock.md`). (Owner decision of 2026-10-14, in #574.)
- `--resume` takes the session of the folder that started last (the `ts` of its header) and has a message, as the TUI does; it is not the session that changed last. The id of a resumed session is the name of its file, and a file whose name is not a session id or whose header `--list` does not accept is skipped, as `--list` skips it (#581, #585).
- The answer goes to stdout as the provider sent it, with no clean pass: a script reads the exact text. Escape sequences in it reach a terminal when stdout is one.
- A turn that the provider starts by itself before the prompt makes the prompt fail with `:turn_running`; the run then fails with status 1.
- SIGINT (Ctrl+C) keeps the BEAM default: the break menu, or an exit with no abort. `os:set_signal/2` cannot handle SIGINT. (Accepted by the owner.)
- The trap starts with the first step of print mode. Before it, the VM boots and `CodingAgent.CLI` checks the options and their combination (an argument error or a bad combination writes its line there, with status 1; the directory argument and the session of `--session` are checked inside print mode); a signal in that span gets the BEAM default. The first step itself is two calls, the swap of the handler and then `:os.set_signal(:sighup, :handle)`: a SIGHUP between them gets the OS default and kills the VM with no status 129, as a SIGHUP during the boot does (the other order does not close the window, because `erl_signal_handler` ignores SIGHUP). No session and no output exist yet. This is the known ceiling of the signal guarantee. (Owner decision of 2026-10-13, after review round 4.)
- At the process limit of the VM, a `spawn` of print mode can fail, and the halt can be lost. In the handler (the stop process), gen_event removes the handler, so the signal gives no halt, and the halter's `:finish` call then fails. In the stop (its abort process), the handler is already done, so the halter sleeps and nothing halts. In the halter (the run process), the halter raises before it waits, with no signal. (Owner decision of 2026-10-14, after review round 6.)
- The halt does not flush: a log line that the logger has not written yet is lost at the halt. The lines of print mode are written by the run process before it ends, so before the halt. The log line of a raise in the run process can be dropped by the halt too.
- After a signal, output that has not reached the pipe is lost: the halt does not flush it. The answer of a run that a signal ends is not complete.
- A turn that the abort does not end in 3,000 ms is cut by the halt: a tool process that the abort did not stop by then can outlive the VM.
- A start that hangs (a plugin that hangs in its init) is ended by a signal like any other state; Core was not started, so nothing is aborted. (Codex, review round 2; accepted by the owner.)
- Log lines reach stderr in the format of the `:default` logger handler, with no clean pass and no 4,000-byte cap: a multi-line or long log message stays so. The 4,000-byte bound of the stderr row holds for the lines of print mode only. (Accepted by the owner.)
- `mix helyx` prints the output of a compile on stdout when the source changed since the last build. The release has no compile.

## Open

Small items from review rounds 3 to 7 of #491:

- A SIGQUIT or SIGUSR1 during the abort wait of a SIGTERM or SIGHUP halts the VM at once with the OTP status, so a SIGQUIT turns 143 into 0, which a caller reads as success; a SIGQUIT alone also gives 0. Two rules meet here ("the first owned signal sets the status" and "every other signal acts as in a plain VM"), and the plain-VM rule wins now. (Judgement, review round 7.)

- The test "SIGTERM during the turn aborts it, then halts with 143" does not prove that the abort comes before the halt: it can subscribe and assert `turn_end` before `{:halt, 143}`.
- The stderr case of `print_signal_test.exs` reaches the blocked write after a fixed 1 s sleep, not after a state marker.
- No test for: a raise of `fun` (one line and 1; only a throw and an exit are tested), a kill of the run process (1), a raise in the logger swap (1), a signal after the run finished (ignored). Probes pass for each.
- No test runs `mix helyx -p`; the signal tests use `elixir -e` with `CodingAgent.CLI.main/2`.
- The second-signal case of `print_signal_test.exs` orders its events by sleeps (the run returns 2 s after the trap, SIGTERM about 1 s after it): a margin of about 1 s, with no `load_` attribute. Under load the SIGTERM can come after the run returns, and the test then reads 0.

## Out of scope

- JSON lines output (the Transport plugin).
- Several prompts in one run. A model switch in print mode.
- A turn or budget limit.
- The approval gate and its print-mode rule (#503).
