# Worktree sessions

## Goal

The user asks a coordinator session to run three tasks in one repository. The coordinator calls `session_create` three times with a `worktree` argument. Each new session runs in its own git worktree on its own new branch. If the repository has a setup script, the script runs in each new worktree before the session starts. The sessions never edit the same files. The coordinator gets the worktree path and the branch name in the tool result, and the user sees them in the transcript.

Many sessions in one checkout overwrite each other's files and share one build state. A worktree gives each session its own files and branch for the cost of one `git worktree add`, with no container. The worktree belongs to the user, not to the call: it stays after the call and after a failure, because its files and its output are the evidence of the failure.

## Interface changes

- `Helyx.Tool.SessionCreate` takes the optional `worktree` argument: an object of `branch` (required) and `base` (optional), with no other key. Without it, the tool behaves as before. With it, the session starts in the new worktree, in the same subfolder of the repository when the base commit has that subfolder, else at the worktree root. The result text names the worktree path and the branch `helyx/<branch>`, and says that the setup script ran when it did. A failure after the add names the path, and the worktree stays.
- `Helyx.Worktree.create/3` (helper, `@moduledoc false`): checks the repository, the branch name, the base, the path, and the cap, makes the worktree, and runs the setup script. It returns the worktree `path`, its `branch`, the `setup` output (`nil` when no script ran), and `rel`, the folder of the source folder in the new worktree. The option `:setup_ms` replaces the setup deadline, for tests only, as `:watchdog_exe` does for `Helyx.Watchdog.start/4`.
- The application env `:worktree_root` of `helyx_plugins` names the root folder of the worktrees; it defaults to `~/.helyx/worktrees`. The worktree path is `<root>/<repo name>-<8 hex of the SHA-256 of the top-level path>/<branch with "/" as "-">`, so two checkouts of one repository name do not mix.
- The setup script is `<worktree>/.helyx/worktree-setup`. It runs with `bash` in the new worktree when it is a regular file, with the env `HELYX_SOURCE_REPO` set to the top level of the source checkout, so it can copy files that git ignores. It is the version of the base commit: an untracked file of the source checkout never runs code. The deadline allows a dependency install, which takes minutes, and keeps a tool call from holding a coordinator turn for longer.
- `Helyx.Tool.SessionCreate.release/3` releases the process groups of the git commands and of the setup script at the delivery of the call, at a crash, and at an abort, as the bash tool does (ADR 0004).
- A branch that exists is never reset, and a path that exists is never reused: each names the branch or the path in an error result. The cap error tells the model to remove a worktree with `git worktree remove`.

## Replaced mechanism

None. The session start, the Hub checks, the prompt, and the tool result are unchanged without the `worktree` argument.

## Bounds

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| the branch name | `@name` in `Helyx.Worktree`: lowercase letters, digits, `.`, `_`, `/`, and `-`, with a letter or a digit first and no `..`, short enough for a path segment; `git check-ref-format --branch` accepts it | an error result | `Helyx.Worktree.create/3` |
| the base | `@max_base_bytes` in `Helyx.Worktree`, no leading `-`, no NUL byte, and it resolves with `git rev-parse --verify --quiet <base>^{commit}` | an error result | `Helyx.Worktree.create/3` |
| the worktrees of one repository | `Helyx.Worktree.max_worktrees/0`, counted as the entries of the repository folder under the root | an error result that names `git worktree remove` | `Helyx.Worktree.create/3` |
| one git command | `Helyx.Worktree.git_ms/0` | the group is released with `:cancel`, and an error result holds the output tail | `Helyx.Worktree` |
| the setup script | `Helyx.Worktree.setup_ms/0` | the group is released with `:cancel`, the worktree stays, and an error result holds the output tail and names the path and the branch | `Helyx.Worktree` |
| the output tail of a git command, and the `setup` text | `Helyx.Worktree.setup_output_bytes/0`, cut from the end, valid UTF-8 | the start is left out | `Helyx.Worktree` |
| the git processes of one call | one `rev-parse` of the repository, one `check-ref-format`, one branch read, one base read when a base is given, and one `worktree add`; one setup script | n/a | `Helyx.Worktree.create/3` |
| the worktree folder | one folder of a full checkout; a path that exists is an error | an error result | `Helyx.Worktree.create/3` |

Two calls that pass the cap check together can each add a worktree, so the count can pass the cap by the number of calls in flight; accepted, because the tool is concurrent and the check holds no lock.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| each git process group and its watchdog | `Helyx.Worktree` through `Helyx.Watchdog.start/4` | the hands of the call, two handles for each command | the hands call `Helyx.Tool.SessionCreate.release/3` with `:deliver`; a command past `git_ms/0` the caller releases with `:cancel` first | the hands release the handles at the delivery of the crash result | the hands call `release/3` with `:cancel`: TERM, a grace, KILL, then a wait |
| the setup process group and its watchdog | `Helyx.Worktree` through `Helyx.Watchdog.start/4` | the hands of the call | as a git process; a script past `setup_ms/0` the caller releases with `:cancel` first | as a git process | as a git process |
| the release Task of a deadline | `Helyx.Worktree.stop/3`, in the call Task | the call Task, by the link; it holds no handle | it returns the handles that stay held | it dies with the call Task | it dies with the call Task, and the hands release the handles |
| the worktree folder and the branch `helyx/<branch>` | `git worktree add` | the user | kept; released by `git worktree remove` of the user; automatic cleanup is out of scope | kept | kept |

## Out of scope

Removing worktrees automatically, at archive or at merge. A wire `start` option for a worktree, which is a wire change. Worktrees for the sub-agents of the agent tool. A port for each worktree. Containers.
