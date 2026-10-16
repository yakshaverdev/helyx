# Session lock

Ticket #579. One OS process at a time has a session open.

## Goal

User story: I open a session that another Helyx process already has open, for example a second TUI with `--session <id>`, or a print run (#574) next to a TUI. The second open fails at once with one line, `helyx: session <id> is open in another process`, and exit status 1, before the TUI draws. Print mode prints the same line. A session whose process crashed, or was killed with SIGKILL, opens normally.

Before this change, two processes could open one session. Both appended to the one session file, and with a harness model both continued one provider session.

Decisions (owner, 2026-10-14):

1. **An OS file lock.** The lock is a `flock` with `LOCK_EX|LOCK_NB` on `<id>.lock`, next to the session file `<id>.jsonl`. A small perl program holds it: it opens the lock file, takes the lock, writes the result on stdout, and then waits on stdin. The program runs on a port that the session server process owns. When that process stops, crashes, or the node halts, the port closes, perl reads the end of its stdin and exits, and the kernel releases the lock. So there is no stale rule and no pid in the file. Perl is a requirement of Core when `:sessions_dir` is given; Erlang has no `flock`, and the bash tool requires perl already.
2. **Core takes the lock.** The session server process of `Helyx.Session.start/2` and `Helyx.Session.resume/2` takes it in its `init/1` when `:sessions_dir` is given, before `Helyx.Session.File` writes anything (a resume can append a newline), so the port of the lock has one owner for its whole life (#589). So every product and every worker (#578) gets it. `--list` reads without the lock. A held lock gives `{:error, {:session_locked, id}}`.
3. **`--resume` with no id does not skip a busy session.** When the newest session of the folder is locked, the open fails with the line above. The user picks another session with `--session` or `--list`.
4. **Release.** The lock lives as long as the session server process. A normal stop, a crash, and a print-mode halt all release it, because the port closes. The lock file stays on disk; only the `flock` on it counts.
5. **Perl ends while the session runs.** The kernel releases the lock, and another process can then open the session. The session watches the port: when it closes, the session stops saving and goes on in memory, by the path of a write failure (`Helyx.Session.Server.Records.stop_saving/3`). It sends one `:notice` event, "the session lock is lost; the rest of this session is not saved", with the turn id of a turn that runs. It does not take the lock again: a second process may hold it by then, and the session cannot tell. It writes no more lines, so a second process that opens the session finds one writer and one chain (#629, joint review of 2026-10-16). The snapshot field `persisting` is false from then on, so a client that subscribes after the notice still tells the user: the TUI shows `Helyx.Reason.text(:not_saved)` at its mount, and print mode writes it to stderr. `persisting` is false also for a session with no file and after a write failure. Before #629, the session kept saving without the lock and the snapshot had `lock_lost` (#606).

## Interface changes

- `Helyx.Session.start/2` and `resume/2` with `:sessions_dir`: new errors `{:session_locked, id}` and `{:lock_failed, text}`. `text` is one sentence for each cause: perl is not on the PATH, the lock file cannot be opened (with the OS reason), or perl gave no answer in time.
- With two Cores in one node, a resume of a session that the other Core holds now gives `{:session_locked, id}`. A second resume in the same Core gives `{:session_locked, id}` too, in place of `{:already_started, pid}`: the Registry rejects it before the `init/1`, and `Helyx.Session.Server.start/3` gives that rejection the shape of a held lock.
- A new `:notice` event text: the lock is lost (decision 5).
- `Helyx.Session.Snapshot` has the field `persisting`, a boolean (decision 5, #629, which replaces `lock_lost` of #606). A client is a tolerant reader (ADR 0006). The client text is `Helyx.Reason.text(:not_saved)`.
- `CodingAgent.error_text/1`, through its private `sentence/1`: `{:session_locked, id}` gives `session <id> is open in another process`, with no "could not start the agent" prefix. `{:lock_failed, text}` gives `could not start the agent: could not lock the session: <text>`.
- New Core module `Helyx.Session.Lock` (`@moduledoc false`). Core cannot call `Helyx.Watchdog`, which is plugin code (ADR 0005).

## Replaced mechanism

Two writers on one session file (#266). The tree rules of the file stay: they read a file that two writers made before this change, or a copy by hand. What changes:

1. Two Cores that resume one session in one `sessions_dir` no longer both run: the second gets `{:session_locked, id}`. Three tests used that state to make two writers or two instances of one id: "each Core writes its own branch" and "a subscribe to the id in another Core leaves the events of the first" (`test/helyx/session/instance_test.exs`), and "a resume of a branch with a fork below its label starts a fresh program session" (`test/helyx/session/provider_process_test.exs`). Each kept its property: the second Core resumes a hard link of the file in a second sessions folder (`Helyx.Test.SessionCase.link_session/2`), so both write the one file and each has its own lock file. #629 deletes the first and the third: the file is one chain, so a branch and a fork are no longer a state of the file. The second stays.
2. "keeps no copy after a start and after a failed start" (`test/helyx/session/persistence_test.exs`) needs a start that fails in the supervisor. A second resume in one folder fails in the supervisor: the Registry rejects it before the `init/1` that takes the lock, and the error is `{:session_locked, id}`. Since #589 the `init/1` loads the transcript, so no copy of it passes through the supervisor.
3. "resume after a crash mid-turn" (`test/helyx/session/persistence_test.exs`) kills the session and resumes it: the kill frees the lock only when perl exits, so the test waits for the free lock.
4. `docs/features/session-instance.md`, "Two Cores", `docs/features/coding-agent.md`, "Session file", and `docs/features/print-mode.md`, "Accepted holes", change to say this.
5. #589 moves the take into the `init/1` of the session process. `Lock.own/1`, which connected the port in the `init/1` and refused a port that had closed, and `Lock.unlink/1`, with the release of the caller around the start request, go. `Lock.hold/2` refuses a port that closed during the open in place of `own/1`. The test "a start request that exits frees the lock" becomes "a start request that exits takes no lock and writes nothing". A resume of a linked file of an id that the same Core runs gave `{:already_started, pid}` and gives `{:session_locked, id}`. The session supervisor no longer hibernates after each message (#103): the start message holds no transcript any more, and the two tests of #103 in `test/helyx/session/persistence_test.exs` stay as guards.

## States

| External state | What the open does | What the running session does |
| -------------- | ------------------ | ----------------------------- |
| perl not on the PATH | `{:lock_failed, text}`; the session file is not written (the take makes its folder first) | not reached |
| perl does not start or ends before its answer | `{:lock_failed, text}` with its output; nothing is written | not reached |
| no answer in the bound | the port closes, `{:lock_failed, text}`; nothing is written | not reached |
| lock file cannot be opened, or is not a regular file | `{:lock_failed, text}` with the OS reason; nothing is written | not reached |
| lock held by another process | `{:session_locked, id}`; nothing is written | not reached |
| lock free | the server's `init/1` takes the lock, then writes or reads the file | holds the lock |
| owner stops normally | not reached | `terminate/2` sends one byte, perl exits, and the stop waits for its exit within the bound. The lock is free when the stop returns, or, past the bound, the release is unconfirmed and perl frees the lock when it ends |
| owner crashes or is killed | not reached | the port closes with the process; perl exits on the end of its stdin; the release is asynchronous |
| node halts (print mode) | not reached | the OS closes the pipe; perl exits |
| perl killed while the session runs | not reached | one `:notice`; the session stops saving and goes on in memory (decision 5). When the session handles the exit of the port before the first subscribe, the notice reaches no client; the snapshot of the later subscribe has `persisting: false`, and the client shows the not-saved text. The close of the port alone does not give that order: a subscribe already in the mailbox runs first, and its snapshot has `persisting: true` |
| the open fails after the lock is taken (file error, model error) | the `init/1` releases the lock and stops with the error; `start/2` or `resume/2` returns it | not reached |
| perl ends during the open in the `init/1` (the resume read can take long) | the open returns. The session traps exits from before the open, so it handles the exit of the port as in the row "perl killed while the session runs" and stops saving. A client call that is in the mailbox before that exit runs first: its snapshot can say `persisting: true`, and its write can append. After the exit, snapshots say `persisting: false` and nothing is saved. This is the same window as for a lock lost while the session runs (#639) | not reached |
| the open raises in the `init/1` (a bug) | the raise goes on, and the `init/1` crashes. The port is linked to the session process and closes with it, so perl exits and frees the lock, as for a crash (#623). The caller gets the crash as an error value, `{:error, {exception, stacktrace}}`, in place of the raise (a probe of the review, `docs/reviews/2026-10-15-session-lock-owner.md`) | not reached |
| the `init/1` crashes after the open (the hands do not start) | the port closes with the process, as for a crash of a running session. A new session leaves its file | not reached |
| the Core or its session supervisor is gone at the start request | no `init/1` runs, so no lock is taken and nothing is written; the caller exits | not reached |
| the caller dies during the open | the session process owns the port, so the caller holds nothing. An `init/1` that runs still starts the session, which holds the lock until it stops | not reached |

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| wait for perl's answer at the take | 5000 ms (`Helyx.Session.Lock`) | the port closes; `{:lock_failed, "perl gave no answer in 5000 ms"}` |
| wait of the session supervisor for an `init/1` | the take above, plus the create of the file or the read of a resume (`Helyx.Session.File.resume_picked/3`, with its size and heap bounds). The read has a size bound and no time bound. The other starts of the same Core, and a stop of the Core, wait for it; the stop of a single session does not | unbounded: a slow disk holds the starts of the Core as long as the read. Open, see `docs/reviews/2026-10-15-session-lock-owner.md` |
| perl output up to its answer line, the line included (startup warnings, such as a locale warning) | 4096 bytes; the answer line carries a random nonce, so no warning passes for it. The port reads in line mode (`{:line, 4096}`) and drops the `\n` or `\r\n` at the end of each line. The bound counts the bytes of each line read past, plus one byte for each line end, plus the line in hand; so a CRLF counts as one byte. The answer line is `<nonce> ok`, `<nonce> locked`, or `<nonce> error <reason>`, with `\n` or `\r\n` at its end. The last bytes of an output with no line end come after the exit status of perl, so the read goes on until the exit of the port, which the session server gets because it traps exits. Removed by the review of 2026-10-16: a CR before a line end in the output is no longer kept in the `:lock_failed` text | the port closes; `{:lock_failed, "perl wrote 4096 bytes with no answer in them"}` |
| the open of the lock file | no wait: perl opens it with `O_NONBLOCK`, so a FIFO with no reader fails, and it refuses a file that is not regular (a FIFO, a device, a directory, or a symlink to one) | not reached: perl answers `error` and exits; `{:lock_failed, "cannot open the lock file: <reason>"}`, and no perl process is left |
| wait for perl's exit at a release | 1000 ms (`Helyx.Session.Lock`), counted in `Helyx.Session.Server.Stop.shutdown_ms/0` | the port closes and the release is unconfirmed; perl frees the lock when it ends |
| text of a `:lock_failed` reason | the answer line and output are within the 4096-byte bound above; the app line has the 4000-byte cap of `CodingAgent.error_text/1` | cut |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| perl process and its port | `Helyx.Session.Lock.hold/2`, in the `init/1` of the session server | the session server | `Stop.run/1` releases it and waits for the exit | the port is linked to the owner and closes with it; perl exits on the end of its stdin | an abort of a turn does not touch the lock |
| `flock` on `<id>.lock` | perl | perl | perl's exit | the kernel, at perl's exit | not touched |
| `<id>.lock` file | perl (`sysopen` with append, with no wait) | the disk | stays | stays | stays |

The port is opened in the `init/1` of the session server, so it has one owner from its open to its close, and the caller of `start/2` or `resume/2` never holds it. An earlier form took the lock in the caller and passed the port to the `init/1`; a caller killed between the two left the lock held until the node ended (#589).

## Out of scope

- A lock on a network filesystem: `flock` on NFS is not reliable. Out of scope like the append rule of `docs/features/coding-agent.md`.
- A retake of a lost lock (decision 5).
- The survival of the session file across a power loss: out of scope, see "Durability" in `docs/features/coding-agent.md`, section "Session file".
- A wait for a busy session, or a skip of it in `--resume` (decision 3).
