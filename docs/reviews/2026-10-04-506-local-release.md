# Review: a local release (#506)

Scope: `CodingAgent.CLI`, `Mix.Tasks.Helyx`, `Mix.Tasks.Helyx.Install`, the `helyx` release in `apps/coding_agent/mix.exs`, and `docs/features/local-release.md`.

## Simplify

Four agents (reuse, simplification, efficiency, altitude).

- Fixed: `mix helyx` ran `app.start` before the checks. It now runs `app.config`, and `CodingAgent.CLI.main/1` starts the applications after the checks.
- Fixed: a hand-kept list of 15 `RELEASE_*` names. `main/1` now deletes every variable whose name starts with `RELEASE_`, so a new variable of a later Elixir does not leak.
- Fixed: three nested functions for one start path became one `with` chain; the parse and its `ArgumentError` rescue are one function.
- Skipped: one shared parser for `CodingAgent.CLI` and `Mix.Tasks.Helyx.Graph`. The graph task is outside the diff.
- Skipped: `:init.script_id/0` in place of `RELEASE_VSN`. The variable is read once and the deletion is necessary anyway.

## Round 1

Bounds sensor (`--diff origin/master`):

```text
bounds sensor: 8 candidate functions, 1 flagged, 0 without an answer
  apps/coding_agent/lib/mix/tasks/helyx.install.ex:42  SIZE  def install(build, prefix, bin_dir) do
```

Standards (9 findings, 2 hard):

- Fixed (hard): `mix helyx.install` used `OptionParser.parse!/2`, so `-=` or a switch that is not UTF-8 crashed with a stack trace. It now contains `ArgumentError` and `UnicodeConversionError` and prints the usage. Test: "bad arguments print the usage".
- Fixed (hard): the open race of two installs at once had no ownership row. It has one now, marked open; it needs a ticket number (see "Open" in the devlog).
- Fixed: the inverted `with` in `start_agent/2` became a `case` on the start result.
- Fixed: a `read_link` error other than `:einval` said "is not a symlink". The text is now "cannot read the link".
- Rejected: `if` in `check_combination/1` and `check_dir/1` (keyword order makes a match longer); `@doc false` on `install/3` (the comment says why it is public); the `~/.helyx` default in two modules (two different defaults, the sessions folder and the install root); the deletion of `RELEASE_*` under `mix helyx` (harmless, and the doc states it); the place of `cli/0` in `mix.exs`.

Spec (6 findings):

- Fixed: the README said "A running session keeps its build" with no qualifier. It now says until the second install after its start.
- Fixed: the feature doc and the devlog said that `mix helyx` starts the applications. It runs `app.config`.
- Fixed: the doc states that `--version` skips the other checks; the Goal snippet has `mix deps.get`; the moduledoc says "never replaced".
- Fixed: manual check 4 now has a crash (`kill -USR1`) as well as SIGTERM.
- Recorded: the open race (see Standards).

Failure path (2 findings, reproduced):

- Fixed (defect): a launcher that cannot be written (the path is a directory) left `current` on the new build and the temporary launcher in the bin folder, and a later install did not delete it. The same defect as Codex finding 2.
- Fixed (doc): the doc now says what a failure before the swap leaves, and that the next install deletes it.

Codex (2 findings):

- Fixed (defect, reproduced by the failure-path agent and the new test): the swap of `current` came before the launcher. A failed launcher write left `current` on the new build; the next install then kept the failed build and deleted the build before it, which a running session can use. The launcher does not name a build, so `install/3` now writes it before the swap. The temporary launcher has one fixed name, `.helyx-install`, so the next install writes over a file that a failed one left. Test: "a launcher that cannot be written leaves current and the kept builds".
- Rejected as a defect, fixed in the doc: `--model nope` starts the applications before Core rejects the ref. This is the order that `mix helyx` had before the change (the ref is checked in `Helyx.Session.start/2`). A second check in the CLI would repeat the boundary check of Core (AGENTS.md, "Remove a repeated check"). My invariant sentence said "every argument"; it was too wide. The feature doc now says which checks come before the start.

Round 1 result: one defect reproduced (the launcher before the swap). The fix changes about 40 lines in two code files, so round 2 is a full round.

## Round 2 (full)

Base: the round 1 state (a commit object of `origin/master` plus the round 1 diff). The fix diff has 52 code lines in two files, so the round is full.

Simplify (four agents):

