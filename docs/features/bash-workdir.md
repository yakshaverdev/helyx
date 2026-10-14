# Bash workdir

## Goal

The agent can run a `bash` command in a folder other than the session folder, such as a worker's git worktree, without a `cd` in every command. The optional `workdir` argument names that folder for one call. Without it, nothing changes. Issue #576.

- The path is expanded against the session folder with `Path.expand/2`, as the read, write, and edit tools expand theirs, so one path names one folder in every tool. A relative path starts at the session folder. A `~` alone or followed by `/` is the home folder; `~foo` is a folder named `~foo`. The empty string is the session folder. `Path.expand/2` resolves `.` and `..` and removes repeated and trailing slashes by the text, before the disk is read, so `link/..` is the folder that holds `link`, not the parent of its target. Owner decision of 2026-10-14.
- The folder is not limited to the session folder. Approval (#503) can limit it later.
- The folder must exist and be a directory when the call starts. The watchdog enters the folder before the command runs, as it does for the session folder, so a folder that is not there, or a file, fails the start: an error result, and nothing runs. The check is at the start and not before it, so a folder removed between a check and the start cannot slip through.
- The argument of other coding tools is in `docs/research/coding-tools.md`.
- The harness providers get the argument through the shared tool spec (`Helyx.Tool.Bash.parameters/0`). No provider lists the bash parameters itself.

## Interface changes

- `Helyx.Tool.Bash.parameters/0` adds `workdir`, a string. It is not required.
- `Helyx.Tool.Bash.run/2` runs the command in the resolved folder. It returns `{:error, text}` for a `workdir` that is not a string, is over 4,096 bytes, is not valid UTF-8, or has a NUL byte. Nothing runs. Missing, `null`, or `""` is the session folder.
- The description and the moduledoc name the argument.
- The tool set digest of a Codex thread changes with the spec, so a Codex session stored before this change starts a new thread with the replay when it resumes (`Helyx.Provider.Codex.Tools.resumable/2`), as for any change to a tool spec.

## Replaced mechanism

none.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| `workdir` argument | a UTF-8 string of at most 4,096 bytes with no NUL byte, checked in `run/2`; missing, `null`, or `""` is the session folder | an error result that does not echo the value; nothing runs |
| resolved folder in the error of a failed start | the reason of `Helyx.Watchdog.start/4` is cut to `Helyx.Watchdog.reason_max_bytes/0`, as for the session folder | cut |
| `workdir` in the tool call line of the TUI | the generic cut of the call line (`Helyx.TUI.ViewModel.call_line/1`) | cut |

## Ownership

No new resource. The command group is the one of `docs/features/bash-timeout.md`, started in another folder.

## Out of scope

A shell state that persists between calls (a `cd` that carries over). A background run (#577).
