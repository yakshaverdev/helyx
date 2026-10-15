# 2026-10-15: #592 hands tests wait for the release message

The end-to-end probe of #578: a Helyx worker (`helyx -p` in its own worktree) ran `/implement 592` and `/ship`.

## What was done

- `assert_received` of a message from another sender after a wait became `assert_receive`: hands_test 85 and 116, every such site in `provider_process_test.exs`, and `harness_stop_test.exs` 49 and 58. Sites that are safe stay; the review record lists them.
- The checks that the old code made at the return of a call stay: `refute Process.alive?/1` after a stop, and `Helyx.Test.Released.take/0` for a release. The test releases write an ETS row before they send their message.
- One AGENTS.md rule line: messages from two senders have no order.
- Review: three rounds and a small-fix round, `docs/reviews/2026-10-15-592-hands-test-race.md`.

## What broke in the Helyx path

- `gh issue view 592 --comments` printed nothing, with exit 0. `gh issue view 592 --json title,body,comments,labels` worked.
- `mix test` in the bash tool stopped at boot: `Runtime terminating during boot ({'cannot get bootfile','/Users/akshaydeshraj/.helyx/releases/12e5cbc/bin/start.boot'})`. The variables of the Helyx release reach the shell of the bash tool, so `erl` boots the release. Each run left an `erl_crash.dump`. Unsetting the `RELEASE_*`, `BINDIR`, `ROOTDIR`, `EMU`, `PROGNAME`, `ERL_*`, `ELIXIR_*`, `BOOT*` and `MIX_*` variables before `mise exec -- mix` fixed it. Every review brief carried that line.
- The print run ended while four simplify agents ran in the background: print mode waits only for its own bash background runs, not for background agents of the harness. One agent (altitude) was lost, with "didn't finish before the previous session ended". The owner restarted the run; from then on every agent ran in the foreground, and no wakeup was scheduled.
- Codex reviews read the working tree but did not run tests: "Tests and precommit were not run because the workspace is read-only."

## Next

- The open items of the review record: one site that checks after two waits, the interrupt at the return of an abort in `:submitting`, and the `refute_received` sites of another sender.
