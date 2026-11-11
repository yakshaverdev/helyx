# Data folder lock

Tickets #579, #589, #605, #629, #661, #833. One Core at a time holds a data
folder.

## Goal

User story: I start a second Helyx server, or a product starts a second Core,
on a data folder that a Core holds. The start fails with
`{:error, {:data_folder_locked, dir}}`, and `helyx serve` prints
`helyx: could not start the agent: another Helyx process holds the data folder
<dir>`. One perl process runs for each Core, not one for each session. A Core
whose process crashed, or was killed with SIGKILL, frees the folder.

Before this change, each session that had a file took a `flock` on
`<id>.lock`. All clients now use one server, so a second OS process no longer
opens session files, and the lock of each session became one lock for the data
folder of each Core.

## Decisions

1. **The flock and its holder.** The lock is a `flock` with `LOCK_EX|LOCK_NB`
   on `<sessions_dir>/core.lock`, held by the perl program of
   `Helyx.Session.Lock` on a port. When the owner of the port ends, the port
   closes, perl reads the end of its stdin and exits, and the kernel releases
   the lock, so there is no stale rule and no pid in the file. Perl is a
   requirement of Core when `:sessions_dir` is given.
2. **Core takes the lock.** `Helyx.Core.FolderLock` is the first child of
   `Helyx.Core`, and only when `:sessions_dir` is set, so the lock is taken
   before the Registry and the session supervisor exist. A supervisor stops
   its children in reverse order, so the lock is released after every session,
   sync worker, and edit Task has stopped. A second Core on the folder, in this
   node or in another OS process, fails at its start.
3. **A lost lock stops Core.** When perl ends while Core runs, the child stops
   with `{:data_folder_lock_lost, dir}`. Its child spec is `temporary` and
   `significant`, and the Core supervisor has `auto_shutdown: :any_significant`,
   so Core stops all its children and exits with `:shutdown`. There is no
   "go on unsaved" mode for this cause. The `persisting` field of the snapshot
   stays for a failed write.
4. **A session writes only in the folder of its Core.** `:sessions_dir` of
   `Helyx.Session.start/2` and `resume/2` is absent (no file) or equal to the
   `:sessions_dir` of the Core; any other value gives
   `{:error, {:invalid_option, :sessions_dir}}`.
5. **A file edit excludes the sessions through the Registry.** The edit
   registers `{:edit, id}`, then looks up the id. The session is in the
   Registry under its id from before its `init/1`, and its open looks up
   `{:edit, id}` after its own registration, so at least one of the two sees
   the other. A session of the id, or another edit of the id, is
   `{:error, :running}`; an open under an edit is `{:error, :editing}`. Both
   sides write their own key first, then read the other's. The edit writes the
   copy, the rename, and the removes in the BEAM, in its Task
   (`docs/features/session-edit.md`).
6. **File commands of the holder.** Only `w` (write a file with mode 0600
   through a temporary file and a rename) and `r` (remove a file) stay, for
   `helyx serve`, which keeps `server.lock` and `server.json`. The copy
   commands and the rename command of the session edit go.

## Interface changes

- New Core errors: `{:data_folder_locked, dir}`, `{:lock_failed, text}`, and
  `{:create_failed, reason}`. `Helyx.Core` maps the failed start of its lock
  child to them.
- `Helyx.Session.Lock.take/1` gives `{:error, :locked}` in place of
  `{:error, {:session_locked, name}}`.
- Removed session errors: `{:session_locked, id}` and `{:lock_failed, text}`.
  New open error: `:editing`.
- Removed notice text: "the session lock is lost".
- The `save` tuples of `Helyx.Session.Server.State` have two elements:
  `{:saving, file}` and `{:stopped, unsaved_from}`. `State.lock/1` goes.
- `Helyx.Session.Server.Stop.shutdown_ms/0` is 30,000 ms: the provider close
  (5,000) plus the hands stop (22,000) plus the load shutdown (3,000). The
  wire `stop` deadline stays 77,000 ms, 1,000 ms above the sum.

## Replaced mechanism

The lock of each session. A test of each property of the old lock keeps it:

| Deleted test | Property that keeps it |
| ------------ | ---------------------- |
| `lock_test` "a session that another Core holds does not open, the same Core attaches, and its file is unchanged" | `folder_lock_test` "a second Core on one sessions folder fails at its start with :data_folder_locked" |
| `lock_test` "the newest session of the folder is not skipped when it is locked" | The folder has one Core, so no second process holds a session of it |
| `lock_test` "a normal stop frees the lock before it returns" | `folder_lock_test` "a stop of Core frees the folder for the next Core" |
| `lock_test` "a killed session frees its lock" | The ownership row of a killed holder: the port closes, perl exits, the kernel frees the lock |
| `lock_test` "perl killed while the session runs gives one notice, and the session stops saving" | `folder_lock_test` "a Core whose lock ends stops" |
| `lock_test` "a start whose lock file cannot be opened fails and writes nothing" | `folder_lock_test` "a core.lock that is not a regular file fails the start, and no perl is left" |
| `lock_test` "a resume whose lock file cannot be opened fails and changes nothing" | The same test; a Core cannot start on such a folder |
| `lock_test` "the moved deadline of the load still kills" | `open_test` "the deadline of the load grows with the file", with one `Killer.arm` before the load |
| `lock_test` "a stop past the release bound returns, and perl frees the lock when it ends" | `folder_lock_test` "a stop of Core frees the folder for the next Core", within the release bound |
| `lock_test` "an open whose perl ends during it sends the exit of the port" | `folder_lock_test` "a Core whose lock ends stops" |
| `lock_test` "a copy is made with mode 0600, appended to, and gets its mode at its close" | `sessions_edit_test` "a removal keeps the mode of the session file" |
| `lock_test` "a file command after the end of the lock writes, renames, and removes nothing" | The BEAM writes the copy and the rename in the edit Task, which a dead process does not run |
| `lock_test` "a lock path that is not a regular file fails, and no perl is left" | `folder_lock_test` "a core.lock that is not a regular file fails the start, and no perl is left" |
| `sessions_edit_test` "a lock that another process holds is refused" | The Core lock: no other OS process writes the folder |
| `sessions_edit_test` describe "a session that lost its lock" | `sessions_edit_test` "an edit in progress refuses a resume and a second edit, and then completes" |
| `sessions_edit_test` describe "a removal whose lock holder ends" | A dead edit Task writes nothing; the Registry removes its key |
| `print_test` "a session open in another process is one line and 1, with -p and without" | `folder_lock_test` test 1, and the one line of `CodingAgent.error_text/1` |
| `attach_test` "a newest session that another OS process has open is not skipped" | A newest session with a model of an unknown provider is not skipped |

