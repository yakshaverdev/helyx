# 2026-10-04: a local release (#506)

## What was done

- `CodingAgent.CLI.main/1` has the argument checks and the error output that `Mix.Tasks.Helyx` had. It returns the exit status. `mix helyx` compiles and loads the applications, calls it, and exits with its status. `main/1` starts the applications after the checks.
- `apps/coding_agent/mix.exs` has a release named `helyx`. Its version is `0.1.0+<commit>`, from `git describe` when the release builds. A tree with changes to tracked files gives `<commit>-dirty`.
- `mix helyx.install [--prefix DIR] [--bin-dir DIR]` builds the release in `prod` into `<prefix>/releases`, renames it to `<commit>` (or `<commit>-2`, ...), writes the launcher `<bin-dir>/helyx`, points `<prefix>/current` at it with a rename, and deletes the builds other than the new one and the one before it.
- `helyx --version` prints `helyx 0.1.0+<commit>`.
- The design is in `docs/features/local-release.md`.

## Probe

A build into scratch folders (a prefix with a quote and a space) on this machine:

```text
$ <bin-dir>/helyx --version
helyx 0.1.0+f767ba3-dirty            status 0
$ <bin-dir>/helyx --bogus
helyx: unknown option or bad value: "--bogus"; the options are --model provider/model, --resume, and --version
                                      status 1
$ <bin-dir>/helyx /nonexistent/x
helyx: not a directory: "/nonexistent/x"   status 1
$ <bin-dir>/helyx . --model fake/echo < /dev/null   (no terminal)
helyx: could not start the agent: the terminal did not start: Device not configured (os error 6)
                                      status 1
```

## Decisions

- The launcher is a `sh` script that the install writes. It holds the absolute path of `<prefix>/current/bin/helyx` and runs it with `eval`. The release script resolves `current` to the physical build folder at start, so a later install does not change the build of a running session.
- A build folder that exists is never replaced. A second install of one commit gets `<commit>-2`.
- `CodingAgent.CLI.main/1` deletes the `RELEASE_*` variables that the release script exports, so a `helyx` that the bash tool starts boots its own build.
- The error line is `helyx: <text>` for the release and for `mix helyx`. Before, `mix helyx` printed `** (Mix) <text>`.

## What broke

- The review found two defects in `Mix.Tasks.Helyx.Install.install/3`. First, the launcher was written after the swap of `current`, so a failed launcher write left `current` on the new build. Second, a deletion error after the swap made the install fail although `current` had moved. The fix makes the swap of `current` the commit point. Each step before it can raise and changes neither `current` nor the kept builds. The deletion after it only warns.

## Open

- Two installs at once can delete each other's build folder. Accepted, no ticket needed: one person runs the install by hand.
- The builds of failed installs and the builds that a deletion could not delete are unbounded. Accepted, no ticket needed: the next successful install deletes them.

- A session that started two installs ago loses its build at the next install (the bound of two builds, accepted in the feature doc).
- A build needs a git checkout. The remote precommit host copies the tree without `.git`, so no test builds a real release; the release build is checked by the probe above.

## Manual checks for a person

These need a real terminal. Nobody did them yet. Install with `(cd apps/coding_agent && mix helyx.install)`, then:

1. Run `helyx` in a project folder. Type text, use the arrows, Ctrl+J, Escape, PgUp and PgDn. Every key must reach the TUI; the Erlang VM must not read stdin.
2. Quit with Ctrl+C twice. The terminal must be restored: the cursor shows, typed text echoes, the shell prompt is normal.
3. Run `helyx /tmp --model nope`. The status (`echo $?`) must be non-zero, the error must be one line on stderr, and the terminal must be restored.
4. While the TUI runs, stop the VM from another terminal with `kill <pid of beam.smp>` (SIGTERM, a graceful stop). The terminal must be restored. Then start it again and use `kill -USR1 <pid of beam.smp>`. The VM then writes `erl_crash.dump` into the folder and halts with no cleanup. This is a crash. Record whether the terminal is restored after each. If it is not, record it as a finding.
5. After a quit, move and click the mouse in the terminal. No escape sequences must show; mouse capture must be off.
6. Run `helyx --version` and compare the commit with `git rev-parse --short HEAD`.
