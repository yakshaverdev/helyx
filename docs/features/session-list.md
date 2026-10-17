# Session list and resume by id

## Goal

The user sees the earlier sessions on the command line and resumes one by its id (#489). Before this, `--resume` resumed only the newest session of a folder, and the user could not see or pick another one.

User stories:

1. `helyx --list` prints the sessions of the folder (the directory argument or the current folder), newest first. Each line has the id, the time of the last activity, the model, and the first prompt.
2. `helyx --list --all` prints the sessions of every folder, with the folder on each line.
3. `helyx --session <id>` resumes that session in the folder that its header names, wherever the user starts it.
4. `helyx --resume` keeps its meaning: the newest session of the folder.

Decisions:

- **New switches.** `helyx sessions` already means "start in the folder `sessions`", and `helyx --resume foo` already means "the newest session of the folder `foo`". So the list and the resume by id get their own switches: `--list`, `--all`, and `--session <id>`.
- **Empty sessions (owner, 2026-10-13).** A start writes the header at once, so a disk error shows at start. A user who quits before the first prompt leaves a file with a header and no message. The list and the newest-session resume leave such a file out. Nothing changes in how a session is written, and the file stays on disk. A file is empty only when its head is the whole file (65,536 bytes or less) and has no message. A file larger than the head with no message in the head is not known to be empty: the list shows it with an empty first prompt, and the newest-session resume can take it.
- **Folder (owner, 2026-10-13).** A session resumed by id runs in the folder of its header. The command line checks that this folder exists before the TUI or the print run starts. A folder that no longer exists, or that is not an absolute path, gives the error `not a directory: "<folder>"`. The folder in that line gets the clean pass and the folder width of a list line. Since #765 the resume of Core finds the id after the tool checks (`server-management.md`, "Order of the checks"), and it rejects a folder with a NUL byte as a start rejects such a `:cwd`: that gives the error line of a failed start. The check that the folder exists and is absolute runs after the open of the session. Accepted hole: a session rejected there was opened, so its lock file stays, as after any open, and the open added the newline that the last line lacked.
- **Last activity** is the modification time of the file. An append sets it. Nothing new is stored.
- **The model** on a line is the model of the header: the model that the session started with. A later model change is past the head, so the list does not read it. `--session` and `--resume` restore the current model.
- **First prompt** is the text of the first user message in the head of the file. The first message of a session is the user prompt. If the first message in the head is not a user message (only a hand edit makes that), the first prompt is empty.
- **The id** is the file name without `.jsonl`. The list shows only a file whose name has the format of `Helyx.Session.Id` (12 characters of `A-Z a-z 0-9 _ -`), so each listed id works with `--session`. The newest-session resume (`--resume`) skips the other files too (#581). About one id in 64 starts with `-`: the command line keeps the word after `--session` as its value.
- **A child session** (a header with a `parent`, `docs/features/agent-tool.md`) is left out of the list and of the newest-session resume (`--resume`). It counts toward the 256 scanned files. `--session <id>` opens it.
- **A file that the reader does not accept** is left out of the list: an unknown version, a header that does not parse or has no string `cwd` or `model`, and a file of the older format with no `session` header. The newest-session resume (`--resume`) skips it too, so it takes, of the sessions that `--list` shows, the one that started last (#585). `--session <id>` of such a file gives an error, not a skip.
- **The sessions folder is a name, not a pattern (#699).** The scan lists the sessions folder, then each project folder, with a directory read (`File.ls/1`), and keeps the names that end in `.jsonl`. It builds no glob pattern from a path. So a sessions folder whose path has `*`, `?`, `[`, `]`, `{`, or `}` finds only its own sessions, by id, in the list, and for `--resume`: `<tmp>/{a,b}` reads no session of `<tmp>/a` or `<tmp>/b`. The scan bounds stay. As the `*` of the wildcard before, the scan skips a file or a project folder whose name starts with `.`. The id of `--session` matches a listed name exactly, also on a filesystem that ignores case.
- **The terminal is a boundary for file text.** The folder, the model, and the first prompt come from the file, and a hand edit can put escape sequences in them. Before a line is printed, each field gets the clean pass of `Helyx.TUI.SessionList.one_line/1` (`CodingAgent.one_line/1` before #551): a whitespace run becomes one space, and a control character or a format character becomes `?`.

## Interface changes

- `Helyx.Session.File.Scan` (new, Core) owns the place and the header of a session file, and the choice of a file in a sessions directory: the scan of the newest files, the read of a head, the newest session of a folder, the file of an id, and the list. `Helyx.Session.File` keeps the entries after the header: append and load. `scan.ex` takes this code out of `file.ex`, so `file.ex` gets shorter and the calls go one way, from `File` to `Scan`.
  - `Scan.list(dir, cwd | :all)` returns `[%Scan.Summary{id, cwd, model, mtime, prompt}]`, newest first by modification time.
  - `Scan.find(dir, id)` returns `{:ok, path, header}`, `{:error, :invalid_id}`, `{:error, :not_found}`, `{:error, :duplicate_id}` (two project folders hold the id; only a copy by hand makes that), or `{:error, {:invalid_file, text}}` (the file has no session header).
- `Helyx.Session.File.pick/3` takes the option `:id`: it picks the file of that id, and the header must name `cwd`, else `:not_found`. Without `:id`, the newest session of the folder that has a message.
- `Helyx.Session.resume/2` passes `:id` to `Helyx.Session.File.pick/3`. `session.ex` does not grow, so it needs no split.
- `CodingAgent.run/1` and `CodingAgent.start_session/1`: `:resume` is `true` (the newest session of `:cwd`) or a session id. `:sessions_dir` is required; `CodingAgent.CLI` sets the default `~/.helyx/sessions`.
- `CodingAgent.CLI`: the switches `--list`, `--all`, and `--session <id>`.
  - `--list` combines only with `--all` or a directory argument. `--all` needs `--list` and does not combine with a directory argument.
  - `--session` does not combine with `--model`, `--resume`, `--list`, or a directory argument. `--model` with `--resume` stays an error.
  - `--version` skips these checks, as it skips the others.
  - `--list` reads the disk and prints. It starts no application, and it returns 0, also when no session is listed.
  - The errors of `--session`: `not a session id: "<id>"`, `no session "<id>"`, `not a directory: "<folder>"`, and the error line of a failed start for the other errors. They come after the tool checks (see "Folder").

## Replaced mechanism

1. `most_recent/3`, `newest/2`, `read_header/1` (now `head/1`), `read_up_to/2`, `project_dir/2`, `check_version/1`, `@version`, and the header map of `create/4` move from `Helyx.Session.File` to `Helyx.Session.File.Scan`. `most_recent/3` adds one rule: a candidate must not be empty (see Goal). A header with no string `cwd` is now not a session; before, it matched no folder, so the result is the same. The other rules stay: the scan bound of 256 files by modification time, the path as the tie break, the header `cwd` match, and the newest header `ts` wins.
2. The tests of the header scan in `test/helyx/session/file_test.exs` keep their properties. Their sessions get a user message, because a session with only a header is now left out. The test "create writes a header and resume restores the empty session" becomes the test that a header-only session is not resumed. The tests that resume a session with a model change or a damaged entry and no message get a user message first.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| files scanned for the list, also with `--all` | the 256 regular files with the newest modification time, the scan bound of the newest-session resume. A file that is then skipped (a name that is not a session id, an empty file, a header the reader does not accept) counts toward the 256 | the older files are not listed | `Scan.list/2` through `newest/2` |
| bytes read of each file for the list and the newest-session resume | 65,537: the head of 65,536 bytes (the header bound) for the header and the first prompt, and one byte more that shows whether the head is the whole file | a first prompt past the head is empty; a file of 65,537 bytes or more whose head has no message is not known empty and stays | `Scan.head/1` |
| first prompt in memory | at most the head, 65,536 bytes for each listed file | n/a | `Scan.head/1` |
| stats and paths of the scan | not bounded: the scan stats every session file of the folder, or of every folder with `--all`, and keeps every path before it takes the 256 newest; nothing deletes session files. Before this change the newest-session resume did the same for one folder. `Scan.find/2` keeps every `.jsonl` path of every folder (no stat) to match the id against the listed names (#699). A known ceiling, with no ticket yet | n/a | `Scan.newest/2`, `Scan.find/2` |
| heap of the head walk | the caller decodes one line of the head at a time, not a list of all its lines; a few MiB at most for a head of 65,535 short lines | n/a | `Scan.head/1` |
| lines printed | at most one line for each scanned file, so 256 | n/a | `CodingAgent.CLI` |
| first prompt on screen | 60 code points after the clean pass; a code point, not a grapheme, because one grapheme can hold any number of combining marks | cut at 60 code points | `Helyx.TUI.SessionList.line/2` (#551 moved it from `CodingAgent.CLI`) |
| model on screen | 40 code points after the clean pass | cut at 40 code points | `Helyx.TUI.SessionList.line/2` (#551 moved it from `CodingAgent.CLI`) |
| folder on screen (`--all`, and the error of `--session`) | the last 80 code points after the clean pass; the end of a path is the part that tells folders apart | the start is cut | `Helyx.TUI.SessionList.line/2` (#551 moved it from `CodingAgent.CLI`) |
| session id of `--session` | the format of `Helyx.Session.Id`, checked before any path is built | `not a session id`, no file access | `Scan.find/2` |
| files that match an id | one | two or more give `:duplicate_id` | `Scan.find/2` |
| resume by id: file size, heap | the bounds of the resume of `Helyx.Session.File` (64 MiB, the heap cap) | as for `--resume` | `Helyx.Session.File.resume_picked/3` |

## Ownership

Each head read opens one file with the fun form of `File.open/3`, which closes the handle on every path. No other resource.

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| file handle of a head read | `Scan.head/1` | the calling process | `File.open/3` closes it | the file process ends with its owner | n/a |

## Out of scope

- `/new` and `/resume` inside the TUI (#551).
- Session names, a tree view, branching, fork.
- Deleting empty session files.
- The current model in the list: it needs the whole file.
