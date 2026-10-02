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
| Failure path | No defect reproduced. Notes: the `:provider_session` key (as above). `Message.provider_id?/1` checks a resume id. That name is the spec's, so it stays. A local provider with an unrelated `init/3` now counts as connected. That is intended, and step 3 makes `init/3` required. | No change. |
| Codex adversarial | Approve, no findings. | None. |

No round reproduced a defect, so the loop ends after round 1.
