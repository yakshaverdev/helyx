# Session lock

Ticket #579. One OS process at a time has a session open.

## Goal

User story: I open a session that another Helyx process already has open, for example a second TUI with `--session <id>`, or a print run (#574) next to a TUI. The second open fails at once with one line, `helyx: session <id> is open in another process`, and exit status 1, before the TUI draws. Print mode prints the same line. A session whose process crashed, or was killed with SIGKILL, opens normally.

Before this change, two processes could open one session. Both appended to the one session file, and with a harness model both continued one provider session.

Decisions (owner, 2026-10-14):

1. **An OS file lock.** The lock is a `flock` with `LOCK_EX|LOCK_NB` on `<id>.lock`, next to the session file `<id>.jsonl`. A small perl program holds it: it opens the lock file, takes the lock, writes the result on stdout, and then waits on stdin. The program runs on a port that the session server process owns. When that process stops, crashes, or the node halts, the port closes, perl reads the end of its stdin and exits, and the kernel releases the lock. So there is no stale rule and no pid in the file. Perl is a requirement of Core when `:sessions_dir` is given; Erlang has no `flock`, and the bash tool requires perl already.
2. **Core takes the lock.** `Helyx.Session.start/2` and `Helyx.Session.resume/2` take it when `:sessions_dir` is given, before `Helyx.Session.File` writes anything (a resume can append a newline). So every product and every worker (#578) gets it. `--list` reads without the lock. A held lock gives `{:error, {:session_locked, id}}`.
3. **`--resume` with no id does not skip a busy session.** When the newest session of the folder is locked, the open fails with the line above. The user picks another session with `--session` or `--list`.
4. **Release.** The lock lives as long as the session server process. A normal stop, a crash, and a print-mode halt all release it, because the port closes. The lock file stays on disk; only the `flock` on it counts.
5. **Perl ends while the session runs.** The kernel releases the lock, and another process can then open the session. The session watches the port: when it closes, the session sends one `:notice` event with no turn id, "the session lock is lost; another Helyx process can now open this session", and goes on. It does not take the lock again: a second process may hold it by then, and the session cannot tell.

## Interface changes

- `Helyx.Session.start/2` and `resume/2` with `:sessions_dir`: new errors `{:session_locked, id}` and `{:lock_failed, text}`. `text` is one sentence for each cause: perl is not on the PATH, the lock file cannot be opened (with the OS reason), or perl gave no answer in time.
- With two Cores in one node, a resume of a session that the other Core holds now gives `{:session_locked, id}`. A second resume in the same Core gives `{:session_locked, id}` too, in place of `{:already_started, pid}`: the lock comes before the start of the process.
- A new `:notice` event text: the lock is lost (decision 5).
- `CodingAgent.error_text/1`: `{:session_locked, id}` gives `session <id> is open in another process`, with no "could not start the agent" prefix. `{:lock_failed, text}` gives `could not start the agent: could not lock the session: <text>`.
- New Core module `Helyx.Session.Lock` (`@moduledoc false`). Core cannot call `Helyx.Watchdog`, which is plugin code (ADR 0005).

## Replaced mechanism

Two writers on one session file (#266). The tree rules of the file stay: they read a file that two writers made before this change, or a copy by hand. What changes:

1. Two Cores that resume one session in one `sessions_dir` no longer both run: the second gets `{:session_locked, id}`. Three tests used that state to make two writers or two instances of one id: "each Core writes its own branch" and "a subscribe to the id in another Core leaves the events of the first" (`test/helyx/session/instance_test.exs`), and "a resume of a branch with a fork below its label starts a fresh program session" (`test/helyx/session/provider_process_test.exs`). Each keeps its property: the second Core resumes a hard link of the file in a second sessions folder (`Helyx.Test.SessionCase.link_session/2`), so both write the one file and each has its own lock file.
2. "keeps no copy after a start and after a failed start" (`test/helyx/session/persistence_test.exs`) needs a start that fails in the supervisor. A second resume in one folder now fails at the lock, before the supervisor, so the test resumes the link in a second folder, and the Registry still rejects it with `{:already_started, pid}`.
3. "resume after a crash mid-turn" (`test/helyx/session/persistence_test.exs`) kills the session and resumes it: the kill frees the lock only when perl exits, so the test waits for the free lock.
4. `docs/features/session-instance.md`, "Two Cores", `docs/features/coding-agent.md`, "Session file", and `docs/features/print-mode.md`, "Accepted holes", change to say this.

## States

| External state | What the open does | What the running session does |
| -------------- | ------------------ | ----------------------------- |
| perl not on the PATH | `{:lock_failed, text}`; the session file is not written (the take makes its folder first) | not reached |
| perl does not start or ends before its answer | `{:lock_failed, text}` with its output; nothing is written | not reached |
| no answer in the bound | the port closes, `{:lock_failed, text}`; nothing is written | not reached |
| lock file cannot be opened | `{:lock_failed, text}` with the OS reason; nothing is written | not reached |
| lock held by another process | `{:session_locked, id}`; nothing is written | not reached |
| lock free | the lock is taken, then the file is written, then the server starts and takes the port | holds the lock |
| owner stops normally | not reached | `terminate/2` sends one byte, perl exits, and the stop waits for its exit within the bound. The lock is free when the stop returns, or, past the bound, the release is unconfirmed and perl frees the lock when it ends |
| owner crashes or is killed | not reached | the port closes with the process; perl exits on the end of its stdin; the release is asynchronous |
| node halts (print mode) | not reached | the OS closes the pipe; perl exits |
| perl killed while the session runs | not reached | one `:notice`; the session goes on without the lock (decision 5) |
| the open fails after the lock is taken (file error, model error, start error) | the caller releases the lock before it returns the error. A session process that took the port and then crashed in its `init/1` closed it already: the release is then unconfirmed, as for a crash | not reached |
| the Core or its session supervisor is gone at the start request, or the `hold/2` function raises | the caller releases the lock and goes on with the same raise or exit | not reached |

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| wait for perl's answer at the take | 5000 ms (`Helyx.Session.Lock`) | the port closes; `{:lock_failed, "perl gave no answer in 5000 ms"}` |
| perl output up to its answer line, the line included (startup warnings, such as a locale warning) | 4096 bytes; the answer line carries a random nonce, so no warning passes for it | the port closes; `{:lock_failed, "perl wrote 4096 bytes with no answer in them"}` |
| wait for perl's exit at a release | 1000 ms (`Helyx.Session.Lock`), counted in `Helyx.Session.Server.Stop.shutdown_ms/0` | the port closes and the release is unconfirmed; perl frees the lock when it ends |
| text of a `:lock_failed` reason | the answer line and output are within the 4096-byte bound above; the app line has the 4000-byte cap of `CodingAgent.error_text/1` | cut |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| perl process and its port | `Helyx.Session.Lock.take/1`, in the caller of `start/2` or `resume/2` | the caller until the server's `init/1` connects the port, then the session server | `Stop.run/1` releases it and waits for the exit | the port is linked to the owner and closes with it; perl exits on the end of its stdin | an abort of a turn does not touch the lock |
| `flock` on `<id>.lock` | perl | perl | perl's exit | the kernel, at perl's exit | not touched |
| `<id>.lock` file | perl (`open` with append) | the disk | stays | stays | stays |

The caller unlinks the port right before it asks the supervisor for the session process, and stays its owner until `init/1` connects it. So a session process that dies in its `init/1` after the connect closes the port without an exit signal to the caller. A start request that exits (the supervisor is gone) is caught, and the caller releases the lock.

Open race (needs a ticket): a caller that another process kills after its unlink leaves the port with a dead owner. If the start request still reaches the supervisor, `init/1` connects the port and the session runs as usual. If no init runs (the request never went out, or the supervisor ends first), nothing closes the port, and the lock stays held until the node ends.

## Out of scope

- A lock on a network filesystem: `flock` on NFS is not reliable. Out of scope like the append rule of `docs/features/coding-agent.md`.
- A retake of a lost lock (decision 5).
- The survival of the session file across a power loss: ticket #584.
- A wait for a busy session, or a skip of it in `--resume` (decision 3).
