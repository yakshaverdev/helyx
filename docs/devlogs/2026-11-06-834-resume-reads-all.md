# 2026-11-06: #834, the resume reads the whole file

Done:

- `Helyx.Session.File.resume_picked/3` has no file limit and no whole-file heap cap. `Helyx.Session.File.Reader` reads the file in reads of 1 MiB, one line at a time; a line has at most 64 MiB (`:max_entry_bytes`), and a line over 64 KiB decodes in a process of its own with a heap cap of 1 GiB (`:max_heap_bytes`). A line over either is `{:too_large, text}` and the file does not change. `Scan.with_regular/2` opens a regular file for the resume and the header scan.
- The docs that cited the 64 MiB file limit as a bound now cite the line limit or the transcript (coding-agent, interrupted-calls, memory, message-identity, print-mode, session-list, session-snapshot, tool-text-out-of-core, tui-attach, tui-tool-output-toggle, wire-protocol).
- The bench `session_append.exs` measures `resume_picked/3`.

What broke: three review rounds (`docs/reviews/2026-11-06-834-resume-reads-all.md`). Round 3 reproduced that tool calls of dense small values within the live bounds resume at about 3.4 MB/s, so a session-written file of about 85 MB passes the open deadline of 25,000 ms.

Next: the owner decides on the open deadline of the resume load (see the review record, round 3).