`lock_test` became `open_test` for the tests that stay. `Lock.hold/2` and the
copy commands went with the per-session lock.

## States

| State | Core start | A running Core |
| ----- | ---------- | -------------- |
| the folder is free | Core makes the folder (`Helyx.Session.File.mkdir/1`) and takes `core.lock` | holds the lock |
| another Core holds the folder | `{:error, {:data_folder_locked, dir}}`; nothing written | not reached |
| the folder cannot be made | `{:error, {:create_failed, reason}}` | not reached |
| perl not on the PATH | `{:error, {:lock_failed, "perl is not on the PATH; Helyx needs it for its file locks"}}` | not reached |
| perl gives no answer, or its output breaks the bound | `{:error, {:lock_failed, text}}` | not reached |
| `core.lock` cannot be opened, or is not a regular file | `{:error, {:lock_failed, text}}` with the OS reason; no perl is left | not reached |
| perl ends while Core runs | not reached | the child stops with `{:data_folder_lock_lost, dir}`, and Core stops with `:shutdown` |
| Core stops normally | not reached | `FolderLock.terminate/2` sends the byte that ends perl and waits for its exit within the release bound |
| Core crashes or is killed | not reached | the port closes with the process; perl exits on the end of its stdin |

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| wait for perl's answer at the take | 5,000 ms and 4,096 bytes of output (`Helyx.Session.Lock`) | Core start fails with `{:lock_failed, text}` |
| release of the lock at the Core stop | 1,000 ms (`Helyx.Session.Lock.release_ms/0`), inside the default worker shutdown of 5,000 ms | the port closes and the release is unconfirmed; perl frees the lock when it ends |
| open deadline | one `Killer.arm` before the load: `deadline_ms.open` (25,000 ms) plus 1 ms for each 1,000 bytes of the file, from one stat before the load | the session is killed and the caller gets `{:error, :open_timeout}` |
| a session of the Core | no perl, no lock take | not reached |
| the edit exclusion | no wait: the Registry answers `{:error, :running}` or `{:error, :editing}` | not reached |
| the edit's file calls | no bound of their own, as a session append | a hung disk holds the call |
| `remove_message/3` up to its rename | 25,000 ms plus 3 ms for each 1,000 bytes of the file (`Helyx.Sessions`) | `{:error, :timeout}`, and the file did not change |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| perl process and its port | `Helyx.Session.Lock.take/1` in `Helyx.Core.FolderLock` | `Helyx.Core.FolderLock` | `terminate/2` calls `Lock.release/1` and waits for the exit | the port is linked to the owner and closes with it; perl exits on the end of its stdin | an abort of a turn does not touch the lock |
| `flock` on `<sessions_dir>/core.lock` | perl | perl | perl's exit | the kernel, at perl's exit | not touched |
| `core.lock` file | perl (`sysopen` with append, with no wait) | the disk | stays | stays | stays |

## Accepted holes

- Both sides can refuse at once: `:running` for the edit and `:editing` for the
  open. A retry passes.
- The Registry removes the key of a process that ended after it handles the
  exit. An edit just after a session stop can get `:running`, and a resume just
  after the kill of an edit Task (the deadline, or a Core stop) can get
  `:editing`.
- A lost folder lock stops Core, but until the stop ends, a session of the Core
  can still append (a mailbox drain, then the plugin stop). For `helyx serve`
  the hole is closed in practice: `server.lock` stays held until after the Core
  stop.
- A removed `core.lock` lets a second Core lock a new file at the path while
  the first holds the old one. A hard link that two folders share has one lock
  for each folder, so an edit in one Core does not see a session of the other.
- A program that writes the folder without Helyx (an edit by hand) is not seen.

## Out of scope

- A merge of `server.lock` into `core.lock`, and of `hub.db.lock`.
- A change of the wire `stop` deadline (77,000 ms) in the Rust client and the
  TUI.
- A cleanup of old `<id>.lock` files on disk. Nothing reads them.
- A lock on a network filesystem.
- A wait of the open for an edit: the open refuses with `:editing`.
- A narrower window between a lost folder lock and the end of the Core stop.
- A wire request for edits.