- Fixed: `start_agent/2` had a `case` inside a `with`. The start error now becomes the sentence in the `else` of `launch/2`, and `start_agent/2` is one flat `with`.
- Skipped: one shared helper for the three guards around `OptionParser` (`CodingAgent.CLI`, `Mix.Tasks.Helyx.Graph`, `Mix.Tasks.Helyx.Install`). The graph task is outside the diff; a helper is the subject of a later change.
- Skipped: a lock file for two installs at once. It needs a decision on a lock that a killed install leaves; see "Open" in the devlog.

Bounds sensor (`--diff 376d968`):

```text
bounds sensor: 4 candidate functions, 1 flagged, 0 without an answer
  apps/coding_agent/lib/mix/tasks/helyx.install.ex:43  SIZE  def install(build, prefix, bin_dir) do
```

Codex (1 finding):

- Fixed (defect, reproduced by reading the code and by the new test): after the swap of `current`, a deletion error (`File.rm_rf!/1`) made the install fail although `current` had moved. A retry then kept the "failed" build and deleted the one before it. This is the second finding on the failure handling of `install/3`, so the fix is to the mechanism: the swap is the commit point. Every step before it can raise and leaves `current` and the kept builds as they were; the deletion after it only warns on stderr, and the next install tries again. Test: "a deletion that fails after the swap warns, and the install succeeds".

Spec (5 findings):

- Fixed: the launcher test now checks the builds right after the failed install, not only after the next one.
- Fixed (doc): the ownership row of the build folder said that `after` deletes it on any raise; after step 1 the folder has its build name. The row and the step list now say that the next successful install deletes it.
- Fixed (doc): the builds of failed installs have a bounds row: one per failed install, unbounded and accepted, because each needs a person.
- Fixed (doc): the step list now says that the launcher names the prefix of the last install that reached step 2.
- Covered by the Codex fix: a raise in step 4 after the swap.

Standards (6 findings):

- Open (hard): the race of two installs at once needs a ticket number; see "Open" in the devlog.
- Fixed: the `mix helyx.install` command line has a bounds row.
- Fixed: the usage test now passes safe `--prefix` and `--bin-dir` folders first, so a parse that let an argument list through would not install into the home folder.
- Fixed: the long sentence of manual check 4 is split.
- Rejected: the two styles of UTF-8 handling (a check before the parse, or a rescue); both are contained at the boundary. The `do :ok` body of the `with` in `launch/2`.

Failure path (1 finding, reproduced, low):

- Rejected: a `--bin-dir` inside `<prefix>/releases` lets the deletion step delete the launcher. The person chose a bin folder inside the build store; `current` and the kept builds stay correct. The earlier finding (a launcher path that is a directory) no longer moves `current` (reproduced: `current` and the builds stay).

Round 2 result: one defect reproduced (the raise after the commit point). The fix changes about 30 code lines in one file and adds a function, so round 3 is a full round.

## Round 3 (full)

Base: the round 2 state (a commit object of `origin/master` plus the round 2 diff).

Simplify (three agents; the efficiency agent had no findings):

- Fixed: `entries/1` joined each name to the folder, and the loop took the base name back. It now returns the names.
- Fixed: the usage test built its safe folders once for each argument list. It builds them once.
- Skipped: a `prune/3` function for the deletion after the commit point. The comment at the commit point names the step; a function adds a name and no check.
- Skipped: a test for an `entries/1` error. The error is at the disk boundary and only warns.

Bounds sensor (`--diff 5f31752`):

```text
bounds sensor: 1 candidate functions, 1 flagged, 0 without an answer
  apps/coding_agent/lib/mix/tasks/helyx.install.ex:43  SIZE  def install(build, prefix, bin_dir) do
```

Codex: approve, no findings.

Failure path (4 probes, no defect):

- `releases` cannot be listed after the swap: the install warns and succeeds, and `current` and the builds are correct. This is the design.
- Symbolic links in `releases`: the deletion deletes only the links.
- A swap that fails under a new `--prefix`: `current` does not change, but the launcher names the new prefix, so `helyx` does not start until an install succeeds. The feature doc now states this.
- An absolute `current` link with a trailing slash: the install keeps the right build.

Standards (8 findings, 2 hard):

- Open (hard): the race of two installs at once, and the unbounded builds of failed installs and failed deletions, need ticket numbers. The bounds row now names the failed deletions too.
- Fixed: the references to an "Open" section now name the devlog. The devlog records the two defects and the open items.
- Fixed: "next successful install" in all places; "completed step 2"; the long sentence of step 3 is split.
- Fixed: the warning test now checks that the next install deletes the build that the failed deletion left.
- Accepted: the `chmod 0o500` test cannot fail a deletion when the tests run as root.

Spec (no findings): the bound of two builds, the commit point, the README text on `PATH`, and the launcher with no wait and no retry hold in the code.

Round 3 result: no defect reproduced. The loop ends.
