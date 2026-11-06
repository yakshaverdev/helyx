# 2026-11-06: test time in the agent workflow

Owner request in chat, no ticket. Three decisions: `mix test --stale` between review rounds, slow tests only at the merge gate, and a check of which sync tests in `apps/coding_agent` can run async.

## What changed

- `/ship` step 3: between rounds, `mix test --stale` in each touched project plus the test files of the change. The skill states why `--stale` is not the gate. The facts come from the Mix source of Elixir 1.19.5 (`lib/mix/lib/mix/compilers/test.ex`, `set_up_stale/3` and `tests_with_changed_references/1`): a test file runs when it references a module of the project whose beam is newer than the stale manifest, followed through the project's compile manifest. A change to `mix.exs`, a Mix config file read at compile time (not `config/runtime.exs`, per `tasks/loadconfig.ex`), or `test_helper.exs` forces every file. The manifest is written only after a run with no failures. A module of a path dependency is not in the project's manifest.
- `/ship` precommit runs without `HELYX_SLOW=1`; only the merge gate of `/orchestrate` (step 5.2) sets it. The gate sends a failed slow test back to the worker as a follow-up. `AGENTS.md` states the trade with #295.
- `AGENTS.md` Commands: one line for `mix test --stale`.

## Measurements of `apps/coding_agent`, this machine

Two runs, one after the other, at `b67f4ea2`:

| Run | Tests | Finished in | Async | Sync |
| --- | --- | --- | --- | --- |
| `mix test --slowest 20` | 127, 22 excluded | 11.4 s | 2.8 s | 8.5 s |
| `HELYX_SLOW=1 mix test --slowest 30` | 149 | 97.3 s | 18.1 s | 79.1 s |

The owner measured 82 s of sync time on the precommit host, not compared here. On this machine the sync time comes from the slow tests: four waits of `ServeTest` and `AttachTest` take 30.3 s, 10.2 s, 10.1 s, and 10.1 s. Without them, the sync modules sum to about 8 s. So a `/ship` precommit without the slow tests drops most of the sync time; the merge gate keeps it.

Both runs had the same 3 failures in `CodingAgent.PrintTest` (lines 190, 242, 289): stderr starts with `helyx: 15 skills were left out: the skill list has at most 16384 bytes`. The tests read the skills of the real home folder of this machine. Not changed here; it needs its own fix.

## Sync modules: none moved

Each module stays `async: false`. Its shared state lives in the production code under test, not in the test, so no per-test value removes it without a production change:

- `CodingAgent.ServeTest`, `CodingAgent.AttachTest`: `CLI.main/1` reads `:sessions_dir` from the application env (`cli.ex`, `sessions_dir/0`) and has no option for it; `CodingAgent.Serve` is registered under one name, a VM runs one server; Core runs under its default name; tests set `PATH`, `HELYX_LAUNCHER`, and `LC_ALL`.
- `CodingAgent.PrintTest`: print mode swaps the handler of the VM's signal server, and the CLI starts Core under its default name.
- `CodingAgent.CLITest`: `main/1` changes OS variables of the VM (`RELEASE_*`, `PATH`), and reads `:sessions_dir` from the application env.
- `CodingAgent.LogFileTest`: the hold changes the logger handlers of the VM, and one process holds at a time.
- `Mix.Tasks.HelyxTest`: application env `:sessions_dir`, and Core under its default name.
- `Mix.Tasks.Helyx.GraphTest`: the turn trace is global to the node.

## Next

- A `:sessions_dir` option for `CLI.main` and a server name per start would let `ServeTest` and `AttachTest` run their slow waits in parallel at the merge gate. That is a production change, for a ticket.
- The three `PrintTest` failures that depend on the skills of the home folder.
