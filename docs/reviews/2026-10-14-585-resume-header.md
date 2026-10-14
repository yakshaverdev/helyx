# Review: #585 The newest-session resume skips a header the list skips

Invariant: `Helyx.Session.File.Scan.most_recent/3`, the newest-session resume of `Helyx.Session.File.resume/3` without `:id` (`--resume` in the TUI and in print mode), skips the same files as `Scan.list/2`: the version check and the string-model check now run once, in the shared scan `sessions/3`, as the id check of #581 does. The resume by id (`--session`, through `Scan.find/2`) does not change: a named file with a bad header gives `{:unknown_version, v}` or `{:invalid_file, _}`.

Entry points: `Scan.list/2` and `Scan.most_recent/3`, through `sessions/3`.

Accepted: a skipped file still takes one of the 256 scan slots (#581); the bounds row of `docs/features/session-list.md` now names every kind of skipped file. A folder whose only session has a header this build does not read now gives the `:not_found` sentence of `--resume`, not the version error; `docs/features/coding-agent.md` says so. `Scan.check_version/1` in `resume_within/5` can no longer fail on the newest-session path, and it stays for the id path (AGENTS.md: remove a repeated check only when the earlier check still proves the same property).

Test fixtures: the version test of `file_test.exs`, the header-model case of "a later valid model change does not launder a bad one", and the unknown-version test of `helyx_test.exs` used the newest-session resume to reach the strict error. They now resume by id (`id:` or `--session`), which keeps the strict path under test.

## Round 1 (full)

Simplify, four agents. Fixed: the #581 test and the new test became one test that covers a bad name and the four bad headers (reuse). Skipped: one `Scan.check_header/1` for the version, the model, and the `cwd`, shared by the scan and the strict path (altitude); it changes the error shape of `--session` for a bad model, and the ticket keeps `find/2` and the strict path as they are. The repeated `check_version/1` on the newest-session path (see Accepted).

Bounds sensor:

```
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | Codex | Approve, no findings | n/a |
| 1.2 | failure path | Probes through `resume/3` and `list/2` with version `1.0`, version `"1"`, model `nil`, `["a"]`, `""`: resume and list agree, and `--session` stays strict; three newer version-2 files hide an older session with `max_scanned_files: 3` and not with 4 | n/a, no defect |
| 1.3 | failure path | A folder whose only session has version 2 now prints "no saved session", and `coding-agent.md` names only the 256-file bound as a cause of that sentence | Fixed: one sentence in `coding-agent.md` |
| 1.4 | failure path, standards | `Scan.check_version/1` in `resume_within/5` always passes on the newest-session path | Kept: the id path needs it (see Accepted) |
| 1.5 | standards, spec | No test proves that an empty file or a bad header takes a scan slot, which the bounds row states | Fixed: the scan test resumes with `max_scanned_files: 7` (`:not_found`) and 8 (the valid session) behind two bad names, four bad headers, and one empty session |
| 1.6 | spec | "the newest session that `--list` shows" is wrong: the list orders by modification time, the resume by header `ts` | Fixed: "of the sessions that `--list` shows, the one that started last" |
| 1.7 | spec | No test of `--session` on a header with no `model` key | Accepted: the probe gives `{:invalid_file, "the first entry is not a header"}`, the same check as the tested `"model":42` case |
| 1.8 | standards | Two places decide what a readable header is (`head/1` and `sessions/3`) | Skipped, judgement call: see the altitude skip above |
| 1.9 | standards | `resume_message/1` takes a directory or an argv list | Kept, judgement call: the directory clause keeps six call sites short |
| 1.10 | spec | One run of `scan_test.exs:166` under load listed 161 files, not 256 | Not reproduced. Two test runs shared this worktree's `tmp/` at that time (a parallel run also failed in `File.rm_rf!` of the same test's directory), so the runs removed each other's files |

Round 1 reproduced no defect, so the loop ends. The fixes of 1.3, 1.5, and 1.6 are doc and test only.

Not reached by round 1: a file that changes between the scan and the load (older than this change); property-generated header JSON.

Guarantee table (round 1, from the spec agent, rows updated for the fixes):

| Guarantee | Proof |
| --------- | ----- |
| `most_recent`: skips an empty session | `file_test.exs`, "create writes a header, and the newest-session resume skips a session with no message" |
| `most_recent`: skips a file whose name is not a session id | `scan_test.exs`, "the newest session skips the files the list skips; resume by id stays strict" |
| `most_recent`: skips an unknown or missing version, and a model that is not a string | the same test |
| `most_recent`: picks only a session that `list/2` lists | the same test; a probe with a null `cwd`, bad JSON, and the older format |
| The pick is the session that started last (`ts`) | `file_test.exs`, "the modification time selects the files, then the start time decides" |
| `--session` of such a file gives an error | the same scan test (version 2); `file_test.exs`, "resume by id rejects a header with an unknown or missing version" and the `"model":42` case; `helyx_test.exs`, "a tagged term: an unknown version" |
| A skipped file counts toward the 256 | the same scan test, `max_scanned_files: 7` and 8 |
| print-mode: a header that `--list` does not accept is skipped | the same scan test; both clients go through `Session.File.resume/3` (#581, 1.9) |

## Orchestrator gate

| Round | Finding | Resolution |
| ----- | ------- | ---------- |
| r1 (Codex) | none (approve) | n/a |
