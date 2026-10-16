# Second review of 2026-10-16: a third model, and every finding fixed

Base: master at 7c0b292b, after the joint review (`2026-10-16-joint-review.md`) and #639. Ticket: #643 (closed by this change).

## Process

1. A third reviewer (Claude Fable) ran the prompt of the joint review on master, in nine slices.
2. Claude and Codex debated each finding. The rule: fix every finding unless the debate shows it is wrong. A "keep" needs a correctness reason, a data-loss reason, or the filter "equal size, equal clarity". A finding is not deferred because the batch is large.
3. Every changed clause has a test, or it is a deletion.
4. Five agents made the changes in parallel, one slice each: providers, hands, session and Core, tools, and TUI with the product. Codex reviewed each slice diff with its own probes, and each review ended with no findings.

**Deviation from `/ship`:** the owner asked for one commit and a fast path. This change had no `/simplify` pass and no three-agent review round. The Codex review of each slice took the place of the review round. `mix precommit` ran with the slow tests.

## What the first review missed

- The OpenAI request followed redirects. The #479 review recorded this as open, but no ticket existed. Now `redirect: false`; a 307 gives one request and an `http_status` error.
- The joint review lowered `codex.ex` and `claude_code.ex`, but their Credo counts stayed above the real line counts. The FileLength check now also reports a listed file under its count ("Lower its entry to N."), so this cannot happen again.
- A reader clause loaded a compaction entry with a non-string provider. It had no test. It is deleted, and the file is rejected as invalid with no byte changed.

## Changes

Deleted with no removed capability: `Resumed.session_id`, `handle_call(:snapshot)` (tests use `Session.subscribe/1`), the `{:EXIT, _, _}` clause of `Reason.crash/1`, the `:ok` answer to `started/1` from a Task that is no tool call, the second-place refusal of `Background.reserve/3`, the `info` default of `Events.events/2`, `Message.encodable?/1`, an unused default of `Core.plugins/2`, the `Interrupt` module (nested in `turn.ex`), the token `min` of the TUI view model, `is_binary` guards in `CodingAgent.sentence/1`, and a second UTF-8 repair in `Background.start/2`.

Moved: `File.resume/3` and the fake hands to test support, the lock sentences to `CodingAgent.sentence/1`, the background error text to `Helyx.Tool`, the bash start helper to `ToolRunner.start_tool/3`. Renamed: the bash `max_output_bytes`, and one name `background_dir` for the background folder.

Removed capabilities:

| Change | Removed capability |
|---|---|
| OpenAI `redirect: false` | A gateway that redirects no longer works. No evidence of one. |
| Hands working-directory check deleted | The uniform "working directory does not exist" text. A tool that does not use the directory now runs, and Write recreates a missing directory with `File.mkdir_p/1`. |
| `check/0` special answer deleted | A bad `check/0` return fails the public start or resume caller, as a raising `check/0` does. |
| `Tool.hold(nil)` deleted | A call outside the hands exits with `:noproc`. |
| Edit Prepend cap deleted | A match whose old text ends in a Prepend cluster before a trailing space. A probe of 252 cases found 168 such edits now rejected, every file unchanged, and no changed byte range. |
| `Turn.result_text/1` catch-alls deleted | A tool result content that is neither text nor a list of blocks fails the turn through the generic path. Supported non-text blocks keep their placeholders. |
| `mix helyx.install` special error sentence deleted | A listing failure after the swap raises. The first install, with no `current` link, still works. |

Added:

- The snapshot `turn` has `elapsed_ms` from a server clock, so a client that mounts late shows the real busy time.
- The TUI sends the default log handler to `<sessions_dir>/tui.log` while it runs. Before, a tool crash warning wrote stack frames onto the active terminal.
- The glossary in `CONTEXT.md` defines the resume label, background run, place, end, held end, and lost end (#643).
- Docs: the lock-loss rows of `session-lock.md` and `coding-agent.md` state the asynchronous window; `README.md` no longer says that a user interface is a plugin.

Tests: the bash exit-code tests are one loop; the hands and tools tests read event counts, not process state; one poll helper; the bash time-limit tests have a stated load margin and are `:slow`; a provider test had an order race and now holds the Wait until the provider loss reaches the server. The first full precommit, run beside the Codex probes, failed the bash test that ran `echo hi` with a 1 s limit: under load the command took longer. That case now checks only that 1 passes the bound, and a mutation of the bound fails it.

## Kept after the debate

| Finding | Reason |
|---|---|
| `catch` in `Run.tool/3` | Without it, a probe in a real terminal printed an OTP Task crash report onto the active TUI. |
| Background output write-error handler | On a write failure, the in-memory tail is the only copy of that output. |
| `map_size` term of `Usage.valid?/1` | A forged usage struct with an extra pid passed validation without it and crashed the session at JSON encode. |
| Gated `fail` and `dangling` fixtures | Two view-model tests use them. |
| The missing-link branch of the installer | It is the first install. |
| A FIFO at the TUI log path | Class (b): no run shows it, and the failure halts the product with a visible error. |
| About 20 smaller items | Equal size and equal clarity, or a test seam for a bound. The debate files list each one. |

## Residuals

- `turn_loop.ex` has 399 lines and `session.ex` 396. The next change to them needs a split where a module can own its state.
- On the laptop, a full slow precommit timed out at 60 s in the setup of the persistence test of #103 (20,000 appends), on this branch and on master 7c0b292b alike, with a load average over 14. Alone, the test takes 3.3 s, and on the precommit host the full run passed. Cause not measured.
- Not done: a packaged release run and live provider runs.
