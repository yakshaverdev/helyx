# Coding agent

A terminal coding agent on Helyx: Core with the bundled plugins, one session, and the TUI. The design is in `docs/features/coding-agent.md`.

```sh
mix helyx [directory] [--model provider/model] [--resume]
```

## Keys

The footer shows no key hints. These are the keys:

| Key | What it does |
| --- | ------------ |
| Enter | Sends the composer as a prompt, or as a steer while a turn runs |
| Alt+Enter | Queues the composer as a follow-up |
| Ctrl+J, or Shift+Enter where the terminal reports it | Adds a new line |
| Up on the first row, Down on the last row | Recalls an earlier prompt |
| Escape | Aborts the running turn |
| PgUp, PgDn | Scrolls the transcript by one screen |
| Home, End with an empty composer (fn+Left, fn+Right on a MacBook) | Goes to the oldest or the newest output. With text in the composer, they move the cursor |
| Ctrl+C | Quits and restores the terminal |

`/model provider/model` in the composer switches the model. A paste of more than 5 lines shows as one marker and is sent in full.
