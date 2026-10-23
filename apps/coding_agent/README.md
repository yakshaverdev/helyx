# Coding agent

A terminal coding agent on Helyx: Core with the bundled plugins, one session, and the TUI. The design is in `docs/features/coding-agent.md`.

## Install

Install the current checkout once, from the repository root:

```sh
(cd apps/coding_agent && mix deps.get && mix helyx.install)
```

The install builds a release into `~/.helyx/releases/<commit>`, points `~/.helyx/current` at it, and writes the launcher `~/.local/bin/helyx`. It keeps the build before it and deletes older builds. A running session keeps its build until the second install after its start. Edits to the source do not change the installed build until you install again. `--prefix DIR` and `--bin-dir DIR` change the two folders.

If `~/.local/bin` is not on your `PATH`, add it, for example with `export PATH="$HOME/.local/bin:$PATH"` in `~/.zshrc`. Without it, the shell does not find `helyx`.

## Run

```sh
helyx [directory] [--model provider/model] [--new | --resume]
helyx --version          # the version and the commit of the build
helyx --help             # the usage, the switches, and the exit statuses
```

`directory` defaults to the current folder. When `helyx serve` runs for the data folder, `helyx` reattaches to the newest session of the folder, and `--new` or `--model` starts a new one (`docs/features/tui-attach.md`, decision 16). `mix helyx` in `apps/coding_agent` takes the same arguments and runs the source tree. The design is in `docs/features/local-release.md`.

## Print mode

```sh
helyx -p "fix the failing test"           # the answer on stdout
cat log | helyx -p "why does this fail"   # piped input joins the prompt, at most 1 MiB
```

`-p` runs one prompt with no TUI, in a new session, or with `--resume` or `--session <id>` in the session they pick (one process per session at a time). stdout holds only the answer. The session id, notices, and errors go to stderr. The status is 0 for a normal end, 1 for a failed or aborted turn or an answer cut at the token limit, 143 on SIGTERM, and 129 on SIGHUP. Helyx has no timeout of its own; use `timeout`. The session is saved, so `helyx --session <id>` continues it in the TUI, and `helyx -p "..." --session <id>` with one more prompt. The design is in `docs/features/print-mode.md`.

## Server

```sh
helyx serve                               # 127.0.0.1 and a port that the OS picks
helyx serve --host 0.0.0.0 --port 4040    # another address needs the explicit --host
```

`helyx serve` runs the agent with no TUI as a WebSocket server (`docs/features/wire-protocol.md`) until SIGINT, SIGTERM, or SIGHUP (a signal that was ignored at its start, as under `nohup`, stays ignored), then stops Core, and the sessions stay saved. `mix helyx serve`, with no launcher, stops in order only at SIGTERM. One server runs for each data folder (`~/.helyx/sessions`): a second `helyx serve` exits 1 and names the address of the first. When it is ready, the server prints its address and writes `server.json`, mode 0600, with its address, port, token, protocol number, and pid. Each start makes a new token. There is no TLS: for another machine, use an SSH tunnel or a TLS proxy. The design is in `docs/features/serve.md`.

## Keys

The footer shows no key hints, except "Ctrl+C again to quit" after a first Ctrl+C on an empty composer. These are the keys:

| Key | What it does |
| --- | ------------ |
| Enter | Sends the composer as a prompt, or as a steer while a turn runs |
| Alt+Enter | Queues the composer as a follow-up |
| Ctrl+J, or Shift+Enter where the terminal reports it | Adds a new line |
| Up on the first row, Down on the last row | Recalls an earlier prompt |
| Escape | Aborts the running turn; its queued messages come back to the composer |
| PgUp, PgDn | Scrolls the transcript by one screen |
| Home, End with an empty composer (fn+Left, fn+Right on a MacBook) | Goes to the oldest or the newest output. With text in the composer, they move the cursor |
| Ctrl+A, Ctrl+E | Moves the cursor to the start or the end of the line in the composer |
| Alt+B or Ctrl+Left, Alt+F or Ctrl+Right | Moves the cursor one word back or forward in the composer. Alt needs Option as Meta (Escape) in the macOS terminal |
| Wheel, trackpad | Scrolls the transcript by three rows |
| Ctrl+O | Shows the full text of every tool result, or the first four lines again. The hint row of a short result names the key |
| Drag in the transcript | Selects text and copies it to the clipboard with OSC 52, at most 75,000 bytes. The TUI takes the mouse, so the selection of the terminal does not work |
| Ctrl+F | Finds text in the loaded transcript, case-insensitive: type the text, Enter or Up goes to the older match, Down to the newer one, Escape closes the search and keeps the view |
| Ctrl+C | Clears the composer. A second Ctrl+C within 500 ms quits and restores the terminal |

`/help` in the composer lists the slash commands and these keys. `/model provider/model` switches the model. `/new` starts a new session in the folder, and `/resume` lists the other sessions of the folder: Up and Down select, Enter resumes, Escape closes. A paste of more than 5 lines shows as one marker and is sent in full.
