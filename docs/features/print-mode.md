# Print mode

## Goal

A script or another program gives the coding agent one prompt and reads the answer (#491). Before this, the agent ran only as the interactive TUI.

```sh
helyx -p "fix the failing test"
cat log | helyx -p "why does this fail"
helyx --list                    # shows the print run
helyx --session <id>            # continues it in the TUI
```

Decisions (owner, 2026-10-13, in #491):

- **Start.** Print mode starts only with `-p` (or `--print`), never from a TTY check. The value of `-p` is the prompt.
- **Output.** Text only. stdout holds only the final answer: the text of the last assistant message of the turn, then one newline. The session id, the notices, and the errors go to stderr, one line each, after `helyx: `. A JSON lines event stream waits for the Transport plugin, so that Helyx has one wire format.
- **Exit status.**
  - 0: the turn ends normally (`:turn_end` with outcome `:done`).
  - 1: a bad argument or input, a failed start, a failed turn, an aborted turn, a session that stops, or a last message that stopped at the output limit (`:max_tokens`). At the output limit the text is still printed, and a stderr line says that it was cut. A failed or aborted turn prints nothing on stdout.
  - 143 on SIGTERM and 129 on SIGHUP. The BEAM stops with status 0 on SIGTERM and dies at once on SIGHUP by default, so print mode traps both signals. Its first step installs the trap, before the logger change, the read of stdin, and any output, and the trap is never removed: every print run ends with a halt of the VM, also a failed start, a bad stdin, and an error line. The first signal aborts the turn, waits at most 3 s for the abort, and halts the VM with the status and no flush (`:erlang.halt(status, flush: false)`). The signal path never waits on output: a stdout or stderr pipe that nobody reads, a stdin pipe that stays open, or a start that hangs does not hold the exit. The first signal sets the status; later ones are ignored. (Owner decisions of 2026-10-13, after review rounds 2 and 3.)
- **No timeout inside Helyx.** The caller uses `timeout(1)`, which sends SIGTERM.
- **Session.** A print run saves a normal session under the sessions directory, and prints `helyx: session <id>` on stderr when the session starts. No opt-out flag.
- **Piped stdin.** When stdin is not a terminal, print mode reads it to the end before the agent starts. Input that is not empty is added after the prompt as a block:

  ```text
  <prompt>

  <stdin>
  <the input>
  </stdin>
  ```

- **No user.** Nobody can steer or approve. No approval gate exists yet, so the tools run. #503 adds the gate and its print-mode rule.
- **Refusal.** A last message with the stop reason `:refused` ends the turn normally (outcome `:done`), so the status is 0. Its text is printed, and a stderr line says that the provider refused or filtered the answer, as the TUI says. (Proposed by the worker, kept by the owner on 2026-10-13.)
- **No resume.** `-p` does not combine with `--resume` or `--session`. (Proposed by the worker, kept by the owner on 2026-10-13; ticket #574 is the follow-up.)

Decision of the worker (not in #491):

- **Print mode is a client.** It subscribes to the session and reads its events, as the TUI does. Core gets no print-mode code.

## Interface changes

- `CodingAgent.CLI`: the switch `-p TEXT` / `--print TEXT`. It combines with `--model` and a directory argument. It does not combine with `--resume`, `--session`, or `--list`: a print run is one prompt in a new session (ticket #574 for a print run that resumes). A value that starts with `-` stays the value, as for `--session`. `main/2` takes `halt` (default `&:erlang.halt(&1, flush: false)`); with `-p` it runs `Print.main/2`, which ends with `halt` and the status (0, 1, 129, or 143) and does not return. Tests pass a `halt` that reports the status and returns it. The other commands return 0 or 1 as before.
- `CodingAgent.run/1` takes the option `:prompt`. With it, `CodingAgent.Print.run/2` is the client in place of the TUI, and `run/1` returns its exit status. Core and the session start and stop as before.
- `CodingAgent.Print` (new):
  - `main(fun, halt \\ &:erlang.halt(&1, flush: false))` runs `fun` as the whole of print mode, in this order:
    1. SIGTERM and SIGHUP are trapped: it swaps the default handler of `:erl_signal_server` for its own and sets SIGHUP to `:handle`. This is the first step, before any output. The handler starts a stop process on the first signal and ignores the later ones, so the signal server never waits. The stop process aborts the session that `run/2` named (or none, before `run/2` names one: the session can already run, but it has no prompt yet), in a process of its own that it does not link, waits for that process to end for at most `abort_ms/0` (3,000 ms), and calls `halt` with the status.
    2. The log goes to stderr: the `:default` logger handler writes to stdout, and its output type is fixed when it is added, so `main/2` removes it and adds it again with the type `:standard_error`. Without this, a warning of Core (a failed turn logs one) reaches stdout. App config cannot set the type: under `mix helyx`, Logger starts before the app config loads (probed: a `config/config.exs` with the type left the warning on stdout).
    3. `fun` runs and returns the status, or `{:error, text}`, which `main/2` writes as one stderr line, with status 1.
    4. It asks the handler to finish. The handler answers in one call, so the answer and a signal cannot both win: when no stop has started, the handler marks the run as done, so a later signal is ignored, and `main/2` calls `halt` with the status; when a stop has started, `main/2` waits for its halt, so the status of the signal stands. Nothing is put back: the halt ends the VM.
  - `prompt(text)` returns `{:ok, prompt}` with the piped input added, or `{:error, text}` when the input is over the bound or not UTF-8.
  - `run(session, prompt)` names `session` to the signal handler, subscribes, prints the session id, sends the prompt, and waits for the end of the turn. It returns 0 or 1. It runs inside `main/2`.
- `CodingAgent.clean_line/1` (new, public): the clean pass of `one_line/1` and the 4,000-byte cap that `error_text/1` ends with.
- `Mix.Tasks.Helyx` passes the status of `main/2` to Mix. With `-p`, print mode halts the VM itself, so `mix helyx -p` exits with 0, 1, 129, or 143 and does not return to Mix. The release launcher (`System.halt(CodingAgent.CLI.main(System.argv()))`) does not change.

## Replaced mechanism

none. The TUI path does not change. `CodingAgent.run/1` picks the client from the options.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| piped stdin | 1,048,576 bytes (1 MiB), valid UTF-8, read as raw bytes: the device is set to latin1 and read with `:file.read/2` (probed on OTP 28: in unicode mode the device changes the bytes). The session file holds at most 64 MiB, and 1 MiB is about 250,000 tokens, more than the context window of the models that Helyx runs. The read takes at most one byte more than the bound | one line on stderr, status 1, before any application starts | `CodingAgent.Print.prompt/1` |
| stdin that stays open | not bounded: the read waits for the end of the input. A caller that keeps a pipe open and sends nothing gives `</dev/null`, or `timeout(1)` stops the run with 143 | a signal halts the VM | `CodingAgent.Print.prompt/1` |
| `-p` value | valid UTF-8 (the command line check); its length is the bound of the OS on arguments. An empty value is a prompt too: the turn runs with it | the argument error, status 1 | `CodingAgent.CLI` |
| wait for the end of the turn | none inside Helyx (owner decision); the end of the session ends it, and a signal halts the VM | n/a | `CodingAgent.Print.run/2` |
| wait for the abort after a signal | 3,000 ms (`abort_ms/0`): the abort releases the provider and the tools, or reports them as not confirmed, and the halt can drop that report; a turn that is not aborted by then is cut by the halt. From the signal to the exit: at most this bound, whatever stdout, stderr, and stdin do, from the first step of `main/2` to the halt | the halt with no abort | `CodingAgent.Print.Signal` |
| state of the wait | the last assistant message of the turn; the deltas are not kept | n/a | `CodingAgent.Print.run/2` |
| answer on stdout | the text of one assistant message, as the provider sent it; the provider and its output limit bound it. The write has no time bound: a pipe that nobody reads blocks it, and a signal halts the VM with no flush | n/a | `CodingAgent.Print.run/2` |
| stderr lines | one line each: a fixed sentence, or a sentence with the turn error, a notice text, or a start error, after the clean pass and the 4,000-byte cap of `CodingAgent.clean_line/1` (a start error goes through `CodingAgent.error_text/1`, which ends in the same pass) | n/a | `CodingAgent.Print` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the signal handler in `:erl_signal_server` | `main/2`, first step | the VM, until the halt | never removed: `main/2` calls `halt` | a raise in `fun` ends the CLI process with the handler still in place; the VM then stops by the BEAM path with the handler in, and a signal halts it | the stop process halts the VM |
| the stop process, and its abort process | the signal handler, on the first signal | nobody: not linked | the halt ends both | a crash of the abort ends its wait; the halt follows | the halt |
| the SIGHUP setting `:handle` | `main/2`, first step | the VM, until the halt | never set back: the halt | as on normal end | the halt |
| the `:default` logger handler on stderr | `main/2`, after the trap | the VM, until the halt | never put back: the halt; a log line in the swap window is lost | as on normal end | the halt |
| stdin encoding `:latin1` (raw bytes) | `prompt/1` | the CLI process | it sets `:unicode` back after the read | `after` sets it back | the halt |
| Core and the provider process | `CodingAgent.run/1` | the CLI process | `after`: abort, then `Supervisor.stop/1` | as on normal end | after a signal: the abort of the stop process, then the halt |

## Accepted holes

- The answer goes to stdout as the provider sent it, with no clean pass: a script reads the exact text. Escape sequences in it reach a terminal when stdout is one.
- A turn that the provider starts by itself before the prompt makes the prompt fail with `:turn_running`; the run then fails with status 1.
- SIGINT (Ctrl+C) keeps the BEAM default: the break menu, or an exit with no abort. `os:set_signal/2` cannot handle SIGINT. (Accepted by the owner.)
- The trap starts with the first step of print mode. Before it, the VM boots and `CodingAgent.CLI` checks the options and their combination (an argument error or a bad combination writes its line there, with status 1; the directory argument is checked inside print mode); a signal in that span gets the BEAM default. This is the known ceiling of the signal guarantee.
- A raise in `fun` (a bug) ends the CLI process before the halt; the run then ends by the BEAM path with the trap still in place.
- The halt does not flush: a log line that the logger has not written yet is lost at the halt. The lines of print mode are written by the CLI process itself before the halt.
- After a signal, output that has not reached the pipe is lost: the halt does not flush it. The answer of a run that a signal ends is not complete.
- A turn that the abort does not end in 3,000 ms is cut by the halt: a tool process that the abort did not stop by then can outlive the VM.
- A start that hangs (a plugin that hangs in its init) is ended by a signal like any other state; Core was not started, so nothing is aborted. (Codex, review round 2; accepted by the owner.)
- Log lines reach stderr in the format of the `:default` logger handler, with no clean pass and no 4,000-byte cap: a multi-line or long log message stays so. The 4,000-byte bound of the stderr row holds for the lines of print mode only. (Accepted by the owner.)
- `mix helyx` prints the output of a compile on stdout when the source changed since the last build. The release has no compile.

## Open

Review round 4 of #491 (owner exception round) reproduced two defects. They are not fixed; the owner decides:

- The first step of `main/2` is two calls: the swap of the handler, then `:os.set_signal(:sighup, :handle)`. A SIGHUP between the two calls gets the OS default: the VM dies by the signal and does not exit with 129. Codex hit the window by pausing the signal server during the swap; without a pause it lasts a few microseconds. The other order does not close it: a SIGHUP in the swap then goes to `erl_signal_handler`, which ignores it. It is a window inside the first step, outside the stated ceiling (the VM boot and the option check).
- When stdin is a directory, the read of `prompt/1` fails inside the IO system: the reader of the terminal driver crashes, and `:io.setopts/1` returns `{:error, :terminated}`, so the match at the `:latin1` reset raises. The run ends by the BEAM path with status 1 and a stack trace, not with one error line and the halt. The trap stays, so a signal still halts with 143 or 129.

Small items from review rounds 3 and 4 of #491:

- The test "SIGTERM during the turn aborts it, then halts with 143" does not prove that the abort comes before the halt: it can subscribe and assert `turn_end` before `{:halt, 143}`.
- The stderr case of `print_signal_test.exs` reaches the blocked write after a fixed 1 s sleep, not after a state marker.
- The second-signal case of `print_signal_test.exs` orders its events by sleeps (the run returns 2 s after the trap, SIGTERM about 1 s after it): a margin of about 1 s, with no `load_` attribute. Under load the SIGTERM can come after the run returns, and the test then reads 0.
- The `@shortdoc` of `Mix.Tasks.Helyx` still says "Starts the coding agent TUI".

## Out of scope

- JSON lines output (the Transport plugin).
- Several prompts in one run, and a print run that resumes a session (ticket #574).
- A turn or budget limit.
- The approval gate and its print-mode rule (#503).
