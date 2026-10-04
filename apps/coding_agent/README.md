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
helyx [directory] [--model provider/model] [--resume]
helyx --version          # the version and the commit of the build
```

`directory` defaults to the current folder. `mix helyx` in `apps/coding_agent` takes the same arguments and runs the source tree. The design is in `docs/features/local-release.md`.

## Keys

The footer shows no key hints, except "Ctrl+C again to quit" after a first Ctrl+C on an empty composer. These are the keys:

| Key | What it does |
| --- | ------------ |
| Enter | Sends the composer as a prompt, or as a steer while a turn runs |
| Alt+Enter | Queues the composer as a follow-up |
| Ctrl+J, or Shift+Enter where the terminal reports it | Adds a new line |
| Up on the first row, Down on the last row | Recalls an earlier prompt |
| Escape | Aborts the running turn |
| PgUp, PgDn | Scrolls the transcript by one screen |
| Home, End with an empty composer (fn+Left, fn+Right on a MacBook) | Goes to the oldest or the newest output. With text in the composer, they move the cursor |
| Wheel, trackpad | Scrolls the transcript by three rows |
| Drag in the transcript | Selects text and copies it to the clipboard with OSC 52, at most 75,000 bytes. The TUI takes the mouse, so the selection of the terminal does not work |
| Ctrl+C | Clears the composer. A second Ctrl+C within 500 ms quits and restores the terminal |

`/model provider/model` in the composer switches the model. A paste of more than 5 lines shows as one marker and is sent in full.
