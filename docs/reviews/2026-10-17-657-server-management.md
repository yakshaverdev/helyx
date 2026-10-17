# Review: #657 server management

Scope: the public server-management API (`Helyx.Sessions`), the Core options `:sessions_dir` and `:model`, the cap of 64 sessions, the attach of a resume, and stop. Base: `origin/master` (`94204fcf` after the last rebase). Feature doc: `docs/features/server-management.md`.

The ticket hit the limit of 45 minutes after round 3. Round 3 reproduced a defect, and no small-fix round ran. The commit holds only code whose last review round is done. The open defects are listed at the end.

## Round 1 (full)

Simplify ran first. Applied: the reuse of `SessionCase.await_down/3`; `max_concurrency` from the count of pids; `with` in `resume/2`; the stop through `Server.via/2`; a comprehension in `list_live/1`; no guard on `Core.config/2`. Skipped: shared test helpers, one `@call_timeout_ms` for `Helyx.Session` and `Helyx.Sessions` (session.ex is at the line limit), the second header read of a resume by id, a scan for each page, `send_request` in place of Tasks, `Helyx.Session.start/2` that reads the Core config, `stop/1` in `Helyx.Session`.

Bounds sensor:

```text
bounds sensor: 15 candidate functions, 0 flagged, 0 without an answer
```

- Codex (needs-attention), [medium] "An attach can lose the first open error" (`server.ex:48-54`). Reproduced by Codex with a stub: the process exits before the attach monitors it, the attach gets `:noproc`, runs again, and gets another result. Accepted as a hole: ticket #694. The feature doc states it.
- Standards: the race had no ticket (fixed: #694); bounds rows named the wrong enforcer (fixed). Judgement calls, kept and stated: `stop/1` in `Helyx.Sessions`, the second `@call_timeout_ms`, the `runs` argument, `Calls` that builds `Live`, the model check by type only (fixed: the Core now parses the model ref). Test gaps fixed: the `:open_timeout` attach, an invalid id, `sessions_dir: <<255>>`, `model: "no-slash"`.
- Spec: the product profile has no Helyx construct (an assumption, stated); `{:error, :session_not_found}` after two runs was not stated (fixed in the doc); the enforcer of the stop bound (fixed); the `:killed` mapping (stated in round 3); the stale wire cite `server.ex:38-50` (fixed to `:62-77`); the stale comment in `plugins/bundled/clients/tui/lib/helyx/tui/switch.ex:96` (open).
- Failure path: no defect reproduced. `Helyx.Session.start(core, model: 5)` raises; this is on master too.

## Round 2 (reduced: spec and failure path)

Fix counts: about 14 code lines, one code file (`lib/helyx/core.ex`), no function added or removed.

```text
bounds sensor: 9 candidate functions, 0 flagged, 0 without an answer
```

- Failure path, reproduced: the Core took a relative `:sessions_dir` (also `""`), so the folder moved with the cwd of the node and a resume gave `:not_found`. Fixed in round 3: the Core refuses a path that is not absolute.
- Spec: no test for `:session_not_found` after two runs (open, a test gap); `stop/1` catches only `:noproc` (not reproduced in round 2; reproduced in round 3); the `:killed` mapping during a Core stop (stated in the doc in round 3); stale cites of master in the wire doc (open, not of this change); the base was behind #683 (rebased).

## Round 3 (reduced: spec and failure path)

Fix counts: 2 code lines, one code file (`lib/helyx/core.ex`), no function added or removed. The invariant given to the agents: the sessions folder of a Core names one fixed folder for the life of the Core.

```text
bounds sensor: 8 candidate functions, 0 flagged, 0 without an answer
```

The sensor ran with the base `origin/master`, because the state before the fix had no commit.

- The fix holds: `sessions_dir: "relative/sessions"` gives `{:error, {:invalid_option, :sessions_dir}}` (`test/helyx/sessions_test.exs`). `"~"`, `"~/s"`, `"c:/x"`, and `"\\x"` are relative on Unix and are refused.
- Spec, reproduced: the `:noproc` clause of `Helyx.Sessions.stop/1` never matches. `GenServer.stop/3` exits with `{:noproc, {GenServer, :stop, [...]}}`, so a session that ends between the abort and the stop exits the caller. The fix is the pattern `{:noproc, _}`. Open: the limit was reached. The feature doc states it.
- Failure path, reproduced: glob characters in an absolute `:sessions_dir`, for example `<tmp>/{a,b}`, make `list_saved/2` and `resume/2` read and resume the sessions of another folder, because `Helyx.Session.File.Scan` builds a `Path.wildcard` pattern from the folder (`scan.ex:79`, `:118`). The scan code is on master, and `Helyx.Session.resume/2` has the same path. Open: the root fix lists the folder without a glob.
- Spec, partial: `Helyx.Session.start/2` and `resume/2` take any `:sessions_dir`. The feature doc states that `Helyx.Session` does not read the Core options, so the invariant holds only for sessions that `Helyx.Sessions` starts.
- Spec, test gaps: no test for the kill of an opened session during an attach, and none for the stop race.

Guarantee table of the contract text that round 3 changed:

| Guarantee | Proof |
|---|---|
| A relative `:sessions_dir` refuses the start with `{:invalid_option, :sessions_dir}` | `test/helyx/sessions_test.exs`, the Core option refusals |
| `"~"` and volume-relative forms are refused | spec probe of `Path.type/1` |
| A kill at the deadline of the open gives `:open_timeout` to every caller | `test/helyx/sessions_test.exs`, the `:open_timeout` attach |
| A kill of an opened session during an attach gives `:open_timeout` | code only (`server.ex:53`), no test |
| A session that ends between the abort and the stop exits the caller | spec probe; the doc states it as an open defect |

## Precommit after round 3

The first run failed in two steps:

- Credo: "The alias `` is not alphabetically ordered among its group." (`lib/helyx/sessions.ex:15`). Fixed: the two alias lines changed places. No behaviour changed.
- `plugins/bundled` test: "a failed resume shows the error and stays on the current session" (`test/helyx/tui/switch_test.exs:324`). The test held the lock in the same Core and expected `{:session_locked, id}`; since #657 that resume attaches. Fixed in the test only: a second Core holds the lock. No review round ran for these two fixes.

## Open

- `Helyx.Sessions.stop/1`: the `:noproc` clause does not match (round 3).
- Glob characters in `:sessions_dir` widen the scan (round 3, code of master).
- #694: an attach can lose the first open error.
- The stale comment in `switch.ex:96`, and stale cites of master in `docs/features/wire-protocol.md`.
