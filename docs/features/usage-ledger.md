# Usage ledger

## Goal

The user runs `mix helyx.stats` in `apps/coding_agent`, or `mix helyx.stats --days 7 --json`, and sees what the saved sessions used in a window: the tokens in, the tokens out, the cache share, and the cost with the marks of the footer; the same values by UTC day, by model, and by project folder; the ten sessions with the highest known cost; the assistant replies by stop reason and model; each tool with its calls, errors, error percentage, and the wall times from a call to its result at p50, p95, and the maximum; the hook answers by point and answer and the denies by tool; the count of compactions; and what the report skipped.

**Derive, not store.** The report is a fold of the session files, which are the record of truth. Nothing new is written, so no table, no cache, and no migration can disagree with the files. The fold is the one rule that a later wire operation and a later store rebuild reuse, so it lives in the bundled plugins project and the Mix task is a thin caller.

The user story: I have run long sessions for a few weeks. I ask which model and which project cost the most, which tools fail, and how long a tool call waits. The report answers from the files that already exist, and it names what it could not read instead of guessing.

## Interface changes

### `Helyx.Ledger` (`plugins/bundled/lib/helyx/ledger.ex`)

`Helyx.Ledger.read(dir, opts) :: {:ok, t()} | {:error, :invalid_window | :invalid_cwd}` folds the files under `dir` into a ledger.

| Option | Meaning |
| ------ | ------- |
| `:since` | the start of the window, a UTC `DateTime`, inclusive; required |
| `:until` | the end of the window, a UTC `DateTime`, exclusive; required, and after `:since` |
| `:cwd` | an absolute folder path that keeps one project after `Path.expand/1` of it and of each header `cwd`; absent for every folder; a relative path is `:invalid_cwd` |
| `:max_files` | a lower file bound for a test |

The struct holds the window, the file counts, the skips, `totals`, `by_day`, `by_model`, `by_project`, `sessions`, `replies`, `tools`, `hooks`, `denies`, and `compactions`. `sessions` holds one entry for each file read, keyed by the base name of the file, with the header `cwd`, the first prompt, the session totals, and the parent session id of a child file. `tools` holds the calls, the errors, a fixed histogram of wall times, and the exact maximum. Every token and cost sum goes through `Helyx.Session.Totals.add/2`; there is no second sum rule.

### `Helyx.Ledger.Lines` (`plugins/bundled/lib/helyx/ledger/lines.ex`, `@moduledoc false`)

`fold(path, acc, fun, opts \\ [])` reads one file in chunks and hands each line to `fun` as an entry or a skip. It uses the limits of a session resume, so a file that resumes is read whole. The file handle is closed in an `after`.

### `Helyx.Ledger.Report` (`plugins/bundled/lib/helyx/ledger/report.ex`)

`text/1` gives one section for each item of the goal, each a table of padded columns. `json/1` gives the same values with string keys, costs as numbers or null with `cost_unknown` and `cost_list`, and percentiles as integers or null. Every text from a file is cleaned in `Report` itself: each invalid byte and each control character becomes `?`, so a file cannot write escape codes to the terminal.

### `Mix.Tasks.Helyx.Stats` (`apps/coding_agent/lib/mix/tasks/helyx.stats.ex`)

`mix helyx.stats [--days n | --since YYYY-MM-DD] [--until YYYY-MM-DD] [--cwd dir] [--json]`. The window defaults to the last 30 days. `--since` is its day at 00:00 UTC, and `--until` is the day after its day at 00:00 UTC, so the day itself is in the window. The folder is `:sessions_dir` of `:coding_agent`, else `~/.helyx/sessions`. The task runs `app.config`, reads the files, and starts no application. A bad argument or a bad window prints one line on stderr, `helyx.stats: <reason>`, and stops Mix with status 1.

## Replaced mechanism

None. The feature adds a read-only report and replaces no protocol, state machine, or code path.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| session files | `Helyx.Ledger.@max_files` files, the newest by modification time; each file is read whole, so more is a job for the indexed store of a later slice | the rest count in `skipped_files` |
| one line | `Helyx.Ledger.Lines.@max_line_bytes` bytes, and a decode heap of `Helyx.Ledger.Lines.@max_heap_bytes`, the limits of a session resume | a complete line counts in `too_large` and the read goes on; a partial line over the bound counts once and ends the read of that file |
| wall-time histogram | `Helyx.Ledger.@max_bucket`, so the map has a fixed size for any number of calls; the exact maximum is kept | every larger value uses the top bucket |
| window days | 1 to 3,650 (`Mix.Tasks.Helyx.Stats.@max_days`) | one line on stderr and status 1 |
| text from a file | each invalid byte and each control character becomes `?` (`Helyx.Ledger.Report`) | the replacement character only |
| files, entries | one entry for each file read, at most the file bound; the sessions map has that many entries | the file or the entry counts as skipped |

A file whose first decodable entry is not a header with a string `cwd` counts in `skipped_files`, and its other entries are not read. A torn line counts in `torn`, a line over the bound in `too_large`, and an entry with a bad `ts`, a message that the codec rejects, or an invalid hook entry in `skipped_entries`.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| session file handle | `Helyx.Ledger.Lines.fold/4` | the process of the fold | `File.close/1` in the `after` | the VM closes the handle of a dead process | none: the fold has no abort path; the `after` always runs |

## Known ceiling

The wall time of a tool call is the time from the write of the assistant message that holds the call to the write of its result. For concurrent calls it includes the wait in the queue behind the other calls, so it is longer than the tool's own run. The session file has no start and end record for a call of its own, so no value on disk separates the two.

## Out of scope

- A store, a table, or a cache of the fold.
- A wire operation or a `helyx stats` command of the release command line; a later slice reads the fold over the wire.
- Provider attempts and their failures; the session file has no record of them.
- Per-turn rows and turn durations, which need the session feed; the session file has no turn-end record.
- A TUI view of the ledger.
- A change under `lib/` (Core), the session file format, or the wire protocol.
