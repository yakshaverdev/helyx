# Session edit

Ticket #833. A caller deletes a saved session, or removes one message from it.

## Goal

User story: a product keeps the sessions of its users. A user asks the product to remove a message, or a whole conversation, from every copy that it keeps. The product calls `Helyx.Sessions.remove_message(core, id, message_id)` or `Helyx.Sessions.delete(core, id)`. After the call, the session file holds no byte of that text, and a later resume, with its memory sync, does not bring it back.

Before this change, the session file was append only and nothing in Helyx removed it. A caller could not edit it safely: the reader rejects a broken chain, the lock of the data folder belongs to Helyx, and the path of the file is a detail of `Helyx.Session.File.Scan`.

Decisions (owner, 2026-11-06, triage comment on #833):

1. **A running session is refused.** A delete or a removal of a session that runs gives `{:error, :running}` and changes nothing. The caller stops the session first (`Helyx.Sessions.stop/1`). Reason: a running session holds the transcript in memory and appends to the file, so an edit under it would come back at its next append or in its memory.
2. **Pairs go together.** The removal of one half of a tool call and result pair removes both halves, and the call returns every id that it removed. Reason: a provider rejects a call with no result, and a result with no call.

Design decisions:

3. **The Registry decides "running".** Each call registers `{:edit, id}` in the session Registry of the Core, then looks up the id. A session of the id, or another edit of the id, is `{:error, :running}` and changes nothing. The key goes before the result returns. A session open looks up `{:edit, id}` after its own registration and refuses with `{:error, :editing}` (`session-lock.md`, decision 5). Both sides write their own key first, then read the key of the other, so at least one of the two sees the other; when both see each other, both refuse. Reason: the Core holds the lock of the data folder, so no other OS process writes the folder, and the Registry is the exclusion between the sessions and the edits of this Core.
4. **The BEAM writes the file.** The unlink of a delete, and the copy, the rename, and the removes of a removal, are local file calls in the Task. No command goes to perl. A hung disk holds the call, as it holds a session append. A dead process writes nothing, so no write happens after the exclusion ends.
5. **A removal rewrites the whole file.** The call reads and checks the file as a resume does, with no repair write (`Helyx.Session.File.read_picked/3`, the read of `resume_picked/3`), finds the group of the message, and copies the file without the group to `<id>.jsonl.tmp`, then renames the copy over the file. The copy is made new with an exclusive create, so no file or link at its path is written through; it gets the mode of the session file before its first byte, and it closes on every path. A copy left by an error or a kill is removed by the next removal or delete of the id. Every kept line is copied as it is, except an entry whose fields name a removed message:
   - The entry after removed messages gets the id of the last kept entry as its `parent_id`, so the file stays one chain.
   - A `last_id` of a compaction or a summary that names a removed message names the last kept message before the entry, or null when there is none. A null `last_id` reads as no compaction point, as before.
   - A summary whose `first_kept_id` is removed keeps from the next kept user or assistant message before the summary entry. With none, the summary entry goes: the resume then has the summary before it, or none, and the model gets more of the transcript, which loses nothing (`summary-compaction.md`).
   - A line that does not decode to an entry, a torn append that every read skips, is not copied: it can hold a part of the text.
   - A last line with no newline gets one.
   - A `system_prompt` entry (`turn-record.md`) is kept with all its fields, cut text and `bytes` included, in the order of the chain; one whose parent was removed gets the parent of the removed message, as any entry after removed messages does. So each prompt stays between the assistant messages that it came between, and a resume of the edited file reads the same records (`turn-record.md`, "Overlap with #833").
   - A `hook` entry (`hooks.md`) whose `call_id` is the id of a call of the removed group goes: a tool call of the removed assistant message, or the call of a removed tool result. It goes wherever it is in the file, and by its call id alone, so the entry of a call of another message with the same call id goes too (a provider can repeat a call id). Every other `hook` entry is kept as a `system_prompt` entry is. Reason (decision of the orchestrator, 2026-11-07): ADR 0013 §6 makes the `hook` entries a log of answers for the user, no code derives anything from them (a resume reads none), and a log entry about a call that the user removed has no call left to describe; the first entry of each chain on the call holds the JSON of its arguments, and a `reason` can hold text of the call or of its result, so a kept entry would keep bytes of the removed messages (requirement 2 of #833).

   Reason: an append-only file cannot lose bytes in place, and a rename replaces the file at once, so a reader sees the old file or the new one.
6. **The group of a message.** An assistant message and the run of tool results right after it are one group: a removed assistant message takes those results, and a removed tool result takes that assistant message and its other results. A tool result with no assistant message before its run, and a user message, are alone. The ids come back in file order. They are message ids only: the `hook` entries that go with the group, and a summary entry that goes (decision 5), are not in them, because no call of Helyx gives the id of such an entry to a caller, and a caller removes its own copies by message id (`Helyx.Memory` keys its records by message id). A message id must be the id of a message in the file: an interrupted result that a resume derives (`interrupted-calls.md`) has no line, so its id is `:message_not_found`, and the removal of its call removes it.
7. **A delete removes the copy first.** It removes `<id>.jsonl.tmp`, then `<id>.jsonl`, so a failed remove of the copy leaves the session file, and `{:edit_failed, text}` names the cause; a retry succeeds once the cause is gone (a directory at the path of the copy stays until it is removed by hand).
8. **The work runs in a Task.** The Task is not linked to the caller, so a caller that ends does not end it. It holds no port.
9. **The report derives from what happened.** For a removal, the caller arms the killer of the Task (`Helyx.Session.Killer.arm/2`) and sends its pid to the Task; the Task disarms it before it renames. A killer that fires kills the Task and ends with the reason `:fired`, and only that end, seen in the `:DOWN` of the killer at the caller, gives `{:error, :timeout}`. Any other end of the Task with no result is `{:error, :unknown}`: the file may or may not have changed. An example is a stop of the Core: its supervisor kills the Task after its shutdown time, and that kill can come after the rename. A delete has no killer, so any end of its Task with no result is `:unknown`. Reason: a kill gives the same exit reason `:killed` whoever sent it, so the reason cannot tell the deadline from a stop; `Helyx.Sessions.stop/1` reports `{:not_released, :unknown}` in the same way when another end came first.

## Interface changes

- `Helyx.Sessions.delete(core, id)`: `:ok`, or `{:error, reason}` with `:not_found` (no file of the id, or a Core with no `:sessions_dir`), `:invalid_id`, `:duplicate_id`, `:running` (a session of the id runs, or another edit of the id runs), `:not_regular` (the path is a symlink or not a file), `{:edit_failed, text}` (a remove failed), `:unknown` (decision 9), or a POSIX reason of the stat of the file. A file whose header does not parse is found and deleted.
- `Helyx.Sessions.remove_message(core, id, message_id)`: `{:ok, ids}`, or `{:error, reason}` with the reasons of a delete, the read errors of a resume (`{:invalid_file, text}`, `{:too_large, text}`, `:not_regular`, a POSIX reason), `:message_not_found`, `:timeout`, and `:unknown`. The ids are message ids only (decision 6).
- `Helyx.Session.Killer` (internal): the cancellable kill of the open of a session, moved out of `Helyx.Session.Server.Open` so that a removal uses it too. It can arm a kill of another process (`arm/2`), the process that it kills can cancel it (`disarm/1`), and a killer that fired ends with the reason `:fired`.
- `Helyx.Session.File.Scan.locate/2` (`@doc false`): the path of an id with no read of its header. `find/2` uses it.
- `Helyx.Session.File.Reader.entry/3` and `Helyx.Session.File.read_picked/3` (internal): the decode of one line, shared by the read and the copy, and the read of a resume with no repair write, which gives the limits of its lines to the copy.
- `Helyx.Session.File`: the moduledoc and ADR 0001 say that only these two calls change a saved file.

No wire request is added. The transport can map the calls later; the client contract is out of scope here.

## What the calls do not remove

Both calls change only the session file. They do not remove:

- the copies that a plugin keeps, such as the records of a `Helyx.Memory` plugin that `sync/2` got before the call. A later resume gives the plugin only the messages in the file, so a removed message does not come back through the replay; the plugin removes its own copy by its own policy;
- the stored state of a harness program, and the resume id of a provider that names it: the program keeps its own history. The resume id entry stays, so the provider resumes that history, which still holds the text;
- the text of a summary or a compaction that a model wrote, which can restate the removed text;
- the text of a `system_prompt` entry, which is kept as it is (`turn-record.md`): the bundled ModelContext builds the prompt with no message text, but a ModelContext plugin that puts message text in the prompt keeps that copy there, as a plugin keeps its own copies;
- the end message of a background run that a removed tool call started (`background-bash.md`): it is a message of its own, which holds the id of the run, also in the removed start result, and the output of the run; the caller removes it by its own id;
- the child sessions that a removed tool call started (`docs/features/agent-tool.md`): each is a saved session of its own, with its id from `Helyx.Sessions.child_id/2`, and the caller deletes it;
- the empty lock file (decision 7);
- the bytes that the filesystem, a snapshot, a backup, or a log keeps: the rename frees the blocks of the old file and does not overwrite them;
- a hard link to the session file that was made outside Helyx: it keeps the old file. A session file that is a symlink is refused with `:not_regular`, because the unlink and the rename would change the link and leave the file that it names;
- the transcript of a running session: refused (decision 1);

The rewrite changes the modification time of the file, so the session moves to the top of `list_saved/2`, and the first prompt of its list item can change.

## Replaced mechanism

None. The append-only rule of the session file (ADR 0001) stays for every session; these two calls are the only writers that remove bytes, and they run only while no session holds the file. `coding-agent.md`, "Repair never truncates", stays true of a resume.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| the wait of the caller of `delete/2` | no deadline of its own: two removes and the work of its Task | not reached |
| the work of `remove_message/3` up to its rename | 25,000 ms plus 3 ms for each 1,000 bytes of the file, at most 4,294,967,295 ms (`Helyx.Sessions`, the cap of `Helyx.Session.Killer`), counted from the start of the Task. The size is a stat before the Task. The base covers the small file and the margin for load. The rate is the rate of the load of a session open (`session-lock.md`, row "wait of the caller") for each of three passes: the read, the copy read, and the copy write. The Task disarms the killer before it renames, and the disarm waits for the end of the killer, so no kill of the killer follows a rename (`Helyx.Session.Killer`, the killer of the open of a session). After it, the rename and the remove of the copy after an error are local file calls | the killer kills the Task and ends with `:fired`: the caller gets `{:error, :timeout}`. A killer fires only before the disarm, so the rename was not done and the file did not change. A copy left by the kill is removed by the next removal or delete of the id. Any other kill of the Task is `{:error, :unknown}` (decision 9) |
| a caller that ends during a call | the Task is not linked: it runs to its end, within the bounds above; the killer of a removal is armed by the caller but not linked to it, so it still kills the Task at the deadline. A caller that ends before it sends the killer to the Task ends the Task, whose wait for it monitors the caller | not reached |
| one line of the file in the read | 64 MiB and a decode heap of 1 GiB, as a resume (`Helyx.Session.File`) | `{:error, {:too_large, text}}`, nothing changed |
| one line of the file in the copy | the read checked every line, and no session of the Core writes the file while the edit holds its key, so the copy reads lines of at most 64 MiB with the same decode | not reached for a writer that obeys the exclusion; accepted hole below |
| a batch of kept lines written to the copy | 1 MiB (`@batch_bytes` of `Helyx.Session.File.Edit`) plus one line of at most 64 MiB | written, and a new batch starts |
| the transcript in memory | the messages of the file, as a resume holds them | as a resume |
| the ids of a removal | one group: one assistant message and its run of tool results | not reached |
| `id` | a session id (`Helyx.Session.Id.valid?/1`), checked before a path is built | `{:error, :invalid_id}` |
| `message_id` | any binary; compared with the ids of the file | `{:error, :message_not_found}` |

Accepted holes: both sides can refuse at once (`:running` for the edit, `:editing` for the open); a retry passes. The Registry removes the key of a process that ended after it handles the exit, so an edit just after a session stop can get `:running`, and a resume just after the kill of an edit Task can get `:editing`. A session file that two folders share by a hard link has one folder lock for each Core, so an edit in one Core does not see a session of the other; the per-session lock files differed too. A program that writes the file without Helyx (an edit by hand) during a removal can make a copy line with no length bound, and its change is lost at the rename. A file operation that blocks in the OS (a hung disk) holds the kill until it returns, as in the open of a session. The session file of a new session can grow between the stat and the Task, and its removal then counts a smaller deadline; this needs a session that stopped in that window, and the result is `:timeout` with no change. A resume that picked the file before a delete gets the error of the read of a missing file (`:enoent`), not `:not_found`; a removal maps that case to `:not_found`. The rename has no `fsync`, as no write of the session file has one (`coding-agent.md`, "Durability").

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| `{:edit, id}` in the session Registry | `Registry.register/3` in the edit Task | the Task | `Registry.unregister/3` before the result returns | the Registry, at the end of the Task | the kill of the deadline is a crash of the Task |
| `<id>.jsonl.tmp` | the copy of a removal, made new with an exclusive create, with the mode of the session file before its first byte | the disk, written only by the Task | the rename makes it the session file; on an error of the call the Task removes it | stays; the next removal or delete of the id removes it. It holds only the kept messages | as a crash |
| the killer process of a removal | `Helyx.Session.Killer.arm/2` in the caller, for the Task | itself; it monitors the Task, and the caller monitors it | the disarm of the Task before the rename ends it; on an error before the rename it ends at the `:DOWN` of the Task, or at the cancel of the caller after the result | it ends at the `:DOWN` of the Task with `:normal`, so the caller reports `:unknown` | it kills the Task at the deadline, then ends with `:fired` |

The Task is the whole holder of the exclusion: its end, normal or not, ends the key, and no other process reads the file for it.

## Out of scope

- A wire request for the two calls, and a TUI command.
- The removal of more than one group in one call, and the edit of a message in place.
- The scrub of the old blocks on the disk, and the copies listed in "What the calls do not remove".
- A delete or a removal on a network filesystem: the lock is a `flock` (`session-lock.md`, "Out of scope").
