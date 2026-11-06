# Session edit

Ticket #833. A caller deletes a saved session, or removes one message from it.

## Goal

User story: a product keeps the sessions of its users. A user asks the product to remove a message, or a whole conversation, from every copy that it keeps. The product calls `Helyx.Sessions.remove_message(core, id, message_id)` or `Helyx.Sessions.delete(core, id)`. After the call, the session file holds no byte of that text, and a later resume, with its memory sync, does not bring it back.

Before this change, the session file was append only and nothing in Helyx removed it. A caller could not edit it safely: the reader rejects a broken chain, the writer lock belongs to Helyx, and the path of the file is a detail of `Helyx.Session.File.Scan`.

Decisions (owner, 2026-11-06, triage comment on #833):

1. **A running session is refused.** A delete or a removal of a session that runs gives `{:error, :running}` and changes nothing. The caller stops the session first (`Helyx.Sessions.stop/1`). Reason: a running session holds the transcript in memory and appends to the file, so an edit under it would come back at its next append or in its memory.
2. **Pairs go together.** The removal of one half of a tool call and result pair removes both halves, and the call returns every id that it removed. Reason: a provider rejects a call with no result, and a result with no call.

Design decisions:

3. **The writer lock decides "running".** Each call takes the lock of the file (`docs/features/session-lock.md`) and does its work under it. A lock that another process holds is `{:error, :running}`: a session of this Core, of another Core, or of another OS process, and also a second edit of the same id. Before the take, the call looks the id up in the session Registry of the Core: a session of the id that is there, in its open or after it lost its lock, is `:running` too. Reason: the lock is the one rule that every writer of the file obeys; the Registry check adds the sessions of this Core that hold no lock.
4. **The change of the file is a command of the lock holder.** The unlink of a delete, and the rename of the rewritten copy of a removal, are commands of the perl process that holds the `flock` (decision 6 of `session-lock.md`; this ticket adds `m`, a rename). So no change happens after the lock has ended: when perl ends, another process can take the lock, and a late rename would drop what that process appended.
5. **A removal rewrites the whole file.** The call reads and checks the file as a resume does, with no repair write (`Helyx.Session.File.read_picked/2`, the read of `resume_picked/3`), finds the group of the message, removes an old copy, and copies the file without the group to `<id>.jsonl.tmp`, made new with `O_EXCL`, then renames the copy over the file. The remove of an old copy, the remove of the copy after an error, and the rename are commands of the lock holder; the write of the copy is the only write of the Task, and it goes to a file that the Task made. Every kept line is copied as it is, except an entry whose fields name a removed message:
   - The entry after removed messages gets the id of the last kept entry as its `parent_id`, so the file stays one chain.
   - A `last_id` of a compaction or a summary that names a removed message names the last kept message before the entry, or null when there is none. A null `last_id` reads as no compaction point, as before.
   - A summary whose `first_kept_id` is removed keeps from the next kept user or assistant message before the summary entry. With none, the summary entry goes: the resume then has the summary before it, or none, and the model gets more of the transcript, which loses nothing (`summary-compaction.md`).
   - A line that does not decode to an entry, a torn append that every read skips, is not copied: it can hold a part of the text.
   - A last line with no newline gets one.

   Reason: an append-only file cannot lose bytes in place, and a rename replaces the file at once, so a reader sees the old file or the new one.
6. **The group of a message.** An assistant message and the run of tool results right after it are one group: a removed assistant message takes those results, and a removed tool result takes that assistant message and its other results. A tool result with no assistant message before its run, and a user message, are alone. The ids come back in file order. A message id must be the id of a message in the file: an interrupted result that a resume derives (`interrupted-calls.md`) has no line, so its id is `:message_not_found`, and the removal of its call removes it.
7. **A delete keeps the lock file.** It removes `<id>.jsonl.tmp`, then `<id>.jsonl`, so a failed remove of the copy leaves the session file for a retry. The empty `<id>.lock` stays, as after a stop. Reason: an open that opened the old lock file before its unlink would lock that file, and a later open would lock a new file at the path, so two processes would hold "the" lock.
8. **The work runs in a Task.** The Task owns the port of the lock and traps its exits, as `Lock.take/1` needs, so the caller gets no message of the port. The Task is not linked to the caller.

## Interface changes

- `Helyx.Sessions.delete(core, id)`: `:ok`, or `{:error, reason}` with `:not_found` (no file of the id, or a Core with no `:sessions_dir`), `:invalid_id`, `:duplicate_id`, `:running`, `:not_regular` (the path is a symlink or not a file), `{:lock_failed, text}`, `{:edit_failed, text}` (the unlink failed), or a POSIX reason of the stat under the lock. A file whose header does not parse is found and deleted.
- `Helyx.Sessions.remove_message(core, id, message_id)`: `{:ok, ids}`, or `{:error, reason}` with the reasons of a delete, the read errors of a resume (`{:invalid_file, text}`, `{:too_large, text}`, `:not_regular`, a POSIX reason), `:message_not_found`, and `:timeout`.
- `Helyx.Session.Lock.rename_file/3` and the perl command `m` with two fields, the old and the new path; the answer is `done` or `fail <reason>`, as for `w` and `r`.
- `Helyx.Session.Killer` (internal): the cancellable kill of the open of a session, moved out of `Helyx.Session.Server.Open` so that a removal uses it too.
- `Helyx.Session.File.Scan.locate/2` (`@doc false`): the path of an id with no read of its header. `find/2` uses it.
- `Helyx.Session.File.Reader.entry/3`, `Helyx.Session.File.limits/1`, and `Helyx.Session.File.read_picked/2` (internal): the decode of one line, shared by the read and the copy, and the read of a resume with no repair write.
- `Helyx.Session.File`: the moduledoc and ADR 0001 say that only these two calls change a saved file.

No wire request is added. The transport can map the calls later; the client contract is out of scope here.

## What the calls do not remove

Both calls change only the session file. They do not remove:

- the copies that a plugin keeps, such as the records of a `Helyx.Memory` plugin that `sync/2` got before the call. A later resume gives the plugin only the messages in the file, so a removed message does not come back through the replay; the plugin removes its own copy by its own policy;
- the stored state of a harness program, and the resume id of a provider that names it: the program keeps its own history. The resume id entry stays, so the provider resumes that history, which still holds the text;
- the text of a summary or a compaction that a model wrote, which can restate the removed text;
- the child sessions that a removed tool call started (`docs/features/agent-tool.md`): each is a saved session of its own, with its id from `Helyx.Sessions.child_id/2`, and the caller deletes it;
- the empty lock file (decision 7);
- the bytes that the filesystem, a snapshot, a backup, or a log keeps: the rename frees the blocks of the old file and does not overwrite them;
- a hard link to the session file that was made outside Helyx: it keeps the old file. A session file that is a symlink is refused with `:not_regular`, because the unlink and the rename would change the link and leave the file that it names;
- the transcript of a running session: refused (decision 1).

The rewrite changes the modification time of the file, so the session moves to the top of `list_saved/2`, and the first prompt of its list item can change.

## Replaced mechanism

None. The append-only rule of the session file (ADR 0001) stays for every session; these two calls are the only writers that remove bytes, and they run only while no session holds the file. `coding-agent.md`, "Repair never truncates", stays true of a resume.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| the take of the lock | 5,000 ms and 4,096 bytes of output (`Helyx.Session.Lock`) | `{:lock_failed, text}`, nothing changed |
| each file command (unlink, rename) | 5,000 ms for its answer (`Helyx.Session.Lock`) | `{:edit_failed, text}`; the perl process is released. Accepted hole: perl can still run a command whose answer came late before it reads the byte of the release, so this one error can come after the remove or the rename ran; the docs of both calls say so |
| the release of the lock | 1,000 ms (`Helyx.Session.Lock`) | the port closes, perl frees the lock when it ends |
| the wait of the caller of `delete/2` | no deadline of its own: the take, two commands, and the release above, at most about 16 s | not reached |
| the work of `remove_message/3` up to its rename | 25,000 ms plus 3 ms for each 1,000 bytes of the file, at most 4,294,967,295 ms (`Helyx.Sessions`, the cap of `Helyx.Session.Killer`), counted from the start of the Task. The size is a stat before the take. The rate is the rate of the load of a session open (`session-lock.md`, row "wait of the caller") for each of three passes: the read, the copy read, and the copy write. The Task cancels the kill before it sends the rename, and the cancel waits for the end of the killer, so no kill follows a sent rename (`Helyx.Session.Killer`, the killer of the open of a session). After it, the rename, the remove of the copy after an error, and the release have the bounds of the rows above, at most 11 s | the killer kills the Task: its port closes, perl exits and frees the lock, and the caller gets `{:error, :timeout}`. The rename was not sent, so the file did not change. A copy left by the kill is removed by the next removal or delete of the id |
| a caller that ends during a call | the Task is not linked: it runs to its end, within the bounds above | not reached |
| one line of the file in the read | 64 MiB and a decode heap of 1 GiB, as a resume (`Helyx.Session.File`) | `{:error, {:too_large, text}}`, nothing changed |
| one line of the file in the copy | the read under the lock checked every line, and no session writes the file while the lock is held, so the copy reads lines of at most 64 MiB with the same decode | not reached for a writer that obeys the lock; accepted hole below |
| the transcript in memory | the messages of the file, as a resume holds them | as a resume |
| the ids of a removal | one group: one assistant message and its run of tool results | not reached |
| `id` | a session id (`Helyx.Session.Id.valid?/1`), checked before a path is built | `{:error, :invalid_id}` |
| `message_id` | any binary; compared with the ids of the file | `{:error, :message_not_found}` |

Accepted holes: a process that writes the file without the lock (an edit by hand) during a removal can make a copy line with no length bound, and its change is lost at the rename. A file operation that blocks in the OS (a hung disk) holds the kill until it returns, as in the open of a session. The session file of a new session can grow between the stat and the take, and its removal then counts a smaller deadline; this needs a session that stopped in that window, and the result is `:timeout` with no change. A resume that picked the file before a delete takes the lock after it and gets the error of the read of a missing file (`:enoent`), not `:not_found`; a removal maps that case to `:not_found`. The rename has no `fsync`, as no write of the session file has one (`coding-agent.md`, "Durability").

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| perl process and its port (the lock) | `Lock.take/1` in the Task | the Task | `Lock.release/1` at the end of the call | the port is linked to the Task and closes with it; perl exits on the end of its stdin | the kill of the deadline is a crash of the Task |
| `<id>.jsonl.tmp` | the copy of a removal, made with `O_EXCL` after a remove of an old one | the disk | the rename makes it the session file; on an error of the call the Task removes it | stays; the next removal or delete of the id removes it. It holds only the kept messages | as a crash |
| the killer process of a removal | `Helyx.Session.Killer.arm/1` in the Task | itself; it monitors the Task | the cancel before the rename ends it; on an error before the rename it ends at the `:DOWN` of the Task | it ends at the `:DOWN` of the Task | it kills the Task at the deadline, then ends |

The Task holds the port: it is the design flag of the template. Here the Task is the whole holder by design: its end, normal or not, ends the lock, and no other process needs the port.

## Out of scope

- A wire request for the two calls, and a TUI command.
- The removal of more than one group in one call, and the edit of a message in place.
- The scrub of the old blocks on the disk, and the copies listed in "What the calls do not remove".
- A delete or a removal on a network filesystem: the lock is a `flock` (`session-lock.md`, "Out of scope").
