# Local release

## Goal

The user installs the coding agent once from the repository. After that, `helyx` starts the agent in any folder from a frozen build, and edits to the source do not change that build until the next install (#506).

```sh
cd apps/coding_agent && mix deps.get && mix helyx.install
helyx                                   # the current folder
helyx ~/Code/x --model claude-code/sonnet
helyx . --resume
helyx --version                         # helyx 0.1.0+<commit>
```

## Interface changes

- `CodingAgent.CLI.main/1` takes the argument list and returns the exit status, 0 or 1. It has the argument checks and the error texts that `Mix.Tasks.Helyx` had. An error is one line on stderr, `helyx: <text>`. `--version` prints `helyx <version>` and skips the other checks; only the parse must pass. In a release the version is the release version, `<app version>+<commit>`. From the source tree it is `<app version> (source)`.
- `mix helyx` compiles and loads the applications (`app.config`) and calls `CodingAgent.CLI.main/1`. A non-zero status stops Mix with that status. The error line changes from `** (Mix) <text>` to `helyx: <text>`; the text stays the same.
- `apps/coding_agent/mix.exs` has a release named `helyx`. Its version is `<app version>+<commit>`, where the commit is `git describe --always --abbrev=7 --dirty=-dirty --exclude=*` when the release builds. A build from a tree with changes to tracked files ends in `-dirty`. A build outside a git checkout stops with an error.
- `mix helyx.install [--prefix DIR] [--bin-dir DIR]` runs in `prod`. It builds the release into a new folder under `<prefix>/releases`, then:
  1. renames that folder to `<prefix>/releases/<commit>`, or `<commit>-<k>` with the smallest free `k` from 2 when that name is in use. An existing folder is never replaced.
  2. writes the launcher `<bin-dir>/helyx`: it writes `<bin-dir>/.helyx-install`, then renames it. The launcher names `current`, not the build, so it comes before the swap.
  3. points `<prefix>/current` at the new build with a new symlink and a `rename(2)`, so a start sees the old link or the new link, never no link.
  4. deletes every entry of `<prefix>/releases` except the new build and the build that `current` pointed at before.

  Step 3 is the commit point. A failure before it leaves `current` and the kept builds as they were. The install then stops with an error. The next successful install deletes the build folder that the failed install left. A failure in step 4 is a warning on stderr, and the install succeeds. The next successful install tries the deletion again. The launcher names the `--prefix` of the last install that completed step 2. If an install with a new `--prefix` completes step 2 and fails in step 3, the launcher names a `current` that does not exist, and `helyx` does not start until an install succeeds.
- Defaults: `--prefix ~/.helyx`, `--bin-dir ~/.local/bin`. The sessions stay in `~/.helyx/sessions`; the install touches only `releases`, `current`, and the launcher.
- The launcher is a `sh` script: `exec '<prefix>/current/bin/helyx' eval 'System.halt(CodingAgent.CLI.main(System.argv()))' "$@"`. It passes every argument unchanged and does not change the folder. The release script resolves `current` to the physical build folder once, at start (`pwd -P`), so a later install does not move a running session to another build.
- The release script exports `RELEASE_*` variables to the VM. `CodingAgent.CLI.main/1` reads `RELEASE_VSN`, then deletes every variable whose name starts with `RELEASE_`, so a command that the agent runs (the bash tool, a harness) does not inherit them. Without this, a `helyx` of another build, started from the bash tool, boots with the version folder of this build and fails.

## Replaced mechanism

1. `Mix.Tasks.Helyx.run/1` parsed the arguments and raised `Mix.Error` with the text. The parse and the checks move unchanged to `CodingAgent.CLI`: the UTF-8 check, the contained `ArgumentError` of `OptionParser.parse/2`, the unknown option text, `--model` with `--resume`, at most one directory, and the folder check. `Mix.raise/1` becomes one line on stderr and status 1. The option list in the text adds `--version`.
2. `Mix.Tasks.Helyx` started the applications after the checks with `app.start`. It now runs `app.config`, which compiles and loads, and `main/1` starts the applications after the checks with `Application.ensure_all_started/1`, as the release needs. A bad argument starts no application.
3. The tests of the argument checks move to `test/coding_agent/cli_test.exs` and assert status 1 and the stderr line. The resume error tests in `test/mix/tasks/helyx_test.exs` run through the Mix task and assert the exit `{:shutdown, 1}` and one stderr line.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| command line arguments | valid UTF-8, the options of `OptionParser` strict mode, at most one directory, an existing folder | one line on stderr, status 1 | `CodingAgent.CLI` |
| error line | one line, with no length cap | control characters and invalid bytes become `?` (`CodingAgent.error_text/1`); an argument shows through `inspect/1` | `CodingAgent.CLI` |
| `mix helyx.install` arguments | `--prefix DIR` and `--bin-dir DIR` only; `OptionParser` strict mode | the usage line, and nothing changes | `parse/1` in `Mix.Tasks.Helyx.Install` |
| installed builds | the new build and the build before it, after a successful install | the install deletes the other entries of `<prefix>/releases`; a deletion error is a warning | `Mix.Tasks.Helyx.Install.install/3` |
| builds of failed installs, and builds that step 4 could not delete | one per failed install or failed deletion, unbounded, accepted (no ticket yet): each failure needs a person, and each failure prints an error | the next successful install deletes them | `Mix.Tasks.Helyx.Install.install/3` |
| build folder name | `<commit>`, then `-2`, `-3`, ... | the first free name; the kept builds limit the tries | `Mix.Tasks.Helyx.Install.install/3` |
| launcher | no wait and no retry | not applicable | the launcher script |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| build folder `<prefix>/releases/.build-<os pid>` | `mix release` in the install | the install task | renamed to the build name | `after` deletes it on a raise before step 1; after step 1 it is `releases/<commit>`. A killed VM leaves it. The next successful install deletes both | as a crash |
| link `<prefix>/releases/.current-<os pid>` | the install | the install task | renamed to `current` | the next successful install deletes it | as a crash |
| launcher `<bin-dir>/.helyx-install` | the install | the install task | renamed to `helyx` | stays after a raise or a killed VM; the next install writes over it | as a crash |
| two installs at once | a person | the two install tasks | not applicable | not applicable | open, no ticket yet: one install can delete the build folder of the other, or point `current` at a build that the other deletes |

## Accepted holes

- A session that started from a build two installs old loses its files when the next install deletes that build. The VM loads modules on demand and starts `inet_gethost` on demand, so the session can fail later. The bound of two builds is the choice of #506.
- Two installs at the same time are not supported (the ownership row above).
- The command line checks the syntax, the combination of options, and the folder before any application starts. The model ref is checked when the session starts, after the applications start, as `mix helyx` did before (`Helyx.ModelRef.parse/1` through `Helyx.Session.start/2`).
- The deletion also deletes a `RELEASE_*` variable that the user set before the start.

## Manual checks

A real terminal is necessary for these; the devlog of #506 lists them for a person:

- The Erlang VM does not read stdin while the TUI runs, so every key reaches the TUI.
- The terminal is restored after a quit, after a failed start, and after a crash.
- After a failed start the status is non-zero and the error is one line on stderr.
- Mouse capture is off after a quit.

## Out of scope

A single-file binary, a Homebrew tap, Hex packages, builds for other platforms, an update check, a self-update, and the rename of the project (#506).
