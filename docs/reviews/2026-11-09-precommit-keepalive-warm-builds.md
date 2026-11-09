# Review: keepalives and warm builds in precommit.sh

Base: `f53af745`. No ticket: the owner asked for these in chat on 2026-11-07 and 2026-11-09. Change: `.claude/skills/ship/precommit.sh`, in two commits:
- **Keepalives:** every ssh, and the ssh of each rsync, gets `ServerAliveInterval=30` and `ServerAliveCountMax=4`.
- **Warm builds:** a new host folder is seeded with a copy of the build of the latest run that passed.

Fast mode (owner, 2026-11-09): one review round for both slices, the Codex review and the failure-path agent. No precommit per slice.

## Keepalives

Four local runs hung from 1.5 to 9 hours on dead connections. The options are in one array, `ssh_opts`: `ssh "${ssh_opts[@]}"`, and `rsync -e "ssh ${ssh_opts[*]}"`.

Probe on the host:
- An `ssh` shim that logged its arguments, run by a copy of the script with a probe lock and a stand-in command. All 5 ssh calls carried the options (`calls without ServerAliveInterval=30: 0`): mkdir, the rsync, the run, the md5 check, and the copy-back rsync. The run passed and copied back a format change.
- A dead peer, simulated by stopping the host's session process of a connection of the probe itself, with interval 2 and count 2. The local ssh ended with status 255 after 4 s: `Timeout, server … not responding.` Afterwards the session process ended, and the probe ended its own `sleep`.

A run that waits for the lock prints nothing, but its ssh still answers the keepalives, so it is not cut.

## Warm builds

**Design.** Every run is wrapped, under its flock (`sh -c '$wrap' run bash .claude/skills/ship/precommit-run.sh`):
1. It removes `.built` and any `_build.seed` and `deps.seed`.
2. When the folder has no root `_build`, it picks a source: the folder with the newest `.built` that has a real `_build`. `.built` is written only by a run whose command passed.
3. It removes the `_build` and `deps` of each project (`.`, `plugins/*`, `apps/*`).
4. It copies the source's `_build` and `deps` with `cp -a` to `.seed` names; a link is never copied.
5. It renames them into place, with the root `_build` last.
6. If a copy or a rename fails, it removes them all, and the run goes on cold. If a removal fails, the run stops with status 1.
7. It runs the command, and writes `.built` only on status 0.

The project PLTs of Dialyzer are in `_build` (Dialyxir's default name, `dialyxir_erlang-…_deps-test.plt`). The core PLTs are under `Mix.Utils.mix_home()` (`plt_core_path` in the three `mix.exs` files), which all folders share. rsync excludes `_build.seed/`, `deps.seed/` and `/.built`, and the md5 list prunes `*.seed`.

**Proof on the host.** Three first runs of new folders, all with the new script and a lock of the probe's own. No folder on the host had a `.built`, so the first run was cold.

| Run | Seed line | Total | Dialyzer (., plugins/bundled, apps/coding_agent) | Tests (., coding_agent, bundled) |
|---|---|---|---|---|
| cold | `no folder to seed from; the run is cold` | 273 s, passed | 181.7 / 203.0 / 209.1 s | 41.4 / 22.9 / 43.3 s |
| seeded | `seeded _build and deps from seedprobe-cold-… in 0 s` | 111 s, passed | 30.9 / 35.3 / 35.6 s | 51.8 / 28.2 / 47.7 s |
| error | `seeded _build and deps from seedprobe-seeded-… in 0 s` | 123 s, failed | `lib/helyx/data/reason.ex:64:invalid_contract`, in each project | 1 failure in `plugins/bundled` |

- **The error run** had a same-size edit (`@spec log(String.t(), term()) :: :ok` to `:: :no`, 12065 bytes before and after) with its mtime set to 2000-01-01. Mix 1.19.5 recompiles a project in full when its manifest names another folder (`compilers/elixir.ex`, `old_cwd != File.cwd!()`).
- **The test failure of the error run** was not identified: the probe's cleanup deleted the log. The flaky tests of `plugins/bundled` are the next item of this branch.
- **The probe deleted** its worktrees and host folders (`left: worktrees 0, host folders 0`).

**Wrapper tests on the host,** in a fake tree with a final wrapper text:
- A new folder seeded from the newest `.built` with a real `_build`. A newer `.built` with no `_build` was skipped, and so was a newer folder that never passed. The run wrote `.built` after passing.
- A failing command left no `.built`.
- A seed killed between renames (state: `deps.seed`, `plugins/x/_build` and `apps/y/deps` from an older source, no root `_build`): the next run reseeded all of them from one source.
- A failed copy, and a copy that failed in `apps/y` after the root was copied: nothing was left, and the run went on cold.
- An undeletable `.seed` stopped the run with status 1.
- A source whose `_build` is a link was skipped.
- A real PID namespace (root sh first), killed while `cp` was held with SIGSTOP: 5380 of 20000 files sat in `.seed`. The next run seeded in full (20000 files), and the held `cp` ended with the namespace.

## Review round

| # | Reviewer | Finding | Reproduced | Resolution |
|---|---|---|---|---|
| 1 | Codex | A failed seed can leave some copied directories, and the next run treats the folder as seeded | in part: a copy failure installed nothing, but a kill between renames left some projects from one source, and the next run took the rest from another (failure path, judgement 1) | Fixed at the mechanism: a seed is all or nothing from one source. It removes every project's `_build` and `deps` first, and all of them on failure. A removal that fails stops the run |
| 2 | Failure path | rsync does not exclude `.built`, so a `.built` at the root of a worktree reaches the host | yes, by construction | Fixed: `--exclude=/.built` |
| 3 | Failure path | A newest source with no `_build` copied only `deps` and printed "seeded" | yes, by construction | Fixed: the source pick needs a real `_build` |

Earlier rounds of this slice, before the rebase on master and before fast mode, found these, and the design above fixes each:
- a half-copied folder became a seed source (fixed by `.built`);
- a first run that ended before the lock never seeded (fixed by the trigger: no root `_build`, under the lock);
- the rsync of a second run of one folder name deleted files of a seed in progress (fixed by excluding the `.seed` names);
- a linked `_build` was copied as a link (fixed by never copying a link).

## Accepted holes

- **The seed runs after the rsync, not before it.** It must run under the lock, which the run takes, and the rsync neither writes nor deletes `_build`, `deps`, or the `.seed` names.
- **A folder that has a root `_build` is never seeded,** even a stale one: Mix rebuilds what changed in it.
- **Two folders can seed from one source at once.** Each run takes the lock, so the copies never overlap.
- **When the network is lost with no close of the connection,** the local ssh ends after 120 s, but the run on the host goes on until TCP gives up there (about 15 min, or about 2 h 11 min for a run that writes nothing).
