# 2026-10-20: two transport tests that failed under load (#805)

- Read the kept logs of both failures in `precommit-fails/` of the git common dir.
- Subscribe test: the sub was gone at `Process.monitor/1` (`:noproc`), and the session lived until the kill of the test. The monitor now comes right after `subscriber/1`. A copy of the test with the sub made to end before the old monitor failed with the text of the run; with the new place it passed. What ended the sub in the run is not found.
- Answer test: `WireClient.upgrade/2` waited 5,000 ms for the status line. A suspend of the one acceptor for 6,000 ms gave the same `MatchError`. One acceptor group does not queue a serial connect: the acceptor waits in `accept` before each connect. Every read of the test client now goes through `read/2` with `Events.wait_ms/0`.
- What broke: an `assert Process.alive?(sub)` added in round 2 failed the accepted early end of the sub; removed in round 3.
- Next: the accepted holes of `docs/reviews/2026-10-20-805-transport-test-races.md`, the 5,000 ms window of the suspended session first.
