# Review: #298, the provider rename (one-provider-path step 1)

Scope: `git diff origin/master` on `ticket/298-provider-rename`. The change renames the connected path from "harness" to "provider" per `docs/features/one-provider-path.md`, "Renames". No behaviour changes, except two. The client event `:harness_session` is now `:provider_session`, with the same data. `contract_version` goes from 1 to 2.

Invariant: every rename of the table holds in Core, in the Claude Code and Codex adapters, and in the tests. Each request to the provider process keeps the bound of its kind. The entry points are the Provider callbacks (`init/3`, `request/3`, `info/2`), `Helyx.Session.Stream.check/2`, `Helyx.Session.Server.handle_info/2`, and the TUI fold. These exceptions are documented:

- The session file keeps the stored entry name `harness_session` and its key `harness_session_id`.
- `Helyx.HarnessIO` keeps its name.
- `stream/3` and `Helyx.Provider.turn/1` stay for the local path until step 3. `turn/1` checks the export of `init/3`.

## Renames that the table does not list

- The stop reasons `{:harness_init, _}`, `{:harness_stop, _}`, and `{:harness_error, _, _}` are now `provider_*`, to match `:provider_timeout`. A client sees them in the `agent_end` error, so this is a second rename that clients see. The `contract_version` increase covers it.
- In the session state, the field `harness` is now `conn`. Outside `file.ex`, `harness_sessions` is now `resume_ids`.
- Codex had a private `request/3` that clashed with the callback. It is now `rpc/3`.
- `server.ex` has a new helper, `ask/4`, for the eight request sites. It keeps `server.ex` at its allowed 1,183 lines. Comments were reflowed in `server.ex` and `hands.ex`, so no allowance in `.credo.exs` grows.

## Round 1 (full)

Bounds sensor, against `origin/master`:

```
bounds sensor: 31 candidate functions, 5 flagged, 0 without an answer
  lib/helyx/session.ex:156  SIZE  def resume(core \\ Helyx.Core, opts) do
  lib/helyx/session/server.ex:390  SIZE  def handle_info(
  lib/helyx/session/server.ex:402  SIZE  def handle_info(
  plugins/bundled/lib/helyx/provider/claude_code.ex:251  SIZE  def request(
  plugins/bundled/lib/helyx/provider/claude_code.ex:323  SIZE  def info(message, state) do
```

The flagged functions changed only in names.

| Axis | Findings | Resolution |
|---|---|---|
| Simplify | `ask/4` uses `provider_ms[key]`, not `Map.fetch!`. | Skipped. Every key exists (`server.ex`, the `provider_ms` default), so a missing key is a bug, and it still crashes in `:timer.kill_after/2`. |
| Standards and spec | 1. A wrong replacement in `provider_process_tools_test.exs`: a link to `long-lived-proc.md`, and "the proc loop" and "the proc withdraws". The same wording was in one comment in `provider_process.ex`. 2. The renamed stop reasons are visible to clients. 3. The `:provider_session` data keeps the key `harness_session_id`. | 1. Fixed. 2. Recorded above. 3. The spec says "the same data", so the key stays. |
| Failure path | No defect reproduced. Notes: the `:provider_session` key (as above). `Message.provider_id?/1` checks a resume id (renamed in round 2). A local provider with an unrelated `init/3` now counts as connected. That is intended, and step 3 makes `init/3` required. | No change. |
| Codex adversarial | Approve, no findings. | None. |

No round reproduced a defect, so the loop ends after round 1.

## Round 2 (reduced, by the orchestrator's decision)

The orchestrator decided two changes on the open points:

- The payload key of the client event `:provider_session` is now `resume_id`, not `harness_session_id`. The session file keeps its stored names. The contract_version increase of round 1 covers this rename.
- `Message.provider_id?/1` is now `Message.resume_id?/1`. The Renames table and the client-event rows of `one-provider-path.md` match it.

The fix diff, without test files and Markdown, is 20 lines in 9 code files (10 added, 10 removed), and it renames a public function. By the rules of `/ship`, that makes a full round. The orchestrator asked for a reduced round, so this round ran the spec and failure-path agents only.

Bounds sensor, against the round 1 commit: `bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer`.

| Axis | Findings | Resolution |
|---|---|---|
| Spec | 0 defects. Notes: `append_harness_session/3`, the `harness_sessions` field of the resumed file, and the comments in `file.ex` keep the stored-format name. | No change: the file keeps its stored names, by decision. |
| Failure path | 0 defects. Note: this record still said that `provider_id?` stays. | The record is fixed. |

No defect was reproduced, so the loop ends.

## Round 3 (reduced, after the rebase)

The branch was rebased onto `origin/master`, after #297, #305, #302, and #308 were merged. Three files had conflicts: `.credo.exs`, `tui/view_model.ex`, and `tui_test.exs`. In each of them, master's side was kept and the renames were applied again. contract_version stays 2, one increase shared with #297. `view_model.ex` has 400 lines. `server.ex` (1,182), `hands.ex` (411), `tui.ex` (841), `session.ex` (470), and `provider_process.ex` (429) are each at their `.credo.exs` count.

The bounds sensor ran against `origin/master`. It flagged the same 5 functions as in round 1, at new line numbers: `session.ex:158 resume`, `server.ex:395` and `server.ex:407` `handle_info`, `claude_code.ex:251 request`, and `claude_code.ex:323 info`. Each of them changed only in names.

| Axis | Findings | Resolution |
|---|---|---|
| Spec | 0 defects. Master's intent is kept in each conflicted file. No old name is left in the new master code, except the documented exceptions. | None. |
| Failure path | 0 defects. | None. |

No defect was reproduced, so the loop ends.
