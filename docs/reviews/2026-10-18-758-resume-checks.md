# Review: a resume runs the tool checks before it reads the disk (#758)

Scope: the working tree against `origin/master` (`9cd55244`). Feature doc: `docs/features/server-management.md`, new section "Order of the checks".

Invariant: a start and a resume run the given `:cwd` check, then the tool specs, each `check/0`, and the `concurrent?/0` values, before any read of the sessions directory. Entry points: `Helyx.Session.start/2`, `Helyx.Session.resume/2`, `Helyx.Sessions.start/2`, `Helyx.Sessions.resume/2`, `Helyx.Session.File.pick/3`. `Session.resume/2` with `:id` and no `:cwd` takes the folder that the header names, checked by `Helyx.Session.Input.cwd/1` in `pick/3`, after the tool checks. Accepted holes: a resume resolves the model ref after the read of the file (#104); `Scan.list/2` and `Scan.most_recent/3` return a header cwd without the `Input.cwd/1` check.

## Reproduction

`test/helyx/session/boundary_test.exs`, "a resume by id rejects a failed check before it looks for the id", on the code before the fix: `Sessions.resume(core, id: <unknown id>)` with `Helyx.Test.Tool.Unavailable` gave `{:error, :not_found}` in place of `{:error, {:tool_unavailable, "unavailable", "the frob is missing"}}`.

## Decision

The header-folder rule moves from `Helyx.Sessions.resume/2` into `Helyx.Session.resume/2` and `Helyx.Session.File.pick/3`. The other ways run `check/0` and `concurrent?/0` twice (once in `Sessions`, once in `Session`), or move the tool checks out of `Session.resume/2`. The first breaks the rule of `Helyx.Tool.concurrent/1` (once per start or resume), and the second restructures the start path. The move also deletes the second scan of the folder: `Sessions.resume/2` found the id, and `pick/3` found it again. `Session.resume/2` with `:id` and no `:cwd` used `File.cwd!/0` as the folder; no caller in the repo depends on it (the TUI switch and `CodingAgent` pass `:cwd`). `Helyx.Session.start/2` does not change.

## Simplify

Four agents (reuse, simplification, efficiency, altitude).

| Finding | Resolution |
| ------- | ---------- |
| The "id and no cwd" rule is decided in `session.ex` and again in `pick/3`, joined by a nil cwd | Skipped: a `resume_cwd/1` with two clauses costs lines in `session.ex`, which is at 400; `pick/3` gets the user options only after the given cwd is checked, so the check order stays that of `start/2` |
| Check the header cwd in `Scan.head/1` for every scan | Skipped: it changes the list and the newest-session scan; out of scope, named as an accepted hole |
| Reuse, efficiency | Clean; the change removes one scan of the folder per resume by id |

## Round 1 (full)

Bounds sensor (`--diff origin/master`):

```
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Codex adversarial | approve, no material finding (41 in-memory checks) | none needed |
| Failure path | 0 reproduced. Probed: header folder shapes (NUL, lone surrogate, null, integer, multibyte, empty), option shapes (`cwd: nil`, `id: nil`, another cwd), 8 concurrent resumes by id, a header rewrite between the pick and the lock | none needed |
| Standards | 0 hard. Judgement calls: the nil sentinel between two modules (see Simplify); a damaged header folder gives `:invalid_cwd`, not `{:invalid_file, text}`; the new test copies `start_core/1`; the new test does not assert that no session process runs | `:invalid_cwd` kept: the code before the change gave the same error for that header, through the cwd check of `Session.resume/2`. Assert added. The copy stays: `start_core/1` takes no Core options |
| Spec | 0 missing. Wording: the `Session.resume/2` doc lost "with the same errors" and "the call returns it"; step 4 put the cap in the open, but the cap and the attach are in `Open.start/4` before it; the `Sessions.resume/2` doc did not name `:invalid_cwd` | All three fixed |

Guarantee table (spec agents of rounds 1 and 2; line numbers are the starts of the tests, corrected in round 2):

| Text | Guarantee | Proof |
|---|---|---|
| `Session.resume/2` doc | the newest of the working directory | `test/helyx/session/persistence_test.exs:101` |
| | `:id`, the header folder when no `:cwd` | `test/helyx/sessions_test.exs:52` |
| | writes only a missing newline | `test/helyx/session/boundary_test.exs:194` |
| | `:cwd` and tool checks before the directory read | `test/helyx/session/boundary_test.exs:194`, `:216`, `:274`; probe: a missing sessions folder stays missing |
| | lock and cap before the load | `test/helyx/session/lock_test.exs:44`, `test/helyx/sessions_cap_test.exs:14` |
| | a locked newest session is not skipped | `test/helyx/session/lock_test.exs:63` |
| | attach, one result | `test/helyx/sessions_test.exs:78`, `:102` |
| `Sessions.resume/2` doc | the header folder, or the newest of `:cwd` | `test/helyx/sessions_test.exs:52` |
| | no `:sessions_dir` is `:not_found` | `test/helyx/sessions_test.exs:94`, probe (id) |
| | `Scan.find/2` errors | `test/helyx/sessions_test.exs:89`, probe (duplicate id, a file that is not a session) |
| | `:invalid_cwd` for a bad header folder | `test/helyx/sessions_test.exs:66` |
| | after the tool checks | `test/helyx/session/boundary_test.exs:216`; probe: a NUL header with a failed tool gives `:tool_unavailable` |
| `pick/3` doc | the path and the folder | `test/helyx/session/file_test.exs:744` |
| | a header of another folder is `:not_found` | `test/helyx/session/file/scan_test.exs:294` |
| | nil cwd: the header folder, checked | `test/helyx/sessions_test.exs:66`; probe: `""` resumes, as a start accepts it |
| | never a success for a header without a string cwd | probe: null, an integer, a list, an object, a lone surrogate, and a 0xFF byte give `{:invalid_file, _}` from `Scan.find/2` |
| "Order of the checks" | step 1 before step 2; `check/0` before `concurrent?/0`; the model before mkdir | probe |
| | step 2 before the model ref | `test/helyx/session/boundary_test.exs:186` |
| | nothing on disk before step 3 | `test/helyx/session/boundary_test.exs:175`, `:216` |
| | step 4: the cap and the attach in `Open.start/4`, the lock in the open | read of `lib/helyx/session/server/open.ex`; `test/helyx/sessions_cap_test.exs:14`, `test/helyx/session/lock_test.exs:44` |
| Review checklist line 74 | the header read in the pick, after the checks | `test/helyx/session/boundary_test.exs:216` |

Round 1 reproduced no defect. Its fixes are doc wording and one test assert.

## Precommit after round 1

`mix credo --strict` failed: "Function body is nested too deep (max depth is 2, was 3)", `lib/helyx/session/file.ex:192` (`Helyx.Session.File.pick`). The fix moves the folder rule of the id branch into `match_cwd/3`, a function with three clauses. Each clause guards a string header cwd, so a header without one crashes and never gives a success. A `with` fall-through would have returned `{:ok, path, header}`, and a nil header cwd would have matched a nil `cwd`. The fix adds a function, so round 2 is a full round.

## Round 2 (full)

Simplify, four agents: no defect. Fixed: the name `folder/3` became `match_cwd/3`, and a header without a string cwd now crashes. Kept: the nil cwd between `session.ex` and `pick/3` (see round 1).

Bounds sensor (`--diff origin/master`):

```
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Codex adversarial | approve, no material finding | none needed |
| Failure path | 0 in the diff. 1 reproduced older defect outside the diff: `CodingAgent.CLI` with `--session <id>` reads the header (`Scan.find/2` in `session_cwd/1`, `apps/coding_agent/lib/coding_agent/cli.ex`) before it starts Core, so with no perl on `PATH` it prints `no session "<id>"` where a start prints the tool error | Open, not fixed here: the CLI needs the folder before the launch, to check that it is a directory and to run the TUI in it. A fix moves that check after the Core start, which restructures the start path of the product (the orchestrator ruled it out for #758, because #735 changes the start too). For a follow-up ticket |
| Standards | 0 hard in the code. The record had wrong line references and no round 2. Judgement calls: the `is_binary/1` guards repeat the `Scan.find/2` contract; the wording of step 4 and of the `:invalid_cwd` error in the resume bullet; the `pick/3` spec allows a nil cwd without `:id` | Line references and round 2 fixed. The guards stay: without them a nil header cwd matches a nil `cwd` in the first clause. Step 4 and the bullet reworded. The `pick/3` doc says that a nil `cwd` needs `:id` |
| Spec | 0 missing, 0 code defects; the same record and spec notes as standards | Fixed as above |

Round 2 reproduced no defect in the diff, so the loop ends. Its fixes are doc and record wording.
