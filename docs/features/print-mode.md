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
  - 143 on SIGTERM and 129 on SIGHUP, after the turn is aborted and Core, with the provider process, is stopped. The BEAM stops with status 0 on SIGTERM and dies at once on SIGHUP by default, so print mode traps both signals for the whole run: while it reads stdin, while Core starts (then no prompt is sent), during the turn, and while it writes the answer to a pipe that nobody reads. The first signal sets the status; later ones are ignored.
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

Decisions of the worker (not in #491):

- **Print mode is a client.** It subscribes to the session and reads its events, as the TUI does. Core gets no print-mode code.
- **Refusal.** A last message with the stop reason `:refused` ends the turn normally (outcome `:done`), so the status is 0. Its text is printed, and a stderr line says that the provider refused or filtered the answer, as the TUI says.

## Interface changes

- `CodingAgent.CLI`: the switch `-p TEXT` / `--print TEXT`. It combines with `--model` and a directory argument. It does not combine with `--resume`, `--session`, or `--list`: a print run is one prompt in a new session (worker decision; a print run that resumes is out of scope). A value that starts with `-` stays the value, as for `--session`. `main/1` returns 0, 1, 129, or 143.
- `CodingAgent.run/1` takes the option `:prompt`. With it, `CodingAgent.Print.run/2` is the client in place of the TUI, and `run/1` returns its exit status. Core and the session start and stop as before.
- `CodingAgent.Print` (new):
  - `wrap(fun)` runs `fun` in the setup of print mode:
    - SIGTERM and SIGHUP are trapped: it swaps the default handler of `:erl_signal_server` for its own and sets SIGHUP to `:handle`. A signal becomes a message to the caller. When a signal came during `fun` and `fun` did not take it, the result is the status of the signal.
    - The log goes to stderr: the `:default` logger handler writes to stdout, and its output type is fixed when it is added, so `wrap/1` removes it and adds it again with the type `:standard_error`. Without this, a warning of Core (a failed turn logs one) reaches stdout. App config cannot set the type: under `mix helyx`, Logger starts before the app config loads (probed: a `config/config.exs` with the type left the warning on stdout).
    - After `fun`, it puts the default signal handler, SIGHUP `:default`, and the logger handler back.
  - `prompt(text)` returns `{:ok, prompt}` with the piped input added, `{:error, text}` when the input is over the bound or not UTF-8, or the status of a signal that came during the read.
  - `run(session, prompt)` subscribes, prints the session id, sends the prompt when no signal came, and waits for the end of the turn or a signal. It writes the answer in a linked process, so a signal also ends a write that blocks. It returns the exit status.
- `CodingAgent.clean_line/1` (new, public): the clean pass of `one_line/1` and the 4,000-byte cap that `error_text/1` ends with.
- `Mix.Tasks.Helyx` passes the status of `main/1` to Mix, so `mix helyx -p` exits with 129 and 143 too.

## Replaced mechanism

none. The TUI path does not change. `CodingAgent.run/1` picks the client from the options.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| piped stdin | 1,048,576 bytes (1 MiB), valid UTF-8, read as raw bytes: the device is set to latin1 and read with `:file.read/2` (probed on OTP 28: in unicode mode the device changes the bytes). The session file holds at most 64 MiB, and 1 MiB is about 250,000 tokens, more than the context window of the models that Helyx runs. The read takes at most one byte more than the bound | one line on stderr, status 1, before any application starts | `CodingAgent.Print.prompt/1` |
| stdin that stays open | not bounded: the read waits for the end of the input. A caller that keeps a pipe open and sends nothing gives `</dev/null`, or `timeout(1)` stops the run with 143 | SIGTERM ends the read | `CodingAgent.Print.prompt/1` |
| `-p` value | valid UTF-8 (the command line check); its length is the bound of the OS on arguments. An empty value is a prompt too: the turn runs with it | the argument error, status 1 | `CodingAgent.CLI` |
| wait for the end of the turn | none inside Helyx (owner decision); a signal or the end of the session ends it | n/a | `CodingAgent.Print.run/2` |
| state of the wait | the last assistant message of the turn; the deltas are not kept | n/a | `CodingAgent.Print.run/2` |
| answer on stdout | the text of one assistant message, as the provider sent it; the provider and its output limit bound it. The write has no time bound: a pipe that nobody reads blocks it, and a signal ends it | n/a | `CodingAgent.Print.run/2` |
| stderr lines | one line each: a fixed sentence, or a sentence with the turn error, a notice text, or a start error, after the clean pass and the 4,000-byte cap of `CodingAgent.clean_line/1` (a start error goes through `CodingAgent.error_text/1`, which ends in the same pass) | n/a | `CodingAgent.Print` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the signal handler in `:erl_signal_server` | `wrap/1` | the CLI process | `after` puts the default handler back | `after` runs on a raise; a killed VM ends the handler with it | a signal is the abort: `after` runs once the run returns |
| the SIGHUP setting `:handle` | `wrap/1` | the CLI process | `after` sets `:default`; an Elixir trap of SIGHUP is not restored, and the product has none | as on normal end | as on normal end |
| the `:default` logger handler on stderr | `wrap/1` | the CLI process | `after` adds the handler with its old config again; a log line in the swap window is lost | as on normal end | as on normal end |
| the process that reads stdin, and the process that writes the answer | `prompt/1`, `run/2` | the CLI process | it returns | it is linked to the CLI process | on a signal it is killed; the read or write of the `user` process can still block, and the VM halts after `main/1` (probed: a full stdout pipe and SIGTERM give 143) |
| stdin encoding `:latin1` (raw bytes) | the read process | the read process | it sets `:unicode` back before it returns | a killed read process leaves `:latin1`; then nothing more is printed on stdout | as a crash |
| Core and the provider process | `CodingAgent.run/1` | the CLI process | `after`: abort, then `Supervisor.stop/1` | as on normal end | as on normal end |

## Accepted holes

- The answer goes to stdout as the provider sent it, with no clean pass: a script reads the exact text. Escape sequences in it reach a terminal when stdout is one.
- A turn that the provider starts by itself before the prompt makes the prompt fail with `:turn_running`; the run then fails with status 1.
- SIGINT (Ctrl+C) keeps the BEAM default: the break menu, or an exit with no abort.
- A signal that comes after `fun` returns and before the handler is swapped back is dropped; the run has ended, and its status stands.
- A signal while the applications and Core start takes effect when the start returns: the start runs in the print process, and only then does `run/2` check for the signal (and send no prompt). A start that never returns (a plugin that hangs in its init) also ignores SIGTERM; `timeout -k` ends it with SIGKILL.
- Log lines reach stderr in the format of the `:default` logger handler, with no clean pass and no 4,000-byte cap: a multi-line or long log message stays so. The 4,000-byte bound of the stderr row holds for the lines of print mode only.
- `mix helyx` prints the output of a compile on stdout when the source changed since the last build. The release has no compile.

## Open

- A stderr pipe that nobody reads blocks the run, and a signal does not end it: the stderr lines of print mode are written from the print process, not from a separate process (review round 2 of #491, reproduced, not fixed). A second finding on the blocked write, so the fix is the mechanism: all output, or the whole client, in a process that a signal can end. Until then `timeout -k` ends such a run with SIGKILL.

## Out of scope

- JSON lines output (the Transport plugin).
- Several prompts in one run, and a print run that resumes a session.
- A turn or budget limit.
- The approval gate and its print-mode rule (#503).
