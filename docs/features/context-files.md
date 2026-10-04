# Context files

Status: the current contract since #481.

## Goal

The model sees the instructions that the user and the repositories give for the working directory: a personal global file, and one file for each folder from the filesystem root down to the working directory. A folder can name its file `AGENTS.md` or `CLAUDE.md`, and `AGENTS.override.md` replaces both in that folder. The names and the order come from #481.

User story: I start Helyx in `~/code/proj`. The model sees `~/.helyx/AGENTS.md`, then `~/AGENTS.md`, `~/code/CLAUDE.md`, and `~/code/proj/AGENTS.md`, in that order, whichever of them exist.

## Interface changes

`Helyx.ModelContext.Default.build/2` builds the system prompt from:

1. the base prompt;
2. the global file `~/.helyx/AGENTS.md` (`@global_file`, relative to the home directory, next to `~/.helyx/sessions`);
3. for each folder from `/` down to the working directory, the first of `AGENTS.override.md`, `AGENTS.md`, `CLAUDE.md` that is a regular file there (`@file_names`).

Each file is a section: `## <path>`, a blank line, and the file text, capped by `Helyx.Text.truncate/2`. A file that `Helyx.Text.read_file/1` rejects gives no section, and its folder does not fall back to the next name. A file reached twice (a symlink, or the global file when the working directory is in `~/.helyx`) loads once, at its first place; identity is the device and the inode from `File.stat/1`. The option `:home` overrides the home directory, for tests.

## Replaced mechanism

The old mechanism: `AGENTS.md` of each folder from the home directory down to the working directory; a working directory outside home gave only its own `AGENTS.md`.

| Old rule | Now |
| --- | --- |
| folders from home down to cwd | folders from `/` down to cwd; home is one folder of the chain when cwd is under it |
| cwd outside home: cwd only | the same walk from `/`; the special case is deleted |
| one name, `AGENTS.md` | the first regular file of `AGENTS.override.md`, `AGENTS.md`, `CLAUDE.md` |
| no global file | `~/.helyx/AGENTS.md` before the folder files |
| per-file cap, skip of a rejected file | kept |
| no total cap | the total cap below |

Tests of the old mechanism:

| Old test | Property now |
| --- | --- |
| concatenates AGENTS.md from home down to cwd | kept, from the top of the test folder, with all three names |
| a level without AGENTS.md is skipped | kept |
| no AGENTS.md anywhere gives the base prompt alone | changed: the walk from `/` reads folders above the test folder, so the test checks that a test folder with no file adds no section of its own |
| cwd that is home reads it once | deleted: home is no longer a second walk, so no path reaches its file twice; the global-folder and symlink tests check the remaining double paths |
| a non-UTF-8 AGENTS.md is skipped | kept |
| a long AGENTS.md is truncated | kept |
| cwd outside home contributes only its own file | deleted with the rule |

## Bounds

| What | Bound | Over the bound |
| --- | --- | --- |
| one context file | `Helyx.Text.read_file/1`: a regular file of at most 10,485,760 bytes, valid UTF-8 | no section for that file |
| one section | `Helyx.Text.truncate/2` with `:head` | cut on whole lines, with a notice |
| all sections | 102,400 bytes after the base prompt, headings and 2-byte separators included (`@max_total_bytes`, twice `Helyx.Text.max_bytes/0`) | filled nearest file first; from the first file that does not fit, that file and every farther one are left out and not read |
| folders walked | the components of the working directory path | none; a path is short |

One section at the per-file cap, with its heading and notice, fits in the total cap, so the nearest file is never left out.

Accepted:

- A file can change between the stat and the read; the read checks it again.
- Identity by inode assumes a POSIX filesystem.
- A parent folder that other users can write (such as `/tmp`) can add a context file for a working directory under it.
- A nested checkout (a git worktree under its main checkout) loads the instructions of both checkouts, because the walk does not stop at a repository root.
- The global file keeps its first place when the working directory is in `~/.helyx`, so the cap leaves it out first there.

## Ownership

None: each file is opened and closed inside `Helyx.Text.read_file/1`.

## Out of scope

Skills (#471). The self-awareness section of the prompt (#470).
